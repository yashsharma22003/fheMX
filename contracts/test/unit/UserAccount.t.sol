// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {UserAccountFactory} from "../../src/account/UserAccountFactory.sol";
import {GmxRole} from "../../src/interfaces/gmx/IGmxRoleStore.sol";
import {GmxEventUtils} from "../../src/interfaces/gmx/GmxTypes.sol";
import {MockGmxRoleStore, MockGmxExchangeRouter, MockGmxDataStore} from "../helpers/GmxMocks.sol";

contract UserAccountTest is Test {
    address private constant WNT = address(0x4E7);
    address private constant ORDER_VAULT = address(0x0FA);
    address private constant MARKET = address(0x3A2);

    address private owner = makeAddr("owner");
    address private adapter = makeAddr("adapter");
    address private gmxHandler = makeAddr("gmxHandler");
    address private stranger = makeAddr("stranger");
    address private feeCollector = makeAddr("feeCollector");

    MockGmxRoleStore private roleStore;
    MockGmxExchangeRouter private router;
    UserAccountFactory private factory;
    UserAccount private account;

    bytes32 private constant ORDER = keccak256("order-1");
    uint256 private constant COLLATERAL = 1 ether;
    uint256 private constant FEE = 0.01 ether;
    uint256 private constant PROTOCOL_FEE_RESERVE = 0.05 ether;
    uint256 private constant LOCKED_TOTAL = COLLATERAL + 2 * FEE + PROTOCOL_FEE_RESERVE;

    GmxEventUtils.EventLogData private emptyLog;

    function setUp() public {
        roleStore = new MockGmxRoleStore();
        roleStore.grant(gmxHandler, GmxRole.CONTROLLER);
        router = new MockGmxExchangeRouter();
        UserAccount impl = new UserAccount(
            UserAccount.GmxContracts({
                exchangeRouter: address(router),
                router: address(router),
                orderVault: ORDER_VAULT,
                dataStore: address(new MockGmxDataStore()),
                roleStore: address(roleStore),
                wnt: WNT
            }),
            feeCollector
        );
        factory = new UserAccountFactory(address(impl), adapter);
        account = UserAccount(payable(factory.createAccount(owner)));
        vm.deal(address(account), 2 ether);
    }

    function _lock() internal {
        vm.prank(adapter);
        account.lock(ORDER, WNT, COLLATERAL, FEE, 2, PROTOCOL_FEE_RESERVE);
    }

    function _request() internal pure returns (IUserAccount.OrderRequest memory r) {
        r = IUserAccount.OrderRequest(MARKET, true, true, 2_000e30, COLLATERAL, type(uint256).max, 500_000);
    }

    function _submit() internal returns (bytes32 gmxKey) {
        vm.prank(adapter);
        gmxKey = account.submit(ORDER, _request());
    }

    // ─── factory and initialization ───────────────────────────────────────────

    function test_factory_createsDeterministicAccountBoundToAdapter() public view {
        assertEq(address(account), factory.accountOf(owner));
        assertEq(account.owner(), owner);
        assertEq(account.adapter(), adapter);
    }

    function test_factory_rejectsSecondAccountForSameOwner() public {
        vm.expectRevert(abi.encodeWithSelector(UserAccountFactory.AccountExists.selector, owner, address(account)));
        factory.createAccount(owner);
    }

    function test_initialize_onlyOnce() public {
        vm.expectRevert(IUserAccount.AlreadyInitialized.selector);
        account.initialize(stranger, stranger);
    }

    function test_implementation_cannotBeInitialized() public {
        UserAccount impl = UserAccount(payable(factory.implementation()));
        vm.expectRevert(IUserAccount.AlreadyInitialized.selector);
        impl.initialize(stranger, stranger);
    }

    // ─── lock / release ───────────────────────────────────────────────────────

    function test_lock_reservesFundsFromFreeBalance() public {
        _lock();
        assertEq(account.freeBalance(WNT), 2 ether - LOCKED_TOTAL);
        IUserAccount.Lock memory l = account.lockOf(ORDER);
        assertEq(l.collateral, COLLATERAL);
        assertEq(l.attemptsLeft, 2);
        assertEq(l.protocolFeeReserve, PROTOCOL_FEE_RESERVE);
    }

    function test_lock_onlyAdapter() public {
        vm.prank(stranger);
        vm.expectRevert(IUserAccount.NotAdapter.selector);
        account.lock(ORDER, WNT, COLLATERAL, FEE, 2, 0);
    }


    function test_lock_rejectsMoreThanFreeBalance() public {
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.InsufficientFreeBalance.selector, 3 ether, 2 ether));
        account.lock(ORDER, WNT, 3 ether, 0, 0, 0);
    }

    function test_lock_rejectsReusedOrderId() public {
        _lock();
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.LockExists.selector, ORDER));
        account.lock(ORDER, WNT, 0.1 ether, 0, 0, 0);
    }

    function test_release_returnsReserveToFreeBalance() public {
        _lock();
        vm.prank(adapter);
        account.release(ORDER);
        assertEq(account.freeBalance(WNT), 2 ether);
    }

    // ─── submit ───────────────────────────────────────────────────────────────

    function test_submit_sendsCollateralPlusOneFeeAndMarksPending() public {
        _lock();
        bytes32 gmxKey = _submit();

        assertEq(router.lastValue(), COLLATERAL + FEE);
        (IUserAccount.GmxOutcome outcome, bytes32 key) = account.outcomeOf(ORDER);
        assertEq(uint8(outcome), uint8(IUserAccount.GmxOutcome.Pending));
        assertEq(key, gmxKey);
        IUserAccount.Lock memory l = account.lockOf(ORDER);
        assertEq(l.collateral, 0);
        assertEq(l.attemptsLeft, 1);
        assertEq(account.freeBalance(WNT), 2 ether - LOCKED_TOTAL, "free balance unaffected by submit");
    }

    function test_submit_onlyAdapter() public {
        _lock();
        vm.prank(stranger);
        vm.expectRevert(IUserAccount.NotAdapter.selector);
        account.submit(ORDER, _request());
    }

    function test_submit_rejectsCollateralAboveLock() public {
        _lock();
        IUserAccount.OrderRequest memory r = _request();
        r.collateralDelta = COLLATERAL + 1;
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.CollateralExceedsLock.selector, COLLATERAL + 1, COLLATERAL));
        account.submit(ORDER, r);
    }

    function test_submit_rejectsDecreaseForNow() public {
        _lock();
        IUserAccount.OrderRequest memory r = _request();
        r.isIncrease = false;
        vm.prank(adapter);
        vm.expectRevert(IUserAccount.DecreaseNotSupported.selector);
        account.submit(ORDER, r);
    }

    function test_submit_rejectsWhileInFlight_andReleaseToo() public {
        _lock();
        _submit();
        vm.startPrank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.OrderInFlight.selector, ORDER));
        account.submit(ORDER, _request());
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.OrderInFlight.selector, ORDER));
        account.release(ORDER);
        vm.stopPrank();
    }

    // ─── callbacks ────────────────────────────────────────────────────────────

    function test_callbacks_rejectCallerWithoutControllerRole() public {
        _lock();
        bytes32 gmxKey = _submit();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.NotGmxController.selector, stranger));
        account.afterOrderCancellation(gmxKey, emptyLog, emptyLog);
    }

    function test_callbacks_ignoreUnknownOrderKeys() public {
        vm.prank(gmxHandler);
        account.afterOrderExecution(keccak256("someone-elses-order"), emptyLog, emptyLog);
        (IUserAccount.GmxOutcome outcome,) = account.outcomeOf(ORDER);
        assertEq(uint8(outcome), uint8(IUserAccount.GmxOutcome.None));
    }

    function test_executionCallback_recordsExecuted() public {
        _lock();
        bytes32 gmxKey = _submit();
        vm.prank(gmxHandler);
        account.afterOrderExecution(gmxKey, emptyLog, emptyLog);
        (IUserAccount.GmxOutcome outcome,) = account.outcomeOf(ORDER);
        assertEq(uint8(outcome), uint8(IUserAccount.GmxOutcome.Executed));
    }

    function test_cancellationCallback_keepsReturnedCollateralLockedForRearm() public {
        _lock();
        bytes32 gmxKey = _submit();
        uint256 freeBefore = account.freeBalance(WNT);

        vm.deal(address(account), address(account).balance + COLLATERAL); // GMX returns the collateral
        vm.prank(gmxHandler);
        account.afterOrderCancellation(gmxKey, emptyLog, emptyLog);

        (IUserAccount.GmxOutcome outcome,) = account.outcomeOf(ORDER);
        assertEq(uint8(outcome), uint8(IUserAccount.GmxOutcome.Cancelled));
        assertEq(account.lockOf(ORDER).collateral, COLLATERAL, "collateral back under the lock");
        assertEq(account.freeBalance(WNT), freeBefore, "returned collateral is not withdrawable");

        vm.prank(adapter);
        account.submit(ORDER, _request()); // second attempt uses the re-credited collateral
        assertEq(account.lockOf(ORDER).attemptsLeft, 0);
    }

    // ─── protocol fee ─────────────────────────────────────────────────────────

    function test_protocolFee_onlyAfterExecution() public {
        _lock();
        _submit();
        vm.prank(adapter);
        vm.expectRevert(
            abi.encodeWithSelector(IUserAccount.FeeNotPayable.selector, ORDER, IUserAccount.GmxOutcome.Pending)
        );
        account.payProtocolFee(ORDER, 0.01 ether);
    }

    function test_protocolFee_notOnCancelledOrder() public {
        _lock();
        bytes32 gmxKey = _submit();
        vm.deal(address(account), address(account).balance + COLLATERAL);
        vm.prank(gmxHandler);
        account.afterOrderCancellation(gmxKey, emptyLog, emptyLog);

        vm.prank(adapter);
        vm.expectRevert(
            abi.encodeWithSelector(IUserAccount.FeeNotPayable.selector, ORDER, IUserAccount.GmxOutcome.Cancelled)
        );
        account.payProtocolFee(ORDER, 0.01 ether);
    }

    function test_protocolFee_paidOnceToCollector_restFreed() public {
        _lock();
        bytes32 gmxKey = _submit();
        vm.prank(gmxHandler);
        account.afterOrderExecution(gmxKey, emptyLog, emptyLog);
        uint256 freeBefore = account.freeBalance(WNT);

        vm.startPrank(adapter);
        account.payProtocolFee(ORDER, 0.02 ether);
        assertEq(feeCollector.balance, 0.02 ether);
        assertEq(account.freeBalance(WNT), freeBefore + PROTOCOL_FEE_RESERVE - 0.02 ether, "unused reserve freed");

        vm.expectRevert(abi.encodeWithSelector(IUserAccount.FeeExceedsReserve.selector, 0.02 ether, 0));
        account.payProtocolFee(ORDER, 0.02 ether);
        vm.stopPrank();
    }

    function test_protocolFee_cannotExceedReserve() public {
        _lock();
        bytes32 gmxKey = _submit();
        vm.prank(gmxHandler);
        account.afterOrderExecution(gmxKey, emptyLog, emptyLog);
        vm.prank(adapter);
        vm.expectRevert(
            abi.encodeWithSelector(IUserAccount.FeeExceedsReserve.selector, 1 ether, PROTOCOL_FEE_RESERVE)
        );
        account.payProtocolFee(ORDER, 1 ether);
    }

    // ─── owner ────────────────────────────────────────────────────────────────

    function test_withdraw_onlyFreeBalance() public {
        _lock();
        uint256 free = account.freeBalance(WNT);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.InsufficientFreeBalance.selector, free + 1, free));
        account.withdraw(WNT, free + 1, owner);
        account.withdraw(WNT, free, owner);
        vm.stopPrank();
        assertEq(owner.balance, free);
        assertEq(account.freeBalance(WNT), 0);
    }

    function test_withdraw_onlyOwner() public {
        vm.prank(adapter);
        vm.expectRevert(IUserAccount.NotOwner.selector);
        account.withdraw(WNT, 1, adapter);
    }
}
