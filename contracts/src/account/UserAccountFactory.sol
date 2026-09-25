// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IUserAccount} from "./IUserAccount.sol";

/// @notice Deploys one deterministic UserAccount clone per owner, all bound to a single adapter.
contract UserAccountFactory {
    address public immutable implementation;
    address public immutable adapter;

    event AccountCreated(address indexed owner, address indexed account);

    error AccountExists(address owner, address account);

    constructor(address implementation_, address adapter_) {
        implementation = implementation_;
        adapter = adapter_;
    }

    function accountOf(address owner) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(owner));
    }

    function createAccount(address owner) external returns (address account) {
        account = accountOf(owner);
        if (account.code.length != 0) revert AccountExists(owner, account);
        account = Clones.cloneDeterministic(implementation, _salt(owner));
        IUserAccount(account).initialize(owner, adapter);
        emit AccountCreated(owner, account);
    }

    function _salt(address owner) private pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }
}
