// SPDX-License-Identifier: BUSL-1.1
// Vendored from gmx-synthetics @ bf30ebb4cff17b7f92f8c738f145e75b871a1576 (RoleStore, Role).
pragma solidity ^0.8.0;

interface IGmxRoleStore {
    function hasRole(address account, bytes32 roleKey) external view returns (bool);
}

library GmxRole {
    bytes32 internal constant CONTROLLER = keccak256(abi.encode("CONTROLLER"));
}
