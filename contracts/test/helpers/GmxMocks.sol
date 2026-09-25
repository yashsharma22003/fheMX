// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Minimal GMX stand-ins for unit tests (no fork). Fork tests use the real contracts.
contract MockGmxRoleStore {
    mapping(address => mapping(bytes32 => bool)) public hasRole;

    function grant(address account, bytes32 role) external {
        hasRole[account][role] = true;
    }
}

contract MockGmxExchangeRouter {
    uint256 public ordersCreated;
    uint256 public lastValue;

    /// @dev Accepts the [sendWnt, createOrder] multicall the account makes; returns a fresh order key.
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        lastValue = msg.value;
        ordersCreated++;
        results[data.length - 1] = abi.encode(keccak256(abi.encode("gmx-order", ordersCreated)));
    }
}

contract MockGmxDataStore {
    mapping(bytes32 => uint256) public getUint;
}
