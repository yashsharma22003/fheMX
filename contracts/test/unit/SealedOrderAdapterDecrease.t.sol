// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {GmxRole} from "../../src/interfaces/gmx/IGmxRoleStore.sol";
import {GmxEventUtils} from "../../src/interfaces/gmx/GmxTypes.sol";
import {MockGmxRoleStore, MockGmxExchangeRouter, MockGmxDataStore, MockGmxReader} from "../helpers/GmxMocks.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

/// @notice Milestone 7: stop-loss / take-profit and the D4 re-arm, on CoFHE and GMX mocks.
contract SealedOrderAdapterDecreaseTest is SealedOrderAdapterTestBase {
    address private constant WNT = address(0x4E7);
    address private constant MARKET = address(0x3A2);
    uint256 private constant EXEC_FEE = 0.001 ether;
    uint256 private constant POSITION = 5_000e30; // existing $5,000 position
    bytes32 private constant SIZE_IN_USD = keccak256(abi.encode("SIZE_IN_USD"));

    MockGmxExchangeRouter private router;
    MockGmxDataStore private dataStore;
    MockGmxReader private reader;
    address private gmxHandler = makeAddr("gmxHandler");
    address private feeCollector = makeAddr("feeCollector");
    GmxEventUtils.EventLogData private emptyLog;

    function setUp() public {
        vm.warp(1_800_000_000);
        MockGmxRoleStore roleStore = new MockGmxRoleStore();
        roleStore.grant(gmxHandler, GmxRole.CONTROLLER);
        router = new MockGmxExchangeRouter();
        dataStore = new MockGmxDataStore();
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
        reader = new MockGmxReader();
        _deployAdapter(address(impl), WNT, MARKET, address(reader), address(dataStore));
        _fund(alice.account(), 1 ether);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _account() internal view returns (UserAccount) {
        return UserAccount(payable(adapter.accountOf(alice.account())));
    }

    function _setPosition(bool isLong, uint256 size) internal {
        bytes32 key = keccak256(abi.encode(address(_account()), MARKET, WNT, isLong));
        dataStore.setUint(keccak256(abi.encode(key, SIZE_IN_USD)), size);
    }

    function _decrease(SealedOrderAdapter.OrderKind kind, bool isLong, uint64 size, uint64 trigger, uint32 slip)
        internal
        returns (bytes32)
    {
        return _submitAs(
            alice,
            _decreaseInput(
                alice, MARKET, kind, WNT, EXEC_FEE, Plain({isLong: isLong, size: size, trigger: trigger, slippage: slip})
            )
        );
    }

    function _stopLossLong(uint64 trigger) internal returns (bytes32) {
        return _decrease(SealedOrderAdapter.OrderKind.StopLoss, true, 5_000e6, trigger, 50);
    }

    function _fires(bytes32 id, uint256 price8) internal returns (bool) {
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        _check(MARKET, id, price8);
        return _decryptCheck(id).size != 0;
    }

    function _fireAndExecute(bytes32 id, uint256 price8) internal returns (bytes32 gmxKey) {
        _check(MARKET, id, price8);
        gmxKey = _execute(id, _decryptCheck(id));
    }

    function _gmxCancels(bytes32 gmxKey) internal {
        UserAccount account = _account();
        vm.prank(gmxHandler);
        account.afterOrderCancellation(gmxKey, emptyLog, emptyLog);
    }

    // ─── intake ───────────────────────────────────────────────────────────────

    function test_intake_decreaseLocksFeesAndFlatReserveOnly() public {
        bytes32 id = _stopLossLong(2_300e8);
        IUserAccount.Lock memory l = _account().lockOf(id);
        assertEq(l.collateral, 0);
        assertEq(l.attemptsLeft, 2);
        assertEq(l.protocolFeeReserve, DECREASE_FEE_FLAT);
        assertEq(_account().freeBalance(WNT), 1 ether - 2 * EXEC_FEE - DECREASE_FEE_FLAT);
    }

    function test_intake_decreaseRejectsCollateral() public {
        SealedOrderAdapter.SealedOrderInput memory input = _decreaseInput(
            alice, MARKET, SealedOrderAdapter.OrderKind.StopLoss, WNT, EXEC_FEE, Plain(true, 5_000e6, 2_300e8, 50)
        );
        input.collateral = 1;
        vm.prank(alice.account());
        vm.expectRevert(SealedOrderAdapter.DecreaseTakesNoCollateral.selector);
        adapter.submitOrder(input);
    }

    function test_intake_limitEntryRejectsNonWntCollateral() public {
        SealedOrderAdapter.SealedOrderInput memory input =
            _input(alice, MARKET, 0.1 ether, EXEC_FEE, Plain(true, 100e6, 2_400e8, 50));
        input.collateralToken = address(0x05DC);
        vm.prank(alice.account());
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.UnsupportedCollateral.selector, address(0x05DC)));
        adapter.submitOrder(input);
    }

    // ─── trigger directions ───────────────────────────────────────────────────

    function test_stopLoss_long_firesAtOrBelowTrigger() public {
        bytes32 id = _stopLossLong(2_300e8);
        assertFalse(_fires(id, 2_301e8));
        assertTrue(_fires(id, 2_300e8));
    }

    function test_stopLoss_short_firesAtOrAboveTrigger() public {
        bytes32 id = _decrease(SealedOrderAdapter.OrderKind.StopLoss, false, 5_000e6, 2_700e8, 50);
        assertFalse(_fires(id, 2_699e8));
        assertTrue(_fires(id, 2_700e8));
    }

    function test_takeProfit_long_firesAtOrAboveTrigger() public {
        bytes32 id = _decrease(SealedOrderAdapter.OrderKind.TakeProfit, true, 5_000e6, 2_700e8, 50);
        assertFalse(_fires(id, 2_699e8));
        assertTrue(_fires(id, 2_700e8));
    }

    function test_takeProfit_short_firesAtOrBelowTrigger() public {
        bytes32 id = _decrease(SealedOrderAdapter.OrderKind.TakeProfit, false, 5_000e6, 2_300e8, 50);
        assertFalse(_fires(id, 2_301e8));
        assertTrue(_fires(id, 2_300e8));
    }

    function test_decrease_noLeverageCheck() public {
        // $500k close against 0 collateral would fail any leverage cap; decreases aren't subject to one.
        bytes32 id = _decrease(SealedOrderAdapter.OrderKind.StopLoss, true, 500_000e6, 2_300e8, 50);
        assertTrue(_fires(id, 2_200e8));
    }

    // ─── execute ──────────────────────────────────────────────────────────────

    function test_execute_decreaseTrimsToLivePosition_andSellsWithSlippageBelow() public {
        _setPosition(true, 3_000e30); // user closed part of it manually
        bytes32 id = _stopLossLong(2_300e8);
        _fireAndExecute(id, 2_300e8);

        SealedOrderAdapter.Fill memory f = adapter.fillOf(id);
        assertEq(f.sizeDeltaUsd, 3_000e30, "trimmed from $5,000 to the live $3,000");
        assertEq(f.acceptablePrice, 2_300e8 * 1e4 * 9_950 / 10_000, "long close accepts 0.5% below");
        assertEq(f.protocolFee, DECREASE_FEE_FLAT);
        assertEq(router.lastValue(), EXEC_FEE, "no collateral travels on a decrease");
    }

    /// Known issue 14: slippage applies around GMX's expected fill, so a market's price impact doesn't fail the stop.
    function test_execute_acceptablePriceAnchoredOnGmxExecutionEstimate() public {
        _setPosition(true, POSITION);
        reader.forceExecutionPrice(1_940e8 * 1e4); // GMX expects the close to fill ~15% under the oracle
        bytes32 id = _stopLossLong(2_300e8);
        _fireAndExecute(id, 2_300e8);
        assertEq(adapter.fillOf(id).acceptablePrice, 1_940e8 * 1e4 * 9_950 / 10_000, "0.5% below GMX's expected fill");
    }

    function test_execute_shortClose_buysWithSlippageAbove() public {
        _setPosition(false, POSITION);
        bytes32 id = _decrease(SealedOrderAdapter.OrderKind.StopLoss, false, 5_000e6, 2_700e8, 50);
        _fireAndExecute(id, 2_700e8);
        assertEq(adapter.fillOf(id).acceptablePrice, 2_700e8 * 1e4 * 10_050 / 10_000);
    }

    /// Known issue 2: the position is gone when the stop fires.
    function test_execute_positionGone_voidsOrderAndReleasesFunds() public {
        bytes32 id = _stopLossLong(2_300e8);
        bytes32 gmxKey = _fireAndExecute(id, 2_300e8);

        assertEq(gmxKey, bytes32(0));
        assertEq(router.ordersCreated(), 0, "nothing sent to GMX");
        assertEq(uint8(adapter.orderOf(id).status), uint8(SealedOrderAdapter.Status.Cancelled));
        assertEq(_account().freeBalance(WNT), 1 ether, "fees and reserve released");
    }

    function test_settle_decreaseChargesFlatFee() public {
        _setPosition(true, POSITION);
        bytes32 id = _stopLossLong(2_300e8);
        bytes32 gmxKey = _fireAndExecute(id, 2_300e8);
        UserAccount account = _account();
        vm.prank(gmxHandler);
        account.afterOrderExecution(gmxKey, emptyLog, emptyLog);

        adapter.settle(id);
        assertEq(feeCollector.balance, DECREASE_FEE_FLAT);
    }

    // ─── re-arm (D4, known issues 1 and 3) ────────────────────────────────────

    function test_rearm_afterGmxCancel_usesFallbackSlippageAtFirePrice() public {
        _setPosition(true, POSITION);
        bytes32 id = _stopLossLong(2_300e8); // sealed slippage 0.5%, fallback 8%
        bytes32 firstKey = _fireAndExecute(id, 2_300e8);
        _gmxCancels(firstKey);

        bytes32 secondKey = adapter.rearm(id);
        assertTrue(secondKey != firstKey && secondKey != bytes32(0));
        assertEq(router.ordersCreated(), 2);
        assertEq(adapter.fillOf(id).acceptablePrice, 2_300e8 * 1e4 * 9_200 / 10_000, "8% below the fire price");
        assertEq(_account().lockOf(id).attemptsLeft, 0);
    }

    function test_rearm_onlyOnce() public {
        _setPosition(true, POSITION);
        bytes32 id = _stopLossLong(2_300e8);
        _gmxCancels(_fireAndExecute(id, 2_300e8));
        _gmxCancels(adapter.rearm(id));

        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotRearmable.selector, id));
        adapter.rearm(id);

        vm.prank(alice.account());
        adapter.cancelOrder(id); // owner closes after the second failure
        assertEq(_account().freeBalance(WNT), 1 ether - 2 * EXEC_FEE, "only the two spent execution fees are gone");
    }

    function test_rearm_notAfterFiredCheckExpired() public {
        _setPosition(true, POSITION);
        bytes32 id = _stopLossLong(2_300e8);
        _gmxCancels(_fireAndExecute(id, 2_300e8));
        uint256 expiredAt = adapter.checkOf(id).lastCheckAt + adapter.maxReportAge();
        vm.warp(expiredAt + 1); // the price it fired at is too stale to re-submit at

        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.CheckExpired.selector, id, expiredAt));
        adapter.rearm(id);
        vm.prank(alice.account());
        adapter.cancelOrder(id); // the owner can still close it and free the funds
    }

    function test_rearm_notWhileGmxOrderPendingOrFilled() public {
        _setPosition(true, POSITION);
        bytes32 id = _stopLossLong(2_300e8);
        bytes32 gmxKey = _fireAndExecute(id, 2_300e8);

        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotRearmable.selector, id));
        adapter.rearm(id);

        UserAccount account = _account();
        vm.prank(gmxHandler);
        account.afterOrderExecution(gmxKey, emptyLog, emptyLog);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotRearmable.selector, id));
        adapter.rearm(id);
    }

    /// Known issue 1: an owner's own cancel must not be undone by a re-arm.
    function test_rearm_notAfterOwnerCancelledGmxOrder() public {
        _setPosition(true, POSITION);
        bytes32 id = _stopLossLong(2_300e8);
        bytes32 gmxKey = _fireAndExecute(id, 2_300e8);
        UserAccount account = _account();
        vm.prank(alice.account());
        account.cancelGmxOrder(id);
        _gmxCancels(gmxKey);

        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotRearmable.selector, id));
        adapter.rearm(id);
    }

    /// Known issue 3: the position shrinks between the cancel and the re-arm.
    function test_rearm_retrimsToLivePosition() public {
        _setPosition(true, POSITION);
        bytes32 id = _stopLossLong(2_300e8);
        _gmxCancels(_fireAndExecute(id, 2_300e8));
        _setPosition(true, 1_000e30);

        adapter.rearm(id);
        assertEq(adapter.fillOf(id).sizeDeltaUsd, 1_000e30);
    }

    function test_rearm_voidsIfPositionGone() public {
        _setPosition(true, POSITION);
        bytes32 id = _stopLossLong(2_300e8);
        _gmxCancels(_fireAndExecute(id, 2_300e8));
        _setPosition(true, 0);

        assertEq(adapter.rearm(id), bytes32(0));
        assertEq(uint8(adapter.orderOf(id).status), uint8(SealedOrderAdapter.Status.Cancelled));
        assertEq(_account().freeBalance(WNT), 1 ether - EXEC_FEE);
    }

    function test_rearm_limitEntry_filledOnSecondAttempt_feeChargedOnce() public {
        _fund(alice.account(), 2 ether);
        bytes32 id = _submitAs(alice, _input(alice, MARKET, 1 ether, EXEC_FEE, Plain(true, 5_000e6, 2_400e8, 50)));
        bytes32 firstKey = _fireAndExecute(id, 2_400e8);
        vm.deal(address(_account()), address(_account()).balance + 1 ether); // GMX returns collateral
        _gmxCancels(firstKey);

        bytes32 secondKey = adapter.rearm(id);
        assertEq(adapter.fillOf(id).acceptablePrice, 2_400e8 * 1e4 * 10_800 / 10_000, "long entry: 8% above");
        UserAccount account = _account();
        vm.prank(gmxHandler);
        account.afterOrderExecution(secondKey, emptyLog, emptyLog);

        adapter.settle(id);
        assertEq(feeCollector.balance, adapter.fillOf(id).protocolFee, "fee charged once, on the fill");
    }
}
