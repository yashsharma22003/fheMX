// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {GmxRole} from "../../src/interfaces/gmx/IGmxRoleStore.sol";
import {GmxEventUtils} from "../../src/interfaces/gmx/GmxTypes.sol";
import {MockGmxRoleStore, MockGmxExchangeRouter, MockGmxDataStore, MockGmxReader} from "../helpers/GmxMocks.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

/// @notice A checker that tries to re-enter the adapter when paid.
contract ReenteringChecker {
    SealedOrderAdapter private immutable adapter;
    address private immutable market;
    bytes32 private orderId;

    constructor(SealedOrderAdapter adapter_, address market_) {
        adapter = adapter_;
        market = market_;
    }

    function check(bytes32 id, bytes calldata report) external {
        orderId = id;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        adapter.checkBatch(market, ids, report);
    }

    receive() external payable {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = orderId;
        adapter.checkBatch(market, ids, ""); // re-entry attempt
    }
}

/// @notice Known issue 11: per-check fee paid from each order's check budget (design D3, fee-model.md §6).
contract SealedOrderAdapterCheckFeeTest is SealedOrderAdapterTestBase {
    address private constant WNT = address(0x4E7);
    address private constant MARKET = address(0x3A2);
    uint256 private constant FEE = 0.0001 ether;
    uint256 private constant SPREAD = 0.00001 ether;
    uint256 private constant BUDGET = 3 * FEE;
    uint256 private constant EXEC_FEE = 0.001 ether;
    uint256 private constant COLLATERAL = 1 ether;

    address private keeper = makeAddr("keeper");
    address private feeCollector = makeAddr("feeCollector");
    address private gmxHandler = makeAddr("gmxHandler");
    GmxEventUtils.EventLogData private emptyLog;

    function setUp() public {
        vm.warp(1_800_000_000);
        MockGmxRoleStore roleStore = new MockGmxRoleStore();
        roleStore.grant(gmxHandler, GmxRole.CONTROLLER);
        MockGmxDataStore dataStore = new MockGmxDataStore();
        UserAccount impl = new UserAccount(
            UserAccount.GmxContracts({
                exchangeRouter: address(new MockGmxExchangeRouter()),
                router: address(0x0B7),
                orderVault: address(0x0FA),
                dataStore: address(dataStore),
                roleStore: address(roleStore),
                wnt: WNT
            }),
            feeCollector
        );
        checkFee = FEE;
        checkFeeSpread = SPREAD;
        checkBudget = BUDGET;
        _deployAdapter(address(impl), WNT, MARKET, address(new MockGmxReader()), address(dataStore));
        _fund(alice.account(), 5 ether);
    }

    function _order(uint64 trigger) internal returns (bytes32) {
        return _submitAs(alice, _input(alice, MARKET, COLLATERAL, EXEC_FEE, Plain(true, 5_000e6, trigger, 50)));
    }

    function _account() internal view returns (IUserAccount) {
        return IUserAccount(adapter.accountOf(alice.account()));
    }

    function _keeperChecks(bytes32 id, uint256 price8) internal {
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        bytes memory report = prices.report(price8, block.timestamp);
        vm.prank(keeper);
        adapter.checkBatch(MARKET, ids, report);
    }

    function test_intake_locksCheckBudgetInEth() public {
        bytes32 id = _order(2_000e8);
        assertEq(_account().lockOf(id).checkBudget, BUDGET);
        assertEq(
            _account().freeBalance(WNT),
            5 ether - COLLATERAL - 2 * EXEC_FEE - adapter.maxProtocolFee(COLLATERAL) - BUDGET
        );
    }

    function test_intake_rejectsBudgetBelowOneCheck() public {
        checkBudget = FEE - 1;
        SealedOrderAdapter.SealedOrderInput memory input =
            _input(alice, MARKET, COLLATERAL, EXEC_FEE, Plain(true, 5_000e6, 2_000e8, 50));
        vm.prank(alice.account());
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.CheckBudgetTooLow.selector, FEE - 1, FEE));
        adapter.submitOrder(input);
    }

    function test_eachCheck_paysCheckerAndCollectorFromBudget() public {
        bytes32 id = _order(2_000e8);
        _keeperChecks(id, 2_500e8);

        assertEq(keeper.balance, FEE - SPREAD, "checker reimbursed");
        assertEq(feeCollector.balance, SPREAD, "spread to the collector");
        assertEq(_account().lockOf(id).checkBudget, BUDGET - FEE);
    }

    function test_budgetExhausted_orderCantBeCheckedUntilToppedUp() public {
        bytes32 id = _order(2_000e8);
        _keeperChecks(id, 2_500e8);
        _keeperChecks(id, 2_501e8);
        _keeperChecks(id, 2_502e8);
        assertEq(_account().lockOf(id).checkBudget, 0);

        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        bytes memory report = prices.report(2_503e8, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.InsufficientCheckBudget.selector, id, FEE, 0));
        adapter.checkBatch(MARKET, ids, report);

        vm.prank(alice.account());
        adapter.topUpCheckBudget(id, FEE);
        _keeperChecks(id, 2_504e8);
        assertEq(keeper.balance, 4 * (FEE - SPREAD));
    }

    function test_topUp_ownerOnly_openOnly() public {
        bytes32 id = _order(2_000e8);
        vm.prank(bob.account());
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotOrderOwner.selector, id));
        adapter.topUpCheckBudget(id, FEE);

        vm.startPrank(alice.account());
        adapter.cancelOrder(id);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.OrderNotOpen.selector, id));
        adapter.topUpCheckBudget(id, FEE);
        vm.stopPrank();
    }

    function test_unusedBudgetReturnedOnCancel() public {
        bytes32 id = _order(2_000e8);
        _keeperChecks(id, 2_500e8);
        vm.prank(alice.account());
        adapter.cancelOrder(id);
        assertEq(_account().freeBalance(WNT), 5 ether - FEE, "only the one check's fee was spent");
    }

    function test_unusedBudgetReturnedOnFill() public {
        bytes32 id = _order(2_400e8);
        _keeperChecks(id, 2_400e8); // fires
        bytes32 gmxKey = _execute(id, _decryptCheck(id));
        UserAccount account = UserAccount(payable(address(_account())));
        vm.prank(gmxHandler);
        account.afterOrderExecution(gmxKey, emptyLog, emptyLog);
        adapter.settle(id);

        uint256 protocolFee = adapter.fillOf(id).protocolFee;
        assertEq(account.freeBalance(WNT), 5 ether - COLLATERAL - EXEC_FEE - protocolFee - FEE);
    }

    function test_batch_chargesEachOrder() public {
        bytes32 a = _order(2_000e8);
        bytes32 b = _order(2_100e8);
        bytes32[] memory ids = new bytes32[](2);
        (ids[0], ids[1]) = (a, b);
        bytes memory report = prices.report(2_500e8, block.timestamp);
        vm.prank(keeper);
        adapter.checkBatch(MARKET, ids, report);
        assertEq(keeper.balance, 2 * (FEE - SPREAD));
        assertEq(feeCollector.balance, 2 * SPREAD);
    }

    function test_reenteringChecker_cannotDoubleCharge() public {
        bytes32 id = _order(2_000e8);
        ReenteringChecker attacker = new ReenteringChecker(adapter, MARKET);
        bytes memory report = prices.report(2_500e8, block.timestamp);
        vm.expectRevert(IUserAccount.TransferFailed.selector); // its re-entry reverts, so its payment fails
        attacker.check(id, report);
        assertEq(_account().lockOf(id).checkBudget, BUDGET, "nothing charged");
    }
}
