// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IPriceVerifier} from "../../src/oracle/IPriceVerifier.sol";

/// @notice Test stand-in for a price source. A non-empty report is abi.encode(price8, timestamp) (used for the
///         index price in `checkBatch`); with an empty report, the token's price set by the test is returned
///         with the current timestamp.
contract MockPriceVerifier is IPriceVerifier {
    mapping(address token => uint256) public priceOf;

    error NoPrice(address token);

    function setPrice(address token, uint256 price8) external {
        priceOf[token] = price8;
    }

    function price(address token, bytes calldata signedReport) external view returns (uint256 price8, uint256 timestamp) {
        if (signedReport.length != 0) return abi.decode(signedReport, (uint256, uint256));
        price8 = priceOf[token];
        if (price8 == 0) revert NoPrice(token);
        return (price8, block.timestamp);
    }

    function report(uint256 price8, uint256 timestamp) external pure returns (bytes memory) {
        return abi.encode(price8, timestamp);
    }
}
