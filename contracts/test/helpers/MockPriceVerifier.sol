// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IPriceVerifier} from "../../src/oracle/IPriceVerifier.sol";

/// @notice Test stand-in for the Data Streams verifier: a "report" is abi.encode(price8, timestamp).
contract MockPriceVerifier is IPriceVerifier {
    function verify(address, bytes calldata signedReport) external pure returns (uint256 price8, uint256 timestamp) {
        return abi.decode(signedReport, (uint256, uint256));
    }

    function report(uint256 price8, uint256 timestamp) external pure returns (bytes memory) {
        return abi.encode(price8, timestamp);
    }
}
