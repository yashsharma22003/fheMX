// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IPriceVerifier} from "./IPriceVerifier.sol";
import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";

/// @notice Prices trigger checks from Chainlink Data Feeds (free, push-based, on-chain) instead of
///         Chainlink Data Streams (paid, pull-based). The `report` argument is ignored: the current
///         on-chain answer is the only price, so a caller can't choose which price to submit.
/// @dev Freshness is enforced by the adapter (`maxReportAge` against `updatedAt`, and a strictly newer
///      `updatedAt` per order). Feeds are fixed at deployment; there is no admin (design §6).
///      On an L2 mainnet, pass Chainlink's sequencer-uptime feed: prices are rejected while the sequencer
///      is down and for `sequencerGracePeriod` after it comes back. On testnet pass address(0).
contract ChainlinkFeedPriceVerifier is IPriceVerifier {
    uint8 private constant PRICE_DECIMALS = 8;

    mapping(address market => IAggregatorV3) public feedOf;
    IAggregatorV3 public immutable sequencerUptimeFeed;
    uint256 public immutable sequencerGracePeriod;

    error UnsupportedMarket(address market);
    error InvalidPrice(address market, int256 answer);
    error SequencerDown();
    error SequencerGracePeriod(uint256 upSince);
    error LengthMismatch();

    constructor(
        address[] memory markets,
        address[] memory feeds,
        address sequencerUptimeFeed_,
        uint256 sequencerGracePeriod_
    ) {
        if (markets.length != feeds.length) revert LengthMismatch();
        for (uint256 i; i < markets.length; i++) {
            feedOf[markets[i]] = IAggregatorV3(feeds[i]);
        }
        sequencerUptimeFeed = IAggregatorV3(sequencerUptimeFeed_);
        sequencerGracePeriod = sequencerGracePeriod_;
    }

    function verify(address market, bytes calldata) external view returns (uint256 price8, uint256 timestamp) {
        IAggregatorV3 feed = feedOf[market];
        if (address(feed) == address(0)) revert UnsupportedMarket(market);
        _checkSequencer();

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(market, answer);
        return (_toPrice8(uint256(answer), feed.decimals()), updatedAt);
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
