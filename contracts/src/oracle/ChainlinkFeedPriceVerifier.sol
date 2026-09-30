// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IPriceVerifier} from "./IPriceVerifier.sol";
import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";

/// @notice Prices tokens from Chainlink Data Feeds (free, push-based, on-chain) instead of Chainlink Data Streams
///         (paid, pull-based). The `report` argument is ignored: the current on-chain answer is the only price,
///         so a caller can't choose which price to submit.
/// @dev Each token has its own feed and maximum age, because heartbeats differ (Sepolia 2026-09-30: ETH and BTC
///      every ~2 min, USDC every 24 h). Feeds and ages are fixed at deployment; there is no admin (design §6).
///      On an L2 mainnet, pass Chainlink's sequencer-uptime feed: prices are rejected while the sequencer is down
///      and for `sequencerGracePeriod` after it comes back. On testnet pass address(0).
contract ChainlinkFeedPriceVerifier is IPriceVerifier {
    uint8 private constant PRICE_DECIMALS = 8;

    struct FeedConfig {
        IAggregatorV3 feed;
        uint32 maxAge;
    }

    mapping(address token => FeedConfig) private _feeds;
    IAggregatorV3 public immutable sequencerUptimeFeed;
    uint256 public immutable sequencerGracePeriod;

    error UnsupportedToken(address token);
    error InvalidPrice(address token, int256 answer);
    error StalePrice(address token, uint256 updatedAt, uint256 maxAge);
    error SequencerDown();
    error SequencerGracePeriod(uint256 upSince);
    error LengthMismatch();

    constructor(
        address[] memory tokens,
        address[] memory feeds,
        uint32[] memory maxAges,
        address sequencerUptimeFeed_,
        uint256 sequencerGracePeriod_
    ) {
        if (tokens.length != feeds.length || tokens.length != maxAges.length) revert LengthMismatch();
        for (uint256 i; i < tokens.length; i++) {
            _feeds[tokens[i]] = FeedConfig(IAggregatorV3(feeds[i]), maxAges[i]);
        }
        sequencerUptimeFeed = IAggregatorV3(sequencerUptimeFeed_);
        sequencerGracePeriod = sequencerGracePeriod_;
    }

    function feedOf(address token) external view returns (address feed, uint32 maxAge) {
        FeedConfig memory f = _feeds[token];
        return (address(f.feed), f.maxAge);
    }

    function price(address token, bytes calldata) external view returns (uint256 price8, uint256 timestamp) {
        FeedConfig memory f = _feeds[token];
        if (address(f.feed) == address(0)) revert UnsupportedToken(token);
        _checkSequencer();

        (, int256 answer,, uint256 updatedAt,) = f.feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(token, answer);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > f.maxAge) {
            revert StalePrice(token, updatedAt, f.maxAge);
        }
        return (_toPrice8(uint256(answer), f.feed.decimals()), updatedAt);
    }

    function _checkSequencer() private view {
        if (address(sequencerUptimeFeed) == address(0)) return;
        (, int256 status, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        if (status != 0) revert SequencerDown(); // 0 = up, 1 = down
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriod(startedAt);
    }

    function _toPrice8(uint256 answer, uint8 decimals) private pure returns (uint256) {
        if (decimals == PRICE_DECIMALS) return answer;
        return decimals > PRICE_DECIMALS
            ? answer / 10 ** (decimals - PRICE_DECIMALS)
            : answer * 10 ** (PRICE_DECIMALS - decimals);
    }
}
