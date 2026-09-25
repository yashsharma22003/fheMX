// SPDX-License-Identifier: MIT
// Chainlink Data Streams verifier proxy, as declared in gmx-synthetics
// @ bf30ebb4cff17b7f92f8c738f145e75b871a1576 (contracts/oracle/IChainlinkDataStreamVerifier.sol).
pragma solidity ^0.8.0;

interface IDataStreamsVerifier {
    /// @param payload the full signed report
    /// @param parameterPayload abi-encoded fee token address used for billing
    /// @return verifierResponse the verified, abi-encoded report
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);
}
