// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {GmxRole} from "../../src/interfaces/gmx/IGmxRoleStore.sol";
import {GmxEventUtils} from "../../src/interfaces/gmx/GmxTypes.sol";
import {MockGmxRoleStore, MockGmxExchangeRouter, MockGmxDataStore, MockGmxReader} from "../helpers/GmxMocks.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

/// @notice Sealed trailing stop (docs/trailing-stop-proposal.md), on CoFHE and GMX mocks.
contract SealedOrderAdapterTrailingTest is SealedOrderAdapterTestBase {
    address private constant WNT = address(0x4E7);
    address private constant MARKET = address(0x3A2);
    uint256 private constant EXEC_FEE = 0.001 ether;
    uint256 private constant POSITION = 5_000e30;
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

    function _trailing(bool isLong, uint64 trailBps) internal returns (bytes32) {
        return _submitAs(
            alice,
            _decreaseInput(
                alice,
                MARKET,
                SealedOrderAdapter.OrderKind.TrailingStop,
                WNT,
                EXEC_FEE,
                Plain({isLong: isLong, size: 5_000e6, trigger: trailBps, slippage: 50})
            )
        );
    }

    /// Checks at `price8` after the minimum interval and returns whether that check fired.
    function _fires(bytes32 id, uint256 price8) internal returns (bool) {
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        _check(MARKET, id, price8);
        return _decryptCheck(id).size != 0;
    }

    function _marks(bytes32 id) internal view returns (uint256 high, uint256 low) {
        SealedOrderAdapter.Marks memory mk = adapter.marksOf(id);
        return (mk.high, mk.low);
    }

    // ─── water marks ──────────────────────────────────────────────────────────

    function test_marks_startAtFirstCheck_andOnlyWiden() public {
        bytes32 id = _trailing(true, 2_000); // 20%: wide enough that none of these checks fires
        assertFalse(_fires(id, 2_400e8));
        (uint256 high, uint256 low) = _marks(id);
        assertEq(high, 2_400e8);
        assertEq(low, 2_400e8);

        assertFalse(_fires(id, 2_600e8));
        assertFalse(_fires(id, 2_500e8));
        assertFalse(_fires(id, 2_350e8));
        (high, low) = _marks(id);
        assertEq(high, 2_600e8, "high keeps the best price, not the latest");
        assertEq(low, 2_350e8);
    }

    function test_marks_notTrackedForOtherKinds() public {
        bytes32 id = _submitAs(
            alice,
            _decreaseInput(
                alice, MARKET, SealedOrderAdapter.OrderKind.StopLoss, WNT, EXEC_FEE, Plain(true, 5_000e6, 2_300e8, 50)
            )
        );
        _fires(id, 2_400e8);
        (uint256 high, uint256 low) = _marks(id);
        assertEq(high, 0);
        assertEq(low, 0);
    }

    // ─── trigger ──────────────────────────────────────────────────────────────

    /// The proposal's example: 2400 → 2500 → 2600 → 2550 → 2470, trail 5%, fires at 2470.
    function test_long_stopRatchetsUp_andFiresOnRetrace() public {
        bytes32 id = _trailing(true, 500);
        assertFalse(_fires(id, 2_400e8));
        assertFalse(_fires(id, 2_500e8));
        assertFalse(_fires(id, 2_600e8));
        assertFalse(_fires(id, 2_550e8));
        assertFalse(_fires(id, 2_471e8), "just above 2600 * 95%");
        assertTrue(_fires(id, 2_470e8), "exactly 2600 * 95%");
    }

    function test_long_doesNotFireAtTheOriginalLevelAfterRatchet() public {
        bytes32 id = _trailing(true, 500);
        assertFalse(_fires(id, 2_400e8));
        assertFalse(_fires(id, 2_600e8));
        // 2400's stop was 2280; after the high moved to 2600 the stop is 2470, so 2480 is safe and 2470 isn't.
        assertFalse(_fires(id, 2_480e8));
        assertTrue(_fires(id, 2_465e8));
    }

    function test_short_followsTheLow_andFiresOnRally() public {
        bytes32 id = _trailing(false, 500);
        assertFalse(_fires(id, 2_400e8));
        assertFalse(_fires(id, 2_200e8));
        assertFalse(_fires(id, 2_000e8));
        assertFalse(_fires(id, 2_099e8), "just under 2000 * 105%");
        assertTrue(_fires(id, 2_100e8), "exactly 2000 * 105%");
    }

    function test_newExtremeNeverFires() public {
        bytes32 longId = _trailing(true, 1);
        bytes32 shortId = _trailing(false, 1);
        assertFalse(_fires(longId, 2_400e8));
        assertFalse(_fires(shortId, 2_400e8));
        assertFalse(_fires(longId, 2_500e8));
        assertFalse(_fires(shortId, 2_300e8));
    }

    function test_firstCheckNeverFires() public {
        bytes32 id = _trailing(true, 1);
        assertFalse(_fires(id, 2_400e8), "the mark starts at this price, so there is no retrace yet");
    }

    function test_fireIsSticky_untilExpiry() public {
        bytes32 id = _trailing(true, 500);
        assertFalse(_fires(id, 2_600e8));
        assertTrue(_fires(id, 2_400e8));
        assertTrue(_fires(id, 2_590e8), "a recovery before execution doesn't erase the fire");

        vm.warp(block.timestamp + MAX_REPORT_AGE + 1);
        assertFalse(_fires(id, 2_590e8), "after expiry a fresh check decides");
    }

    // ─── intake caps ──────────────────────────────────────────────────────────

    function test_intake_trailOf100PercentOrMoreNeverFires() public {
        bytes32 full = _trailing(true, 10_000);
        bytes32 over = _trailing(true, 20_000); // would wrap BPS - trail
        _fires(full, 2_400e8);
        _fires(over, 2_400e8);
        assertFalse(_fires(full, 1e8));
        assertFalse(_fires(over, 1e8));
    }

    function test_intake_zeroTrailNeverFires() public {
        bytes32 id = _trailing(true, 0);
        _fires(id, 2_400e8);
        assertFalse(_fires(id, 2_000e8));
    }

    function test_priceAboveCapDoesNotFire() public {
        bytes32 id = _trailing(true, 500);
        uint256 huge = type(uint64).max / 20_000 + 1;
        assertFalse(_fires(id, huge));
        assertFalse(_fires(id, huge / 2), "no euint64 overflow, the check just doesn't fire");
    }

    // ─── execute / settle (reused decrease path) ──────────────────────────────

    function test_execute_closesPositionAtFirePrice() public {
        _setPosition(true, POSITION);
        bytes32 id = _trailing(true, 500);
        _fires(id, 2_600e8);
        assertTrue(_fires(id, 2_470e8));
        bytes32 gmxKey = _execute(id, _decryptCheck(id));

        SealedOrderAdapter.Fill memory f = adapter.fillOf(id);
        assertTrue(gmxKey != bytes32(0));
        assertEq(f.sizeDeltaUsd, POSITION);
        assertTrue(f.isLong, "closes the long");
        assertEq(f.acceptablePrice, 2_470e8 * 1e4 * 9_950 / 10_000, "long close accepts 0.5% below");
        assertEq(f.protocolFee, DECREASE_FEE_FLAT);

        UserAccount account = _account();
        vm.prank(gmxHandler);
        account.afterOrderExecution(gmxKey, emptyLog, emptyLog);
        adapter.settle(id);
        assertEq(feeCollector.balance, DECREASE_FEE_FLAT);
    }

    function test_execute_revertsIfNotFired() public {
        _setPosition(true, POSITION);
        bytes32 id = _trailing(true, 500);
        _fires(id, 2_600e8);
        _fires(id, 2_500e8);
        Decrypted memory d = _decryptCheck(id);
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotFired.selector, id));
        _execute(id, d);
    }

    function test_execute_positionGone_voids() public {
        bytes32 id = _trailing(true, 500);
        _fires(id, 2_600e8);
        _fires(id, 2_400e8);
        assertEq(_execute(id, _decryptCheck(id)), bytes32(0));
        assertEq(uint8(adapter.orderOf(id).status), uint8(SealedOrderAdapter.Status.Cancelled));
        assertEq(_account().freeBalance(WNT), 1 ether);
    }
}
