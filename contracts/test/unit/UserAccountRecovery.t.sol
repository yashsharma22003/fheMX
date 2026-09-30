// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {UserAccountFactory} from "../../src/account/UserAccountFactory.sol";
import {GmxRole} from "../../src/interfaces/gmx/IGmxRoleStore.sol";
import {GmxEventUtils} from "../../src/interfaces/gmx/GmxTypes.sol";
import {MockGmxRoleStore, MockGmxExchangeRouter, MockGmxDataStore, MockERC20} from "../helpers/GmxMocks.sol";

/// @notice Milestone 5: ERC20 collateral, reconcile for lost callbacks, owner cancel and manual close.
contract UserAccountRecoveryTest is Test {
    address private constant WNT = address(0x4E7);
    address private constant MARKET = address(0x3A2);
    bytes32 private constant ORDER_LIST = keccak256(abi.encode("ORDER_LIST"));
    bytes32 private constant SIZE_IN_USD = keccak256(abi.encode("SIZE_IN_USD"));

    address private owner = makeAddr("owner");
    address private adapter = makeAddr("adapter");
    address private gmxHandler = makeAddr("gmxHandler");
    address private feeCollector = makeAddr("feeCollector");

    MockGmxExchangeRouter private router;
    MockGmxDataStore private dataStore;
    MockERC20 private usdc;
    UserAccount private account;
    GmxEventUtils.EventLogData private emptyLog;

    bytes32 private constant ORDER = keccak256("order-1");
    uint256 private constant FEE = 0.001 ether;
    uint256 private constant SIZE = 1_000e30;

    function setUp() public {
        MockGmxRoleStore roleStore = new MockGmxRoleStore();
        roleStore.grant(gmxHandler, GmxRole.CONTROLLER);
        router = new MockGmxExchangeRouter();
        dataStore = new MockGmxDataStore();
        usdc = new MockERC20("USDC", 6);
        UserAccount impl = new UserAccount(
            UserAccount.GmxContracts({
                exchangeRouter: address(router),
                router: address(router),
                orderVault: address(0x0FA),
                dataStore: address(dataStore),
                roleStore: address(roleStore),
                wnt: WNT
            }),
            feeCollector
        );
        account = UserAccount(payable(new UserAccountFactory(address(impl), adapter).createAccount(owner)));
        vm.deal(address(account), 1 ether);
        usdc.mint(address(account), 10_000e6);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _request(uint256 collateral) internal pure returns (IUserAccount.OrderRequest memory) {
        return IUserAccount.OrderRequest(MARKET, WNT, true, true, SIZE, collateral, type(uint256).max, 500_000);
    }

    function _usdcRequest(uint256 collateral) internal view returns (IUserAccount.OrderRequest memory r) {
        r = _request(collateral);
        r.collateralToken = address(usdc);
    }

    function _lockAndSubmitEth() internal returns (bytes32 gmxKey) {
        vm.startPrank(adapter);
        account.lock(ORDER, WNT, 0.5 ether, FEE, 2, 0.01 ether);
        gmxKey = account.submit(ORDER, _request(0.5 ether));
        vm.stopPrank();
        dataStore.setContains(ORDER_LIST, gmxKey, true);
    }

    function _setPositionSize(address token, uint256 size) internal {
        bytes32 positionKey = keccak256(abi.encode(address(account), MARKET, token, true));
        dataStore.setUint(keccak256(abi.encode(positionKey, SIZE_IN_USD)), size);
    }

    function _outcome() internal view returns (IUserAccount.GmxOutcome o) {
        (o,) = account.outcomeOf(ORDER);
    }

    // ─── ERC20 collateral ─────────────────────────────────────────────────────

    function test_erc20_collateralAndReserveInToken_feesInEth() public {
        vm.prank(adapter);
        account.lock(ORDER, address(usdc), 1_000e6, FEE, 2, 10e6);

        assertEq(account.freeBalance(address(usdc)), 10_000e6 - 1_010e6);
        assertEq(account.freeBalance(WNT), 1 ether - 2 * FEE);
    }

    function test_erc20_submitSendsTokensThroughRouterAndFeeAsEth() public {
        vm.startPrank(adapter);
        account.lock(ORDER, address(usdc), 1_000e6, FEE, 2, 10e6);
        account.submit(ORDER, _usdcRequest(1_000e6));
        vm.stopPrank();

        assertEq(router.lastTokenAmount(), 1_000e6);
        assertEq(router.lastValue(), FEE, "only the execution fee travels as ETH");
        assertEq(usdc.balanceOf(address(account)), 9_000e6);
        assertEq(account.freeBalance(address(usdc)), 10_000e6 - 1_010e6, "free balance unchanged by submit");
    }

    function test_erc20_protocolFeePaidInCollateralToken() public {
        vm.startPrank(adapter);
        account.lock(ORDER, address(usdc), 1_000e6, FEE, 2, 10e6);
        bytes32 gmxKey = account.submit(ORDER, _usdcRequest(1_000e6));
        vm.stopPrank();
        vm.prank(gmxHandler);
        account.afterOrderExecution(gmxKey, emptyLog, emptyLog);

        vm.prank(adapter);
        account.payProtocolFee(ORDER, 4e6);
        assertEq(usdc.balanceOf(feeCollector), 4e6);
    }

    function test_withdraw_erc20FreeBalanceOnly() public {
        vm.prank(adapter);
        account.lock(ORDER, address(usdc), 1_000e6, FEE, 2, 0);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.InsufficientFreeBalance.selector, 9_001e6, 9_000e6));
        account.withdraw(address(usdc), 9_001e6, owner);
        account.withdraw(address(usdc), 9_000e6, owner);
        vm.stopPrank();
        assertEq(usdc.balanceOf(owner), 9_000e6);
    }

    // ─── reconcile (known issue 9) ────────────────────────────────────────────

    function test_reconcile_rejectsOrderStillAtGmx() public {
        bytes32 gmxKey = _lockAndSubmitEth();
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.OrderStillAtGmx.selector, gmxKey));
        account.reconcile(ORDER);
    }

    function test_reconcile_executedWhenPositionGrew() public {
        bytes32 gmxKey = _lockAndSubmitEth();
        dataStore.setContains(ORDER_LIST, gmxKey, false);
        _setPositionSize(WNT, SIZE);

        assertEq(uint8(account.reconcile(ORDER)), uint8(IUserAccount.GmxOutcome.Executed));
        assertEq(uint8(_outcome()), uint8(IUserAccount.GmxOutcome.Executed));
        assertEq(account.pendingCount(), 0);

        vm.prank(adapter);
        account.payProtocolFee(ORDER, 0.001 ether); // fee still collectable without the callback
        assertEq(feeCollector.balance, 0.001 ether);
    }

    function test_reconcile_cancelledWhenCollateralReturned() public {
        bytes32 gmxKey = _lockAndSubmitEth();
        dataStore.setContains(ORDER_LIST, gmxKey, false);
        vm.deal(address(account), address(account).balance + 0.5 ether); // GMX returned the collateral

        assertEq(uint8(account.reconcile(ORDER)), uint8(IUserAccount.GmxOutcome.Cancelled));
        assertEq(account.lockOf(ORDER).collateral, 0.5 ether, "back under the lock");
    }

    function test_reconcile_refusesWhenNeitherOutcomeFits() public {
        bytes32 gmxKey = _lockAndSubmitEth();
        dataStore.setContains(ORDER_LIST, gmxKey, false); // gone, but no position and no collateral back
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.CannotReconcile.selector, ORDER));
        account.reconcile(ORDER);
    }

    function test_reconcile_onlyForPendingOrders_andLateCallbackIsIgnored() public {
        bytes32 gmxKey = _lockAndSubmitEth();
        dataStore.setContains(ORDER_LIST, gmxKey, false);
        _setPositionSize(WNT, SIZE);
        account.reconcile(ORDER);

        vm.expectRevert(abi.encodeWithSelector(IUserAccount.NotInFlight.selector, ORDER));
        account.reconcile(ORDER);

        vm.prank(gmxHandler);
        account.afterOrderCancellation(gmxKey, emptyLog, emptyLog); // late, contradictory callback
        assertEq(uint8(_outcome()), uint8(IUserAccount.GmxOutcome.Executed), "first settlement stands");
    }

    // ─── owner cancel and manual close ────────────────────────────────────────

    function test_cancelGmxOrder_ownerOnly_pendingOnly() public {
        bytes32 gmxKey = _lockAndSubmitEth();
        vm.prank(adapter);
        vm.expectRevert(IUserAccount.NotOwner.selector);
        account.cancelGmxOrder(ORDER);

        vm.prank(owner);
        account.cancelGmxOrder(ORDER);
        assertEq(router.lastCancelled(), gmxKey);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.NotInFlight.selector, keccak256("other")));
        account.cancelGmxOrder(keccak256("other"));
    }

    function _closeRequest() internal pure returns (UserAccount.ClosePositionRequest memory) {
        return UserAccount.ClosePositionRequest(MARKET, WNT, true, SIZE, 0, 0, FEE, 500_000);
    }

    function test_closePosition_blockedWhileAdapterOrderInFlight() public {
        _lockAndSubmitEth();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.AdapterOrdersInFlight.selector, 1));
        account.closePosition(_closeRequest());
    }

    function test_closePosition_paysFeeFromFreeEth_andBlocksNewSubmits() public {
        vm.prank(owner);
        bytes32 closeKey = account.closePosition(_closeRequest());
        assertEq(router.lastValue(), FEE);
        assertEq(account.manualCloseKey(), closeKey);
        dataStore.setContains(ORDER_LIST, closeKey, true);

        vm.startPrank(adapter);
        account.lock(ORDER, WNT, 0.5 ether, FEE, 2, 0);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.ManualCloseInFlight.selector, closeKey));
        account.submit(ORDER, _request(0.5 ether));
        vm.stopPrank();

        // The close completes (callback lost); once GMX no longer holds it, submits work again.
        dataStore.setContains(ORDER_LIST, closeKey, false);
        vm.prank(adapter);
        account.submit(ORDER, _request(0.5 ether));
        assertEq(account.manualCloseKey(), bytes32(0));
    }

    function test_closePosition_callbackClearsManualClose() public {
        vm.prank(owner);
        bytes32 closeKey = account.closePosition(_closeRequest());
        vm.prank(gmxHandler);
        account.afterOrderExecution(closeKey, emptyLog, emptyLog);
        assertEq(account.manualCloseKey(), bytes32(0));
    }

    function test_closePosition_ownerOnly() public {
        vm.prank(adapter);
        vm.expectRevert(IUserAccount.NotOwner.selector);
        account.closePosition(_closeRequest());
    }

    // ─── decrease orders (milestone 7) ────────────────────────────────────────

    function _lockAndSubmitDecrease() internal returns (bytes32 gmxKey) {
        _setPositionSize(WNT, 3 * SIZE);
        IUserAccount.OrderRequest memory r = _request(0);
        r.isIncrease = false;
        vm.startPrank(adapter);
        account.lock(ORDER, WNT, 0, FEE, 2, 0);
        gmxKey = account.submit(ORDER, r);
        vm.stopPrank();
        dataStore.setContains(ORDER_LIST, gmxKey, true);
        assertEq(router.lastValue(), FEE, "decrease sends only the execution fee");
    }

    function test_reconcileDecrease_executedWhenPositionShrank() public {
        bytes32 gmxKey = _lockAndSubmitDecrease();
        dataStore.setContains(ORDER_LIST, gmxKey, false);
        _setPositionSize(WNT, 2 * SIZE);
        assertEq(uint8(account.reconcile(ORDER)), uint8(IUserAccount.GmxOutcome.Executed));
    }

    function test_reconcileDecrease_cancelledWhenPositionUnchanged() public {
        bytes32 gmxKey = _lockAndSubmitDecrease();
        dataStore.setContains(ORDER_LIST, gmxKey, false);
        assertEq(uint8(account.reconcile(ORDER)), uint8(IUserAccount.GmxOutcome.Cancelled));
    }

    function test_reconcileDecrease_refusesPartialChange() public {
        bytes32 gmxKey = _lockAndSubmitDecrease();
        dataStore.setContains(ORDER_LIST, gmxKey, false);
        _setPositionSize(WNT, 3 * SIZE - 1); // shrank, but by less than the order: something else happened
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.CannotReconcile.selector, ORDER));
        account.reconcile(ORDER);
    }

    function test_cancelGmxOrder_marksCancelledByOwner() public {
        _lockAndSubmitEth();
        assertFalse(account.cancelledByOwner(ORDER));
        vm.prank(owner);
        account.cancelGmxOrder(ORDER);
        assertTrue(account.cancelledByOwner(ORDER));
    }
}
