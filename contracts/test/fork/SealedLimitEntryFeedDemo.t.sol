// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {ChainlinkFeedPriceVerifier} from "../../src/oracle/ChainlinkFeedPriceVerifier.sol";
import {IAggregatorV3} from "../../src/interfaces/chainlink/IAggregatorV3.sol";
import {NetworkConfig} from "../helpers/NetworkConfig.sol";
import {GmxKeeperSimulator} from "../helpers/GmxKeeperSimulator.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

/// @notice Milestone 6 (revised): trigger checks priced by the free Chainlink ETH/USD Data Feed on an
///         Arbitrum Sepolia fork, end to end with live GMX. No price report is passed to checkBatch.
contract SealedLimitEntryFeedDemoForkTest is SealedOrderAdapterTestBase {
    uint256 private constant COLLATERAL = 0.02 ether;
    uint256 private constant EXEC_FEE = 0.001 ether;
    uint64 private constant SIZE = 100e6;
    uint32 private constant FEED_MAX_AGE = 300; // Sepolia ETH/USD updates every 30-120 s
    uint32 private constant USDC_FEED_MAX_AGE = 90_000; // Sepolia USDC/USD updates every 24 h

    NetworkConfig.Gmx private gmx;
    NetworkConfig.Market private ethUsd;
    address private ethFeed;
    ChainlinkFeedPriceVerifier private verifier;
    address private feeCollector = makeAddr("feeCollector");

    function setUp() public {
        assertEq(block.chainid, 421614, "fork must be Arbitrum Sepolia");
        string memory json = NetworkConfig.arbitrumSepolia();
        gmx = NetworkConfig.gmx(json);
        ethUsd = NetworkConfig.market(json, "ETH_USD");
        ethFeed = NetworkConfig.chainlinkFeed(json, "ETH_USD");
        GmxKeeperSimulator.ensureOpenInterestCapacity(gmx, ethUsd.marketToken);

        address[] memory tokens = new address[](2);
        address[] memory feeds = new address[](2);
        uint32[] memory maxAges = new uint32[](2);
        (tokens[0], feeds[0], maxAges[0]) = (ethUsd.indexToken, ethFeed, FEED_MAX_AGE);
        (tokens[1], feeds[1], maxAges[1]) =
            (ethUsd.shortToken, NetworkConfig.chainlinkFeed(json, "USDC_USD"), USDC_FEED_MAX_AGE);
        verifier = new ChainlinkFeedPriceVerifier(tokens, feeds, maxAges, address(0), 0);

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
            address(verifier),
            FEED_MAX_AGE
        );
        _fund(alice.account(), 0.1 ether);
    }

    /// Simulate the feed publishing a new answer now.
    function _feedPublishes(uint256 price8) internal {
        vm.mockCall(
            ethFeed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(price8), block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _checkWithFeed(bytes32 orderId) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = orderId;
        adapter.checkBatch(ethUsd.marketToken, ids, "");
    }

    function test_liveFeed_isReadableAndFresh() public view {
        (uint256 price8, uint256 updatedAt) = verifier.price(ethUsd.indexToken, "");
        assertGt(price8, 500e8, "plausible ETH price");
        assertLt(price8, 20_000e8, "plausible ETH price");
        assertLe(updatedAt, block.timestamp);
        assertLt(block.timestamp - updatedAt, FEED_MAX_AGE, "feed fresh at the fork block");
    }

    function test_demo_feedPricedLimitEntry_firesAndFills() public {
        (uint256 live8,) = verifier.price(ethUsd.indexToken, "");
        uint64 trigger = uint64(live8 * 99 / 100); // buy 1% below the live price
        bytes32 orderId = _submitAs(
            alice, _input(alice, ethUsd.marketToken, COLLATERAL, EXEC_FEE, Plain(true, SIZE, trigger, 100))
        );

        // The real feed, unmocked: price is above the trigger, so nothing fires.
        _checkWithFeed(orderId);
        assertEq(_decryptCheck(orderId).size, 0);

        // The feed publishes a price through the trigger.
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        uint256 dip8 = uint256(trigger) - 1e8;
        _feedPublishes(dip8);
        _checkWithFeed(orderId);
        bytes32 gmxKey = _execute(orderId, _decryptCheck(orderId));

        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _gmxPrices(dip8 / 1e8));
        (IUserAccount.GmxOutcome outcome,) =
            IUserAccount(adapter.accountOf(alice.account())).outcomeOf(orderId);
        assertEq(uint8(outcome), uint8(IUserAccount.GmxOutcome.Executed));
        adapter.settle(orderId);
        assertEq(uint8(adapter.orderOf(orderId).status), uint8(SealedOrderAdapter.Status.Filled));
        assertGt(feeCollector.balance, 0);
    }

    function test_sameFeedAnswer_cannotBeCheckedTwice() public {
        (uint256 live8,) = verifier.price(ethUsd.indexToken, "");
        bytes32 orderId = _submitAs(
            alice,
            _input(alice, ethUsd.marketToken, COLLATERAL, EXEC_FEE, Plain(true, SIZE, uint64(live8 / 2), 100))
        );
        _checkWithFeed(orderId);
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        vm.expectEmit(address(adapter));
        emit SealedOrderAdapter.CheckSkipped(orderId, SealedOrderAdapter.SkipReason.ReportNotNewer);
        _checkWithFeed(orderId); // no new feed round: nothing new to learn, so no new check
    }

    function test_liveUsdcFeed_acceptedWithinItsOwnMaxAge() public view {
        (uint256 price8,) = verifier.price(ethUsd.shortToken, "");
        assertApproxEqRel(price8, 1e8, 0.02e18, "USDC ~ $1");
    }

    function test_staleFeed_rejected() public {
        (uint256 live8,) = verifier.price(ethUsd.indexToken, "");
        bytes32 orderId = _submitAs(
            alice,
            _input(alice, ethUsd.marketToken, COLLATERAL, EXEC_FEE, Plain(true, SIZE, uint64(live8 / 2), 100))
        );
        vm.warp(block.timestamp + FEED_MAX_AGE + 1);
        // The verifier's per-token max age rejects it before the adapter's own trigger-age rule.
        vm.expectPartialRevert(ChainlinkFeedPriceVerifier.StalePrice.selector);
        _checkWithFeed(orderId);
    }

    function _gmxPrices(uint256 ethUsdWhole) internal view returns (GmxKeeperSimulator.TokenPrice[] memory p) {
        p = new GmxKeeperSimulator.TokenPrice[](2);
        uint256 eth = GmxKeeperSimulator.usdPrice(ethUsdWhole, 18);
        uint256 usdc = GmxKeeperSimulator.usdPrice(1, 6);
        p[0] = GmxKeeperSimulator.TokenPrice(ethUsd.longToken, eth, eth);
        p[1] = GmxKeeperSimulator.TokenPrice(ethUsd.shortToken, usdc, usdc);
    }
}
