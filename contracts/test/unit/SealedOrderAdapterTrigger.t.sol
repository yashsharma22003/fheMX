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

/// @notice Milestone 4: trigger check -> execute -> settle, on CoFHE and GMX mocks.
contract SealedOrderAdapterTriggerTest is SealedOrderAdapterTestBase {
    address private constant WNT = address(0x4E7);
    address private constant MARKET = address(0x3A2);
    uint256 private constant COLLATERAL = 1 ether; // $24,000 max size at $2,400 and 10x
    uint256 private constant EXEC_FEE = 0.001 ether;

    MockGmxExchangeRouter private router;
    address private gmxHandler = makeAddr("gmxHandler");
    address private feeCollector = makeAddr("feeCollector");
    GmxEventUtils.EventLogData private emptyLog;

    function setUp() public {
        vm.warp(1_800_000_000);
        MockGmxRoleStore roleStore = new MockGmxRoleStore();
        roleStore.grant(gmxHandler, GmxRole.CONTROLLER);
        router = new MockGmxExchangeRouter();
        MockGmxDataStore dataStore = new MockGmxDataStore();
        UserAccount impl = new UserAccount(
            UserAccount.GmxContracts({
                exchangeRouter: address(router),
                router: address(0x0B7),
                orderVault: address(0x0FA),
                dataStore: address(dataStore),
                roleStore: address(roleStore),
                wnt: WNT
            }),
            feeCollector
        );
        _deployAdapter(address(impl), WNT, MARKET, address(new MockGmxReader()), address(dataStore));
        _fund(alice.account(), 5 ether);
    }

    function _longAt(uint64 trigger) internal returns (bytes32) {
        return _order(Plain({isLong: true, size: 5_000e6, trigger: trigger, slippage: 50}));
    }

    function _order(Plain memory p) internal returns (bytes32) {
        return _submitAs(alice, _input(alice, MARKET, COLLATERAL, EXEC_FEE, p));
    }

    function _nextCheck(bytes32 orderId, uint256 price8) internal {
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        _check(MARKET, orderId, price8);
    }

    function _account() internal view returns (IUserAccount) {
        return IUserAccount(adapter.accountOf(alice.account()));
    }

    // ─── trigger semantics ────────────────────────────────────────────────────

    function test_long_notCrossed_decryptsToZeros() public {
        bytes32 id = _longAt(2_400e8);
        _check(MARKET, id, 2_500e8);

        Decrypted memory d = _decryptCheck(id);
        assertEq(d.size, 0);
        assertFalse(d.isLong);
        assertEq(d.slippage, 0);

        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotFired.selector, id));
        _execute(id, d);
    }

    function test_long_firesAtOrBelowTrigger() public {
        bytes32 id = _longAt(2_400e8);
        _check(MARKET, id, 2_400e8);

        Decrypted memory d = _decryptCheck(id);
        assertEq(d.size, 5_000e6);
        assertTrue(d.isLong);
        assertEq(d.slippage, 50);
    }

    function test_short_firesAtOrAboveTrigger_only() public {
        bytes32 id = _order(Plain({isLong: false, size: 5_000e6, trigger: 2_600e8, slippage: 50}));
        _check(MARKET, id, 2_500e8);
        assertEq(_decryptCheck(id).size, 0, "short does not fire below trigger");

        _nextCheck(id, 2_600e8);
        Decrypted memory d = _decryptCheck(id);
        assertEq(d.size, 5_000e6);
        assertFalse(d.isLong);
    }

    function test_leverageCap_blocksOversizedOrderEvenWhenCrossed() public {
        bytes32 id = _order(Plain({isLong: true, size: 25_000e6, trigger: 2_400e8, slippage: 50}));
        _check(MARKET, id, 2_400e8); // max size = 1 ETH * $2,400 * 10 = $24,000
        assertEq(_decryptCheck(id).size, 0);
    }

    function test_intakeInvalidOrder_neverFires() public {
        bytes32 id = _order(Plain({isLong: true, size: 5_000e6, trigger: 2_400e8, slippage: MAX_SLIPPAGE + 1}));
        _check(MARKET, id, 2_000e8);
        assertEq(_decryptCheck(id).size, 0);
    }

    function test_triggerPriceIsNeverMadePublic() public {
        bytes32 id = _longAt(2_400e8);
        _check(MARKET, id, 2_400e8);
        SealedOrderAdapter.SealedOrder memory o = adapter.orderOf(id);
        assertFalse(mockAcl.globalAllowed(uint256(euint64.unwrap(o.triggerPrice8))), "trigger");
        assertFalse(mockAcl.globalAllowed(uint256(euint64.unwrap(o.sizeUsd6))), "raw size handle");
        assertTrue(mockAcl.globalAllowed(uint256(euint64.unwrap(adapter.checkOf(id).revealedSize))), "revealed");
    }

    function test_checkBatch_evaluatesSeveralOrdersWithOneReport() public {
        bytes32 a = _longAt(2_400e8);
        bytes32 b = _longAt(2_300e8);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = a;
        ids[1] = b;
        adapter.checkBatch(MARKET, ids, prices.report(2_350e8, block.timestamp));
        assertEq(_decryptCheck(a).size, 5_000e6, "a fires");
        assertEq(_decryptCheck(b).size, 0, "b does not");
    }

    // ─── report and rate-limit rules (design D3) ──────────────────────────────

    function test_check_rejectsStaleReport() public {
        bytes32 id = _longAt(2_400e8);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256 ts = block.timestamp - MAX_REPORT_AGE - 1;
        bytes memory report = prices.report(2_400e8, ts);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.ReportTooOld.selector, ts, MAX_REPORT_AGE));
        adapter.checkBatch(MARKET, ids, report);
    }

    function test_check_rejectsFutureReport() public {
        bytes32 id = _longAt(2_400e8);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        bytes memory report = prices.report(2_400e8, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.ReportFromFuture.selector, block.timestamp + 1));
        adapter.checkBatch(MARKET, ids, report);
    }

    function test_check_rejectsReportNotNewerThanLastUsed() public {
        bytes32 id = _longAt(2_400e8);
        _check(MARKET, id, 2_500e8);
        uint256 used = block.timestamp;
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        bytes memory report = prices.report(2_400e8, used);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.ReportNotNewer.selector, id, used, used));
        adapter.checkBatch(MARKET, ids, report);
    }

    function test_check_enforcesMinimumInterval() public {
        bytes32 id = _longAt(2_400e8);
        _check(MARKET, id, 2_500e8);
        uint256 next = block.timestamp + MIN_CHECK_INTERVAL;
        vm.warp(block.timestamp + 1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        bytes memory report = prices.report(2_400e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.CheckTooSoon.selector, id, next));
        adapter.checkBatch(MARKET, ids, report);
    }

    function test_check_rejectsUnconfiguredMarket() public {
        bytes32 id = _longAt(2_400e8);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        bytes memory report = prices.report(2_400e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.UnsupportedMarket.selector, address(0xB7C)));
        adapter.checkBatch(address(0xB7C), ids, report);
    }

    function test_check_latestCheckWins() public {
        bytes32 id = _longAt(2_400e8);
        _check(MARKET, id, 2_400e8); // fired...
        _nextCheck(id, 2_500e8); // ...but price moved back before anyone executed
        assertEq(_decryptCheck(id).size, 0);
    }

    // ─── execute ──────────────────────────────────────────────────────────────

    function test_execute_submitsGmxOrderWithRevealedTerms() public {
        bytes32 id = _longAt(2_400e8);
        _check(MARKET, id, 2_400e8);
        bytes32 gmxKey = _execute(id, _decryptCheck(id));

        assertEq(router.ordersCreated(), 1);
        assertEq(router.lastValue(), COLLATERAL + EXEC_FEE);
        assertEq(uint8(adapter.orderOf(id).status), uint8(SealedOrderAdapter.Status.Fired));
        SealedOrderAdapter.Fill memory f = adapter.fillOf(id);
        assertEq(f.gmxKey, gmxKey);
        assertEq(f.sizeDeltaUsd, 5_000e30);
        assertTrue(f.isLong);
        assertEq(f.acceptablePrice, 2_400e8 * 1e4 * 10_050 / 10_000, "price + 0.5% for a long");
        assertEq(f.protocolFee, uint256(5_000e6) * 10 / 10_000 * 1e20 / 2_400e8, "10 bps of $5,000 in ETH");
    }

    function test_execute_rejectsForgedDecryption() public {
        bytes32 id = _longAt(2_400e8);
        _check(MARKET, id, 2_400e8);
        Decrypted memory d = _decryptCheck(id);
        d.size = 20_000e6; // claim a bigger size with the real signature

        vm.expectPartialRevert(bytes4(keccak256("InvalidSigner(address,address)")));
        _execute(id, d);
        assertEq(router.ordersCreated(), 0);
    }

    function test_execute_onlyOncePerFire() public {
        bytes32 id = _longAt(2_400e8);
        _check(MARKET, id, 2_400e8);
        Decrypted memory d = _decryptCheck(id);
        _execute(id, d);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.OrderNotOpen.selector, id));
        _execute(id, d);
    }

    function test_execute_requiresACheck() public {
        bytes32 id = _longAt(2_400e8);
        Decrypted memory d;
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotChecked.selector, id));
        _execute(id, d);
    }

    // ─── settle and fee (fee-model.md) ────────────────────────────────────────

    function _fire() internal returns (bytes32 id, bytes32 gmxKey) {
        id = _longAt(2_400e8);
        _check(MARKET, id, 2_400e8);
        gmxKey = _execute(id, _decryptCheck(id));
    }

    function test_settle_paysFeeOnceAfterFill_andFreesTheRest() public {
        (bytes32 id, bytes32 gmxKey) = _fire();
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotFilled.selector, id));
        adapter.settle(id);

        UserAccount account = UserAccount(payable(address(_account())));
        vm.prank(gmxHandler);
        account.afterOrderExecution(gmxKey, emptyLog, emptyLog);
        adapter.settle(id);

        uint256 fee = adapter.fillOf(id).protocolFee;
        assertEq(feeCollector.balance, fee);
        assertEq(uint8(adapter.orderOf(id).status), uint8(SealedOrderAdapter.Status.Filled));
        // Collateral + first execution fee went to GMX; everything else is free again.
        assertEq(_account().freeBalance(WNT), 5 ether - COLLATERAL - EXEC_FEE - fee);

        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotFired.selector, id));
        adapter.settle(id);
    }

    function test_noFeeWhenGmxCancels_andOwnerCanClose() public {
        (bytes32 id, bytes32 gmxKey) = _fire();
        UserAccount account = UserAccount(payable(address(_account())));
        vm.deal(address(account), address(account).balance + COLLATERAL); // GMX returns collateral
        vm.prank(gmxHandler);
        account.afterOrderCancellation(gmxKey, emptyLog, emptyLog);

        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotFilled.selector, id));
        adapter.settle(id);

        vm.prank(alice.account());
        adapter.cancelOrder(id);
        assertEq(feeCollector.balance, 0);
        assertEq(_account().freeBalance(WNT), 5 ether - EXEC_FEE, "only the spent execution fee is gone");
    }

    function test_protocolFeeNeverExceedsReserve_atMaxLeverage() public {
        bytes32 id = _order(Plain({isLong: true, size: 24_000e6, trigger: 2_400e8, slippage: 50}));
        _check(MARKET, id, 2_400e8);
        _execute(id, _decryptCheck(id));
        assertLe(adapter.fillOf(id).protocolFee, adapter.maxProtocolFee(COLLATERAL));
    }
}
