// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {CofheTest} from "@cofhe/foundry-plugin/CofheTest.sol";
import {CofheClient} from "@cofhe/foundry-plugin/CofheClient.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @dev Test-only probe exercising the CoFHE primitives the adapter will rely on:
///      verified input, encrypted compare, select-to-zero, public decrypt, publish + read back.
contract CofheProbe {
    euint64 public stored;
    euint64 public revealed;

    function store(externalEuint64 value, bytes calldata proof) external {
        stored = FHE.asEuint64(value, proof);
        FHE.allowThis(stored);
    }

    function revealIfAtLeast(uint64 threshold) external {
        ebool fired = FHE.gte(stored, FHE.asEuint64(threshold));
        revealed = FHE.select(fired, stored, FHE.asEuint64(0));
        FHE.allowThis(revealed);
        FHE.allowPublic(revealed);
    }

    function publish(uint64 result, bytes calldata signature) external {
        FHE.publishDecryptResult(revealed, result, signature);
    }

    function readRevealed() external view returns (uint64 value, bool ready) {
        return FHE.getDecryptResultSafe(revealed);
    }
}

/// @notice Smoke test: proves the CoFHE mock toolchain works end to end. Not adapter logic.
contract CofheToolchainTest is CofheTest {
    uint256 private constant USER_PKEY = 0xA11CE;
    CofheClient private client;
    CofheProbe private probe;

    function setUp() public {
        deployMocks();
        client = createCofheClient();
        client.connect(USER_PKEY);
        probe = new CofheProbe();
    }

    function _store(uint64 value) internal {
        (externalEuint64 handle, bytes memory proof) = client.createExternalEuint64(value, address(probe));
        vm.prank(client.account());
        probe.store(handle, proof);
    }

    function test_encryptedInputRoundTrip() public {
        _store(2500);
        expectPlaintext(probe.stored(), uint64(2500));
    }

    function test_selectRevealsValueWhenConditionHolds() public {
        _store(2500);
        probe.revealIfAtLeast(2000);
        _publishAndExpect(2500);
    }

    function test_selectRevealsZeroWhenConditionFails() public {
        _store(2500);
        probe.revealIfAtLeast(3000);
        _publishAndExpect(0);
    }

    function _publishAndExpect(uint64 expected) internal {
        (, uint256 value, bytes memory signature) = client.decryptForTx_withoutACP(euint64.unwrap(probe.revealed()));
        assertEq(value, expected);

        (, bool readyBefore) = probe.readRevealed();
        assertFalse(readyBefore);

        probe.publish(uint64(value), signature);
        (uint64 published, bool ready) = probe.readRevealed();
        assertTrue(ready);
        assertEq(published, expected);
    }
}
