# Decision log

Every design decision so far, why it was made, and what it replaced. Newest first within each group. Dates are when the decision was made or the fact was checked.

Design choices D1–D5 are recommended defaults from [design-v0.2.md](design-v0.2.md#open-decisions-recommended-defaults), adopted for the first build. Revisit them there, then record the change here.

## Design choices

| Date | ID | Decision | Rationale | Replaces |
| --- | --- | --- | --- | --- |
| 2026-09-24 | D1 | Market is a public field; side, size, trigger and slippage stay encrypted. | With market encrypted, every trigger check must compare against every supported market, so cost grows with market count. Market is inferable anyway: from the open position (stop-loss, take-profit) or the deposit token (limit entry). | v0.1: market encrypted. |
| 2026-09-24 | D2 | One minimal-proxy clone per user is the GMX `account`, `receiver`, `cancellationReceiver` and `callbackContract`. | GMX keys positions by (account, market, collateralToken, isLong). If the adapter were the account, users' positions in the same market would merge. | v0.1: adapter as `callbackContract`, account model unspecified. |
| 2026-09-24 | D3 | Trigger checks are permissionless: `checkBatch(orderIds[], report)` with a caller-supplied Data Streams report, max report age, strictly increasing report timestamp per order, minimum check interval per order and a per-check fee. | Keeps "no standing execution key". The caller chooses the report, so the rules stop them picking a favourable stale one. The interval limits how tightly repeated checks can bracket the trigger. | v0.1: "adapter periodically dispatches" checks, which a contract can't do by itself. |
| 2026-09-24 | D4 | On a slippage cancel, re-arm once in a separate permissionless `rearm()` transaction with a user-set public fallback bound. Two execution fees escrowed at intake. | Worst case for a stop-loss is never executing. A ciphertext-derived value must never widen the bound. It can't run in the callback: GMX's `executeOrder` and `createOrder` are both `globalNonReentrant`. | v0.1: no policy for triggered orders that fail. |
| 2026-09-24 | D5 | Lead with limit-entry privacy; stop-loss and take-profit still supported. | For decrease orders only the trigger price is truly hidden. Limit entries hide side, size and trigger. | v0.1: pitch led with stop-loss and stop hunting. |
| 2026-09-24 | — | Collateral for each order is locked in the clone at intake. | A point-in-time balance check at intake goes stale if the user withdraws, and the order would then be revealed and fail. | Design-review v0.2, first pass: size ≤ clone balance at intake. |
| 2026-09-24 | — | Decrease orders are trimmed to the live position size at execute time. | GMX reverts `MarketDecrease` orders larger than the position (`InvalidDecreaseOrderSize`); the user may have reduced the position by hand. | Nothing; found in the third review pass. |
| 2026-09-24 | — | Caps are checked on ciphertext at intake, then re-checked in plaintext at execute. | Checking only after reveal leaks a rejected order for nothing. | v0.1: caps checked after decryption only. |
| 2026-09-24 | — | One decrypt round trip per fire: compute `select(fired, field, 0)` for every field and decrypt them together. | Saves a full round trip per fire. A non-fire decrypts to zeros and reveals only "not yet". Costs more decryption per check, so it needs measuring (§10). | v0.1: decrypt the boolean, then decrypt the fields. |
| 2026-09-24 | — | Clone callbacks accept only `msg.sender` holding GMX `CONTROLLER`, and only for order keys the clone created. | Forged callbacks could mark orders `Rearmable` or release locks. | Nothing. |
| 2026-09-24 | — | Order type (limit entry / stop-loss / take-profit) is public. | Encrypting it adds another select per check and hides little. | Unstated in v0.1. |
| 2026-09-24 | — | Private-RPC submission removed from the roadmap. | Arbitrum has no public mempool: the sequencer is first-come-first-served, with Timeboost's express lane. The real exposure is the revealed order waiting for a GMX keeper. | v0.1 roadmap item 1. |
| 2026-09-24 | — | Reveal batching stays deprioritized. | Cosmetic without randomized delays and relayer rotation; expensive with them. | Unchanged from v0.1. |

| 2026-09-25 | — | Build order: interface-first. `IUserAccount` and a minimal clone (milestone 2) before sealed intake and the end-to-end demo (3–4); full clone after (5). | Earlier end-to-end demo of the novel FHE path without throwaway code: the adapter codes against the interface, and the clone is completed behind it. | Proposed order with the full clone before sealed intake. |
| 2026-09-25 | — | First demo covers limit entries only. | Strongest privacy case (D5); decrease orders need the size-trim and re-arm work. | — |

| 2026-09-25 | D6 | Fee model: fee on successful fill only, increase/decrease split, immutable public parameters, receive-only collector. Spec in [fee-model.md](fee-model.md). | Covers operating costs without charging for orders that never fire, without a new admin key, and without leaking anything before reveal. | — |
| 2026-09-25 | — | Protocol fee is reserved in the clone at lock, sized from the maximum possible order (locked collateral × max leverage × bps), and paid only after `Executed`. | A limit-entry fill leaves no proceeds in the clone to sweep from, and a reserve sized from the real order would publish the sealed size. | Fee spec §5: sweep from settled proceeds. |
| 2026-09-25 | — | Fee amount computed at execute from the revealed size and the verified reference price, not from callback event data. | Callbacks only record outcomes; GMX market increases fill in full or cancel, so revealed size = filled size. | Fee spec §5: `filledSizeUsd` from `afterOrderExecution`. |
| 2026-09-25 | — | Clone interface `IUserAccount`: the clone builds GMX order parameters itself and always routes receiver, cancellation receiver and callbacks to itself; outcomes are pull-based (`outcomeOf`); adapter fixed at creation. | The clone enforces "funds return to the user" even against a faulty adapter; no calls into the adapter from gas-capped GMX callbacks. | — |
| 2026-09-25 | — | Callback authentication (GMX `CONTROLLER` + own order keys) built in milestone 2 instead of 5. | Three lines; removes the riskiest part of known issue 8 early. | Milestone 5 plan. |

## Corrected facts

Where a working assumption turned out to be wrong. Kept so the same mistake isn't made again.

| Date | Assumed | Actually | How found |
| --- | --- | --- | --- |
| 2026-09-24 | Fhenix decryption is done by a threshold network (a reviewer's correction to v0.1). | Decryption is done by Teecryptor, one Fhenix-operated TEE on Intel TDX; the key is split 3-of-6 among partners and rebuilt inside the enclave. Threshold decryption is planned, not live. v0.1's "attested enclave" wording was right. | Fhenix developer docs (Teecryptor, Key Management, Future Plans pages), commit d8c9bd2. Fhenix corrected its own docs in a PR titled "Teecryptor decrypts, not the Threshold Network". |
| 2026-09-24 | GMX V2 has an on-chain oracle price to poll between executions. | Prices are set only inside the executing transaction and cleared afterwards (`OracleModule.withOraclePrices` → `clearAllPrices`). | `gmx-synthetics` source. |
| 2026-09-24 | A local fork gives a live FHE coprocessor. | The coprocessor and Teecryptor watch the real chain only. Local testing uses CoFHE mocks. | Fhenix tooling docs; `@cofhe/foundry-plugin`. |
| 2026-09-24 | Private RPC (Flashbots Protect, MEV Blocker) closes mempool exposure. | Those are Ethereum products; Arbitrum has no public mempool. | Arbitrum docs. |
| 2026-09-24 | `FHE.decrypt` + async result. | `FHE.decrypt` is removed. Flow is `allow*` → off-chain `decryptForTx` → `FHE.publishDecryptResult` → `getDecryptResultSafe`. | Fhenix docs; verified in our unit tests on mocks. |
| 2026-09-24 | GMX Sepolia addresses from `gmx-synthetics` main (`deployments/`, `docs/arbitrumSepolia-deployments.md`). | Those are stale. The live deployment is listed in the [official docs](https://docs.gmx.io/docs/api/contracts/addresses/), pinned to commit `bf30ebb` on the `updates` branch. A second, nearly idle router/handler pair also holds CONTROLLER; picking by role alone chose the wrong one. | Fork test failure, then on-chain role and event checks. See [integration/gmx-v2.md](integration/gmx-v2.md#addresses). |
| 2026-09-24 | The 3-of-6 key split might be the ZK Verifier's key share count. | 3-of-6 is the FHE decryption keyset. The ZK Verifier's signer key is split separately (5 on staging, 3 on testnet, per a reviewer). | Teecryptor and Key Management pages. |

## Deferred

Known gaps accepted for now, tracked in [KNOWN_ISSUES.md](KNOWN_ISSUES.md). Decided 2026-09-24: build first, fix each when its code is written, starting from a failing test.
