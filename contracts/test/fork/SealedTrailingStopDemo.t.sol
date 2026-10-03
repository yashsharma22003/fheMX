// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {NetworkConfig} from "../helpers/NetworkConfig.sol";
import {GmxKeeperSimulator} from "../helpers/GmxKeeperSimulator.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

/// @notice Trailing-stop demo (docs/trailing-stop-proposal.md) on an Arbitrum Sepolia fork with live GMX:
///         the price climbs, the sealed stop follows it up, then the reversal closes the real position.
contract SealedTrailingStopDemoForkTest is SealedOrderAdapterTestBase {
    uint256 private constant COLLATERAL = 0.02 ether;
    uint256 private constant EXEC_FEE = 0.001 ether;
    uint64 private constant SIZE = 100e6; // $100
    uint64 private constant TRAIL_BPS = 500; // 5%

    NetworkConfig.Gmx private gmx;
    NetworkConfig.Market private ethUsd;
    address private feeCollector = makeAddr("feeCollector");
    address private account;

    function setUp() public {
        assertEq(block.chainid, 421614, "fork must be Arbitrum Sepolia");
        string memory json = NetworkConfig.arbitrumSepolia();
        gmx = NetworkConfig.gmx(json);
        ethUsd = NetworkConfig.market(json, "ETH_USD");

        GmxKeeperSimulator.ensureOpenInterestCapacity(gmx, ethUsd.marketToken);
        UserAccount impl = new UserAccount(
            UserAccount.GmxContracts({
                exchangeRouter: gmx.exchangeRouter,
                router: gmx.router,
                orderVault: gmx.orderVault,
                dataStore: gmx.dataStore,
                roleStore: gmx.roleStore,
                wnt: gmx.wnt
            }),
            feeCollector
        );
        _deployAdapterFor(
            address(impl),
            gmx.wnt,
            _market(ethUsd.marketToken, ethUsd.indexToken, ethUsd.longToken, ethUsd.shortToken),
            gmx.reader,
            gmx.dataStore,
            address(0),
            MAX_REPORT_AGE
        );
        _fund(alice.account(), 0.1 ether);
        account = adapter.accountOf(alice.account());
        _openLongViaSealedEntry();
    }

    function _gmxPrices(uint256 ethUsdWhole) internal view returns (GmxKeeperSimulator.TokenPrice[] memory p) {
        p = new GmxKeeperSimulator.TokenPrice[](2);
        uint256 eth = GmxKeeperSimulator.usdPrice(ethUsdWhole, 18);
        uint256 usdc = GmxKeeperSimulator.usdPrice(1, 6);
        p[0] = GmxKeeperSimulator.TokenPrice(ethUsd.longToken, eth, eth);
        p[1] = GmxKeeperSimulator.TokenPrice(ethUsd.shortToken, usdc, usdc);
    }

    function _positionSize() internal view returns (uint256) {
        return IUserAccount(account).positionSizeUsd(ethUsd.marketToken, gmx.wnt, true);
    }

    function _outcome(bytes32 orderId) internal view returns (IUserAccount.GmxOutcome o) {
        (o,) = IUserAccount(account).outcomeOf(orderId);
    }

    /// A sealed $100 long limit entry that fires at $2,390 and fills: the position the trailing stop protects.
    function _openLongViaSealedEntry() internal {
        bytes32 entry = _submitAs(
            alice, _input(alice, ethUsd.marketToken, COLLATERAL, EXEC_FEE, Plain(true, SIZE, 2_400e8, 100))
        );
        _check(ethUsd.marketToken, entry, 2_390e8);
        bytes32 gmxKey = _execute(entry, _decryptCheck(entry));
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _gmxPrices(2_390));
        adapter.settle(entry);
        assertEq(_positionSize(), uint256(SIZE) * 1e24, "position open");
    }

    function _sealedTrailingStop(uint32 slippageBps) internal returns (bytes32) {
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        return _submitAs(
            alice,
            _decreaseInput(
                alice,
                ethUsd.marketToken,
                SealedOrderAdapter.OrderKind.TrailingStop,
                gmx.wnt,
                EXEC_FEE,
                Plain({isLong: true, size: SIZE, trigger: TRAIL_BPS, slippage: slippageBps})
            )
        );
    }

    /// Checks at `price8` after the minimum interval and returns whether that check fired.
    function _fires(bytes32 orderId, uint256 price8) internal returns (bool) {
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        _check(ethUsd.marketToken, orderId, price8);
        return _decryptCheck(orderId).size != 0;
    }

    /// The proposal's walk: 2400 → 2500 → 2600 → 2550 → 2470. The stop ratchets 2280 → 2375 → 2470 and
    /// fires on the reversal, at a level a fixed stop placed at entry would never have reached.
    function test_demo_trailingStop_ratchetsUp_andClosesRealPositionOnReversal() public {
        bytes32 stop = _sealedTrailingStop(100);

        assertFalse(_fires(stop, 2_400e8), "first check sets the marks");
        assertFalse(_fires(stop, 2_500e8), "new high: stop moves up to 2375");
        assertFalse(_fires(stop, 2_600e8), "new high: stop moves up to 2470");
        assertFalse(_fires(stop, 2_550e8), "pullback above the stop");
        SealedOrderAdapter.Marks memory marks = adapter.marksOf(stop);
        assertEq(marks.high, 2_600e8, "high mark is public");
        assertEq(marks.low, 2_400e8);

        assertTrue(_fires(stop, 2_470e8), "5% off the 2600 high");
        bytes32 gmxKey = _execute(stop, _decryptCheck(stop));
        SealedOrderAdapter.Fill memory f = adapter.fillOf(stop);
        assertTrue(f.isLong);
        assertEq(f.sizeDeltaUsd, uint256(SIZE) * 1e24, "closes the whole position");

        uint256 freeBefore = IUserAccount(account).freeBalance(gmx.wnt);
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _gmxPrices(2_470));

        assertEq(uint8(_outcome(stop)), uint8(IUserAccount.GmxOutcome.Executed));
        assertEq(_positionSize(), 0, "position closed");
        assertGt(IUserAccount(account).freeBalance(gmx.wnt), freeBefore, "collateral and profit back as free ETH");

        uint256 feesBefore = feeCollector.balance; // already holds the entry's fee
        adapter.settle(stop);
        assertEq(uint8(adapter.orderOf(stop).status), uint8(SealedOrderAdapter.Status.Filled));
        assertEq(feeCollector.balance - feesBefore, DECREASE_FEE_FLAT, "flat decrease fee");
        assertEq(address(account).balance, IUserAccount(account).freeBalance(gmx.wnt), "nothing left locked");
    }

    /// The price gaps through the stop before GMX's keeper runs; the existing re-arm closes it anyway.
    function test_demo_trailingStopRejectedOnGap_rearmFills() public {
        bytes32 stop = _sealedTrailingStop(0); // zero tolerance; fallback 8% (test base)
        assertFalse(_fires(stop, 2_600e8));
        assertTrue(_fires(stop, 2_470e8));
        bytes32 firstKey = _execute(stop, _decryptCheck(stop));

        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, firstKey, _gmxPrices(2_420));
        assertEq(uint8(_outcome(stop)), uint8(IUserAccount.GmxOutcome.Cancelled));
        assertEq(_positionSize(), uint256(SIZE) * 1e24, "still open after the rejected stop");

        bytes32 secondKey = adapter.rearm(stop);
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, secondKey, _gmxPrices(2_420));

        assertEq(uint8(_outcome(stop)), uint8(IUserAccount.GmxOutcome.Executed));
        assertEq(_positionSize(), 0, "closed on the re-arm");
        adapter.settle(stop);
        assertEq(uint8(adapter.orderOf(stop).status), uint8(SealedOrderAdapter.Status.Filled));
    }
}
