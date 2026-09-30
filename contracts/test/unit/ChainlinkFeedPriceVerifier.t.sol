// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ChainlinkFeedPriceVerifier} from "../../src/oracle/ChainlinkFeedPriceVerifier.sol";
import {MockAggregator} from "../helpers/GmxMocks.sol";

contract ChainlinkFeedPriceVerifierTest is Test {
    address private constant WETH = address(0xE7);
    address private constant BTC = address(0xB7C);

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
        address[] memory tokens = new address[](2);
        address[] memory feeds = new address[](2);
        uint32[] memory maxAges = new uint32[](2);
        (tokens[0], feeds[0], maxAges[0]) = (WETH, address(ethFeed), 300);
        (tokens[1], feeds[1], maxAges[1]) = (BTC, address(btcFeed18), 300);
        return new ChainlinkFeedPriceVerifier(tokens, feeds, maxAges, sequencerFeed, 1 hours);
    }

    function test_returnsFeedAnswerAndUpdateTime_reportIgnored() public view {
        (uint256 price8, uint256 ts) = verifier.price(WETH, hex"deadbeef");
        assertEq(price8, 2_500e8);
        assertEq(ts, block.timestamp - 60);
    }

    function test_normalisesDecimalsTo8() public view {
        (uint256 price8,) = verifier.price(BTC, "");
        assertEq(price8, 60_000e8);
    }

    function test_rejectsUnknownMarket() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkFeedPriceVerifier.UnsupportedToken.selector, address(0xBAD)));
        verifier.price(address(0xBAD), "");
    }

    function test_rejectsNonPositiveAnswer() public {
        ethFeed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkFeedPriceVerifier.InvalidPrice.selector, WETH, int256(0)));
        verifier.price(WETH, "");
    }

    function test_sequencerDown_rejected() public {
        MockAggregator seq = new MockAggregator(0);
        seq.set(1, block.timestamp - 2 hours); // 1 = down
        ChainlinkFeedPriceVerifier v = _verifier(address(seq));
        vm.expectRevert(ChainlinkFeedPriceVerifier.SequencerDown.selector);
        v.price(WETH, "");
    }

    function test_sequencerJustRestarted_rejectedDuringGracePeriod() public {
        MockAggregator seq = new MockAggregator(0);
        seq.set(0, block.timestamp - 10 minutes);
        ChainlinkFeedPriceVerifier v = _verifier(address(seq));
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkFeedPriceVerifier.SequencerGracePeriod.selector, block.timestamp - 10 minutes)
        );
        v.price(WETH, "");
    }

    function test_sequencerUpPastGracePeriod_accepted() public {
        MockAggregator seq = new MockAggregator(0);
        seq.set(0, block.timestamp - 2 hours);
        (uint256 price8,) = _verifier(address(seq)).price(WETH, "");
        assertEq(price8, 2_500e8);
    }

    function test_rejectsPriceOlderThanTokenMaxAge() public {
        ethFeed.set(2_500e8, block.timestamp - 301);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkFeedPriceVerifier.StalePrice.selector, WETH, block.timestamp - 301, 300)
        );
        verifier.price(WETH, "");
    }

    function test_maxAgeIsPerToken() public {
        MockAggregator usdcFeed = new MockAggregator(8);
        usdcFeed.set(1e8, block.timestamp - 20 hours); // stablecoin feeds update once a day
        address[] memory tokens = new address[](2);
        address[] memory feeds = new address[](2);
        uint32[] memory maxAges = new uint32[](2);
        (tokens[0], feeds[0], maxAges[0]) = (WETH, address(ethFeed), 300);
        (tokens[1], feeds[1], maxAges[1]) = (address(0x05DC), address(usdcFeed), 25 hours);
        ChainlinkFeedPriceVerifier v = new ChainlinkFeedPriceVerifier(tokens, feeds, maxAges, address(0), 0);
        (uint256 usdc,) = v.price(address(0x05DC), "");
        assertEq(usdc, 1e8);
    }

    function test_rejectsMismatchedConfig() public {
        address[] memory tokens = new address[](1);
        vm.expectRevert(ChainlinkFeedPriceVerifier.LengthMismatch.selector);
        new ChainlinkFeedPriceVerifier(tokens, new address[](0), new uint32[](0), address(0), 0);
    }
}
