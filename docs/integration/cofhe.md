# Fhenix CoFHE integration reference

What we use from CoFHE, how it works today, and what we trust. Last verified 2026-09-24 against Fhenix's developer docs (repo commit `d8c9bd2`, 2026-09-17) and the installed packages.

## Packages (pinned as a set)

| Package | Version | Use |
| --- | --- | --- |
| `@fhenixprotocol/cofhe-contracts` | 0.2.0 | Solidity `FHE` library. Encrypted handles are `bytes32` since 0.1.0. |
| `@cofhe/mock-contracts` | 0.7.1 | Mock TaskManager, ACL, ZK Verifier, decryption |
| `@cofhe/foundry-plugin` | 0.7.1 | `CofheTest` base contract and `CofheClient` for Foundry tests |
| `@cofhe/sdk` | 0.7.1 | Client-side encryption and `decryptForTx` (used by `client/` and `checker/`) |

SDK 0.7 does not work with 0.6 contracts or plugins; upgrade all together. Legacy, don't use: `cofhejs`, `@fhenixprotocol/cofhe-mock-contracts`, `cofhe-hardhat-plugin`. Docs: [cofhe-docs.fhenix.zone](https://cofhe-docs.fhenix.zone/) (docs.fhenix.io redirects there). Supported testnets: Ethereum Sepolia, Arbitrum Sepolia (421614), Base Sepolia.

## Components

| Component | What it does | Runs where | Operator |
| --- | --- | --- | --- |
| TaskManager | On-chain entry point: creates FHE tasks, holds ACL, stores published decrypt results | On-chain | — |
| Coprocessor | Executes FHE operations off-chain | Off-chain | Fhenix |
| ZK Verifier | Checks proof of knowledge for encrypted inputs, signs a digest covering sender, chain id and consuming contract | Intel TDX enclave | Fhenix |
| Teecryptor | Decrypts ciphertexts for authorized parties and signs results | One Intel TDX enclave | Fhenix |

**Key custody.** The FHE key is split 3-of-6 with Shamir secret sharing among six partners (not named in the docs). Each partner releases its share only to an attested enclave image; the key is rebuilt in Teecryptor's memory and never persisted. The result-signing key is inside the same split secret. So the split protects the key at rest; at runtime the whole key is in one Fhenix-run enclave.

**Planned, not live:** threshold/MPC decryption network, MPC for the ZK Verifier, verified computation, audit, full open-sourcing. Docs describe the codebase as unaudited and not fully open source.

Sources: Teecryptor, Key Management, ZK Verifier and Future Plans pages in [fhenix-developer-docs](https://github.com/FhenixProtocol/fhenix-developer-docs) (`deep-dive/cofhe-components/`).

## Contract-side API we use

Verified by `contracts/test/unit/CofheToolchain.t.sol`.

| Step | Call | Notes |
| --- | --- | --- |
| Accept encrypted input | `FHE.asEuint64(externalEuint64 handle, bytes proof)` | Batch form `asEuint64s(handles[], signature)` shares one signature. Proof is bound to sender, chain and this contract. |
| Keep access to a value | `FHE.allowThis(x)` | Needed on every stored handle. |
| Grant a user access | `FHE.allow(x, user)` | For the order owner to view their own order. |
| Compare / select | `FHE.gte`, `FHE.lte`, `FHE.select(cond, a, b)`, `FHE.asEuint64(uint)` for constants | `select(fired, field, 0)` is the reveal-if-fired pattern. |
| Make decryptable by anyone | `FHE.allowPublic(x)` (or `allowGlobal`) | Lets any checker call `decryptForTx` without a permit. |
| Post a decryption on-chain | `FHE.publishDecryptResult(x, value, signature)` | Typed overloads exist per encrypted type; batch form `publishDecryptResultBatch`. Signature is Teecryptor's (mock signer in tests). |
| Read it | `FHE.getDecryptResultSafe(x)` → `(value, decrypted)` | `decrypted` is false until published. |

`FHE.decrypt` no longer exists; the TaskManager rejects it (`DecryptFunctionNotSupported`).

## Decrypt flow

1. Contract computes the value and calls `FHE.allowPublic` on it.
2. Off-chain, anyone calls the SDK's `decryptForTx(ctHash)` (`.withoutACP()` for public values, `.withACP()` with a permit otherwise). Returns plaintext plus Teecryptor's signature.
3. Anyone calls a contract function that runs `FHE.publishDecryptResult`. The TaskManager checks the signature against `decryptResultSigner`.
4. Contract reads with `getDecryptResultSafe`. Steps 3 and 4 can be the same transaction, which is how `execute()` will work.

In Foundry tests, `CofheClient.decryptForTx_withoutACP(ctHash)` returns `(ctHash, value, signature)` from the mocks.

## Access control and replay

- ACL tiers: transient (within a transaction), persistent (`allow`, `allowThis`, `allowSender`), global/public.
- The TaskManager rejects operations on handles the caller isn't allowed to use; Teecryptor refuses to decrypt without a grant.
- Input proofs are bound to sender, chain id and consuming contract, so one user can't replay another's input.
- Our own rule on top: the adapter never takes a handle as a function parameter and only operates on handles it created from that user's verified input. Required test: user B can't get user A's handle decrypted.

## Testing

- **Local:** inherit `CofheTest`, call `deployMocks()` in `setUp`, `createCofheClient()` then `client.connect(pkey)`. `client.createExternalEuint64(value, consumingContract)` makes a bound input. `expectPlaintext` / `getPlaintext` read mock plaintexts.
- Under forge ≥ 1.0 the mocks exclude their own work from gas metering, so gas reports approximate real costs.
- **Live:** real latency, gas and fees only on Arbitrum Sepolia.

## Not yet verified

- Decrypt round-trip latency and cost on live Arbitrum Sepolia.
- Whether coprocessor result commitments are enforced on-chain.
- Key-split parameters specific to Arbitrum Sepolia (docs don't give per-environment values).
