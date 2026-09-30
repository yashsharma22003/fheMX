// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Prices tokens for the adapter: the index token for triggers, and collateral and pool tokens for
///         caps, fees and GMX's execution-price estimate.
/// @dev Implementations enforce their own per-token freshness (feeds have different heartbeats); the adapter
///      additionally applies its stricter trigger rules to the index price.
interface IPriceVerifier {
    /// @param token token to price
    /// @param report signed report for pull-based sources; ignored by push feeds
    /// @return price8 USD per whole token, 8 decimals
    /// @return timestamp observation time of the price, in seconds
    function price(address token, bytes calldata report) external returns (uint256 price8, uint256 timestamp);
}
