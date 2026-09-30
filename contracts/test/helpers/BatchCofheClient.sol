// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {CofheClient} from "@cofhe/foundry-plugin/CofheClient.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {UnsignedEncryptedInput} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";

/// @notice Exposes the plugin's mixed-type batch encryption, which mirrors `@cofhe/sdk` `encryptInputs`:
///         one signature over several inputs, bound to the sender and the consuming contract.
contract BatchCofheClient is CofheClient {
    function encryptOrder(bool isLong, uint64 size, uint64 trigger, uint32 slippage, address consumingContract)
        public
        returns (
            externalEbool isLongHash,
            externalEuint64 sizeHash,
            externalEuint64 triggerHash,
            externalEuint32 slippageHash,
            bytes memory proof
        )
    {
        uint8[] memory utypes = new uint8[](4);
        uint256[] memory values = new uint256[](4);
        (utypes[0], values[0]) = (Utils.EBOOL_TFHE, isLong ? 1 : 0);
        (utypes[1], values[1]) = (Utils.EUINT64_TFHE, size);
        (utypes[2], values[2]) = (Utils.EUINT64_TFHE, trigger);
        (utypes[3], values[3]) = (Utils.EUINT32_TFHE, slippage);
        (UnsignedEncryptedInput[] memory inputs, bytes memory signature) =
            createEncryptedInputsBatch(utypes, values, consumingContract);
        isLongHash = externalEbool.wrap(bytes32(inputs[0].ctHash));
        sizeHash = externalEuint64.wrap(bytes32(inputs[1].ctHash));
        triggerHash = externalEuint64.wrap(bytes32(inputs[2].ctHash));
        slippageHash = externalEuint32.wrap(bytes32(inputs[3].ctHash));
        proof = signature;
    }
}
