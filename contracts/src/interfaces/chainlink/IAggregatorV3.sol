// SPDX-License-Identifier: MIT
// Chainlink Data Feeds (AggregatorV3Interface), as published in smartcontractkit/chainlink.
pragma solidity ^0.8.0;

interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
