// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Turns a caller-supplied signed price report into a verified price.
/// @dev Milestone 6 implements this over Chainlink Data Streams. Tests use a mock.
interface IPriceVerifier {
    /// @param market GMX market the report must price (its index token)
    /// @param report signed report as fetched off-chain
    /// @return price8 index-token price in USD with 8 decimals
    /// @return timestamp observation time of the report, in seconds
    function verify(address market, bytes calldata report) external returns (uint256 price8, uint256 timestamp);
}
