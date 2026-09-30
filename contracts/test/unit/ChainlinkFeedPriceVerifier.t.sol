// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ChainlinkFeedPriceVerifier} from "../../src/oracle/ChainlinkFeedPriceVerifier.sol";
import {MockAggregator} from "../helpers/GmxMocks.sol";

contract ChainlinkFeedPriceVerifierTest is Test {
    address private constant ETH_MARKET = address(0xE7);
    address private constant BTC_MARKET = address(0xB7C);

    MockAggregator private ethFeed;
    MockAggregator private btcFeed18;
    MockAggregator private sequencer;
    ChainlinkFeedPriceVerifier private verifier;

    function setUp() public {
        vm.warp(1_800_000_000);
        ethFeed = new MockAggregator(8);
        btcFeed18 = new MockAggregator(18);
        ethFeed.set(2_500e8, block.timestamp - 60);
        btcFeed18.set(60_000e18, block.timestamp - 30);
        verifier = _verifier(address(0));
    }

    function _verifier(address sequencerFeed) internal returns (ChainlinkFeedPriceVerifier) {
        address[] memory markets = new address[](2);
        address[] memory feeds = new address[](2);
        (markets[0], feeds[0]) = (ETH_MARKET, address(ethFeed));
        (markets[1], feeds[1]) = (BTC_MARKET, address(btcFeed18));
        return new ChainlinkFeedPriceVerifier(markets, feeds, sequencerFeed, 1 hours);
    }

    function test_returnsFeedAnswerAndUpdateTime_reportIgnored() public view {
        (uint256 price8, uint256 ts) = verifier.verify(ETH_MARKET, hex"deadbeef");
        assertEq(price8, 2_500e8);
        assertEq(ts, block.timestamp - 60);
    }

    function test_normalisesDecimalsTo8() public view {
        (uint256 price8,) = verifier.verify(BTC_MARKET, "");
        assertEq(price8, 60_000e8);
    }

    function test_rejectsUnknownMarket() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkFeedPriceVerifier.UnsupportedMarket.selector, address(0xBAD)));
        verifier.verify(address(0xBAD), "");
    }

    function test_rejectsNonPositiveAnswer() public {
        ethFeed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkFeedPriceVerifier.InvalidPrice.selector, ETH_MARKET, int256(0)));
        verifier.verify(ETH_MARKET, "");
    }

    function test_sequencerDown_rejected() public {
        MockAggregator seq = new MockAggregator(0);
        seq.set(1, block.timestamp - 2 hours); // 1 = down
        ChainlinkFeedPriceVerifier v = _verifier(address(seq));
        vm.expectRevert(ChainlinkFeedPriceVerifier.SequencerDown.selector);
        v.verify(ETH_MARKET, "");
    }

    function test_sequencerJustRestarted_rejectedDuringGracePeriod() public {
        MockAggregator seq = new MockAggregator(0);
        seq.set(0, block.timestamp - 10 minutes);
        ChainlinkFeedPriceVerifier v = _verifier(address(seq));
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkFeedPriceVerifier.SequencerGracePeriod.selector, block.timestamp - 10 minutes)
        );
        v.verify(ETH_MARKET, "");
    }

    function test_sequencerUpPastGracePeriod_accepted() public {
        MockAggregator seq = new MockAggregator(0);
        seq.set(0, block.timestamp - 2 hours);
        (uint256 price8,) = _verifier(address(seq)).verify(ETH_MARKET, "");
        assertEq(price8, 2_500e8);
    }

    function test_rejectsMismatchedConfig() public {
        address[] memory markets = new address[](1);
        vm.expectRevert(ChainlinkFeedPriceVerifier.LengthMismatch.selector);
        new ChainlinkFeedPriceVerifier(markets, new address[](0), address(0), 0);
    }
}
