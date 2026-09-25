# Sealed Order Privacy Layer for GMX Perpetuals — Design v0.2

*As of 2026-09-24*

v0.2 keeps the v0.1 architecture but corrects six design-changing assumptions about GMX V2, CoFHE and Arbitrum, and adds a recommended default for each of five open design decisions. The headline change: for stop-loss and take-profit orders, only the trigger price is truly hidden, so v1 leads with limit-entry privacy.

*Amended after a second review against GMX's cloned source (§§3, 4, 5, 6, 7, 10, D4): two design-changing bugs fixed (the D4 re-arm cannot fire from inside a GMX callback — `executeOrder`/`createOrder` are `globalNonReentrant` — so it now runs through a separate `rearm()` transaction with its own escrowed execution fee; and the intake-time balance cap went stale after withdrawal, fixed by locking order collateral at intake instead of checking a point-in-time balance), plus callback-sender authentication via GMX's `CONTROLLER` role, `refundExecutionFee` support, order type made an explicit public field, and `checkBatch` added to amortize Data Streams verification cost across orders sharing a report. A third pass caught one more staleness bug specific to decrease orders (stop-loss/take-profit size isn't collateral-locked, so it can exceed the position if the user manually reduces it — fixed by capping to the live position size at execute time) plus several places where earlier edits hadn't propagated.*

*Open items deferred to implementation are tracked in [KNOWN_ISSUES.md](KNOWN_ISSUES.md).*

---

## What changed from v0.1

Six corrections change the design; the rest are wording and trust-model fixes.

| Section | Change | Why |
| --- | --- | --- |
| §2 Scope, §5 Sealed fields | Market is public by default; v1 pitch leads with limit-entry privacy | Encrypted market forces an all-markets comparison per check. For stop-loss and take-profit, market, side and size are inferable from the public position anyway. |
| §3 Architecture | Per-user clone contract is the GMX account and `callbackContract` | GMX keys positions by (account, market, collateralToken, isLong). One shared adapter account would merge users into one position. |
| §4 Lifecycle | Trigger checks consume a verified Chainlink Data Streams report; decrypt round trips collapsed; re-arm policy added | GMX V2 keeps no oracle price on-chain between executions. Data Streams is pull-based, so the caller supplies the report. |
| §4 Lifecycle | Caps checked on ciphertext at intake | Checking after reveal leaks a rejected order for nothing. |
| §5 Sealed fields | Trigger price "revealed to within one polling interval's price move" | The fire-time bracket is the real leak; pre-fire "false" results leak little. |
| §6 Trust model | Rewritten: decryption is a single Fhenix-operated TEE with a 3-of-6 split key, not a threshold network; caps split into independent vs ciphertext-derived; standing keys listed | v0.1 mixed enclave and threshold language, and treated caps as a confidentiality safeguard. Fhenix's docs confirm the enclave model; threshold decryption is planned, not live. |
| §7, §11 | Mempool exposure and private-RPC roadmap item removed | Arbitrum has no public mempool. The real exposure is the public `createOrder` waiting for a keeper. |
| §9 Testing | Two tiers: fork + CoFHE mocks + own keeper simulator; live Arbitrum Sepolia for end-to-end | The CoFHE coprocessor and GMX keepers watch the real chain, not a local fork. |
| §8 Reveal batching | Unchanged | — |

---

## Open decisions (recommended defaults)

Five design forks must be settled before code starts. Each has a recommended default below; the rest of this doc assumes those defaults. D3 and D4 interact most: the report-submission rules in D3 set how often D4's failure path is hit.

| # | Decision | Recommended default | Main alternative | Depends on |
| --- | --- | --- | --- | --- |
| D1 | Market field | Public; side, size, trigger, slippage stay encrypted | Encrypted market, cost linear in supported markets, hard cap on market count | — |
| D2 | Account model | One minimal-proxy clone per user as GMX account and `callbackContract` | One clone per user per market | — |
| D3 | Who runs trigger checks | Permissionless, with on-chain rate limit and Data Streams report rules | Restricted to a designated keeper set | D1 |
| D4 | Triggered order fails its slippage bound | Re-arm once, in a separate permissionless transaction, with a wider public bound; then leave the revealed order to the user | Accept the reveal and stop | D3 |
| D5 | Lead use case | Limit-entry privacy | Stop-loss / take-profit privacy | D1 |

### D1 — Market field: public

With market public, each check is one encrypted comparison per direction rather than one per supported market. Little privacy is lost: for stop-loss and take-profit the market is visible from the open position, and for limit entries the deposit token already hints at it. Side stays encrypted and is handled with `FHE.select` over both comparison directions (two comparisons per check). Revisit only if a use case needs market privacy and can bound the market count.

### D2 — Account model: per-user clone

Each user gets a minimal-proxy clone that holds their collateral, is the `account` on GMX, and receives callbacks. Only the owning user and the adapter's order path can act through it. The clone must also expose the user-side paths v0.1 left out:

- Manual close or reduce of any position the clone holds
- Add collateral, or withdraw collateral not locked by a live order
- Cancel a sealed order, which releases its collateral lock and second execution fee
- Withdraw idle balances
- Handle a GMX liquidation of the position under a pending sealed order (the order is cancelled on the next check)

Per-market clones would reduce cross-market linkage but fragment margin; defer to the Phase 2 rotating-accounts work.

### D3 — Trigger checks: permissionless with limits

Anyone may call `checkBatch(orderIds[], report)` (a single id is a batch of one), supplying a Chainlink Data Streams report that the adapter verifies on-chain. This keeps the "no standing execution key" claim. Because the caller picks the report, the adapter enforces:

- Maximum report age of a few seconds relative to `block.timestamp` (value to set after latency measurement)
- Report timestamp strictly greater than the last one used for that order
- A minimum interval between checks per order, so rapid calls can't tighten the fire-time bracket beyond design
- A per-check fee paid by the caller, refunded or rewarded on a successful fire, to cover FHE and verification costs and make griefing cost the griefer

The Data Streams subscription is a real dependency: someone must hold access credentials to fetch reports. That is a data-access key, not an execution key, and must be stated in the trust model.

### D4 — Slippage failure: re-arm once

If GMX cancels the triggered order for breaching `acceptablePrice`, the `afterOrderCancellation` callback marks it `Rearmable`. The order is already public at that point. Default: a separate, permissionless `rearm(orderId)` transaction re-submits it once as a market order with a wider, **user-set public** fallback bound chosen at intake. If that also fails, the order stays cancelled and the user is notified to act manually. This bounds the worst case (a stop-loss that never executes) without letting a ciphertext-derived value widen the bound.

The re-arm cannot run inside the callback. GMX's `executeOrder` and `createOrder` are both `globalNonReentrant`, and the cancel callback runs inside `executeOrder`, so a `createOrder` from the callback reverts. GMX catches the revert and only logs `AfterOrderCancellationError`. The callback therefore only records state.

The re-arm needs its own execution fee, so each sealed order escrows two execution fees at intake. The second is released back to the user's free balance in the clone if the order fills first time or is cancelled (it never left the clone).

### D5 — Lead with limit-entry privacy

For a limit entry, side, size and trigger are all hidden until fire, which is the strongest privacy claim the system can make. Stop-loss and take-profit orders still benefit (hidden trigger, invisible cancellation) and remain supported, but the pitch and the first proof of concept target limit entries. This also bears on the open target-user question in §10.

---

## 1–2. What we're building and scope

A privacy adapter in front of GMX Perpetuals V2 that keeps conditional order intent sealed until it fires, using Fhenix CoFHE. GMX's core contracts are not modified; the adapter integrates with the deployed system from outside.

**What it protects against, in priority order:**

1. **Strategy leakage and copy trading** — a visible resting order can be mirrored before it fills. This is the strongest motivation.
2. **Signaling on cancellation** — a sealed order that is cancelled reveals only that some order existed.
3. **Stop hunting** — weaker on GMX than on order-book venues. GMX executes at an oracle price aggregated from centralized exchanges, so hunting a stop means moving those markets.

**In scope for v1:**

- Sealed intake: side, size, trigger price and slippage bound encrypted client-side; market public (D1)
- Order types: limit entry (lead case, D5), stop-loss and take-profit
- Non-custodial per-user clone accounts (D2)
- Permissionless trigger checks against verified Chainlink Data Streams reports (D3)
- Cap checks on ciphertext at intake; public caps re-checked at reveal
- Execution on GMX V2 with payout to the same user clone; one re-arm on slippage failure (D4)

**Deferred, unchanged from v0.1:** pooled accounts with netting and internal liquidation, epoch-batched reveals, rotating per-order accounts, relayer submission, shielded payout, reveal batching (§8). **Removed:** private-RPC submission, which does not apply on Arbitrum (§7).

---

## 3. Architecture and account model

Six components; GMX is untouched. The change from v0.1 is that each user's clone, not the adapter, is the GMX account.

| Component | Role |
| --- | --- |
| User | Holds funds, encrypts order fields client-side, submits sealed orders and deposits. |
| Adapter (ours) | Factory for user clones; stores ciphertext handles, runs cap checks and trigger checks, verifies Data Streams reports, calls GMX on reveal. |
| User clone (ours) | Minimal proxy per user. Holds collateral and execution-fee ETH, is the GMX `account`, `receiver` and `callbackContract`. Exposes manual close, collateral, cancel and withdraw paths to its owner (D2). |
| Fhenix CoFHE | Encrypted storage and compute (compare, select, add). Decryption by Teecryptor, a single Fhenix-operated TEE (§6). |
| Chainlink Data Streams | Signed, pull-based price reports. The check caller fetches one off-chain and the adapter verifies it on-chain through Chainlink's verifier contract. |
| GMX V2 | `ExchangeRouter` / `OrderVault` for order creation, keepers and `OrderHandler` for execution, callbacks for fill and cancel. |

**Oracle source.** GMX V2 keeps no oracle price on-chain between executions: signed prices are supplied by keepers and used only inside the executing transaction. The adapter therefore uses Chainlink Data Streams for trigger checks. For markets where GMX itself prices from Data Streams, the trigger feed and the execution feed are the same source, a few blocks apart. Which Arbitrum Sepolia markets qualify is in §9.

**Integration constraints.**

- **Execution fees.** Paid in ETH at `createOrder`. Each sealed order escrows two fees in the clone at intake: one for the first attempt, one for the D4 re-arm.
- **Fee refunds.** GMX returns unused execution fee through `IGasFeeCallbackReceiver.refundExecutionFee` on the callback contract, with its own gas limit. The clone implements it and also has `receive()` for plain ETH transfers.
- **Callbacks.** `callbackGasLimit` is capped by GMX's maximum, and a failed callback does not revert GMX execution. Settlement never depends on the callback: funds reach the clone as `receiver` regardless, and the adapter reconciles from clone balances if a callback is lost. Callbacks only record state; they never call back into GMX (see D4).
- **Callback authentication.** The clone accepts `afterOrderExecution`, `afterOrderCancellation`, `afterOrderFrozen` and `refundExecutionFee` only when `msg.sender` holds GMX's `CONTROLLER` role in `RoleStore`, and only for order keys the clone itself created.
- **Interface churn.** Callback and order struct signatures change across GMX V2 releases. Pin the `gmx-synthetics` commit that matches the deployment under test, not just its addresses.

---

## 4. Order lifecycle

A triggered order takes two transactions and one decrypt round trip, then GMX's own keeper delay. v0.1's flow needed two decrypt round trips.

```mermaid
sequenceDiagram
    participant U as User
    participant C as User clone
    participant A as Adapter
    participant F as CoFHE
    participant K as Checker (anyone)
    participant G as GMX V2
    U->>C: Deposit collateral + 2x fee ETH
    U->>A: Sealed order (encrypted inputs)
    A->>C: Lock order collateral
    A->>F: Cap checks on ciphertext
    K->>A: checkBatch(orders, Data Streams report)
    A->>F: fired = compare; select(fired, field, 0)
    F-->>A: Decrypt result (async)
    K->>A: execute(order)
    A->>G: createOrder via clone
    G-->>C: Fill or cancel callback (state only)
    K->>A: rearm(order) if cancelled
```

1. **Deposit.** The user deposits collateral and execution-fee ETH (two fees per planned order, D4) into their clone. Public: address, token, amount, time.
2. **Sealed intake.** The user submits encrypted side, size, trigger price and slippage bound, plus plaintext market, order type and a public fallback slippage bound (D4). Every input is verified by CoFHE and bound to the submitting user. The adapter stores only handles it created from verified inputs, with ACL grants to itself and that user (§6).
3. **Collateral lock and cap checks.** The order's collateral amount (public, chosen by the user) is locked in the clone and cannot be withdrawn while the order is live. Encrypted comparisons against public caps produce an encrypted `valid` flag. The caps are max size, max leverage against the locked collateral, and size within the locked collateral. These caps apply to increase orders; decrease orders are bounded at execute time against the live position (step 5). Invalid orders never fire and nothing is revealed. Because the collateral is locked, `valid` cannot go stale.
4. **Trigger check.** Any caller submits one Data Streams report meeting the D3 rules, with a batch of order ids in that report's market: `checkBatch(orderIds[], report)`. The adapter verifies the report once. For each order it computes `fired = valid AND crossed(type, side, trigger, price)` on ciphertext, then `select(fired, field, 0)` for each field, and grants public decryption on the set (§9 describes the decrypt flow). If not fired, the result is all zeros and reveals only "not yet". Per-order minimum intervals (D3) still apply inside a batch.
5. **Execute.** In a later transaction, once the decrypt result is available, any caller triggers execution. The adapter re-checks the now-plaintext values against the public caps. For decrease orders, the adapter reads the clone's current position from GMX and sets size = min(decrypted size, position size) before `createOrder`. GMX reverts `MarketDecrease` orders larger than the position (`InvalidDecreaseOrderSize`), so this cap is required, not optional. The adapter then derives `acceptablePrice` from the reference price and the slippage bound, bounded by the public maximum deviation, and calls `createOrder` from the clone.
6. **GMX execution.** A GMX keeper executes at GMX's oracle price. The order is public on-chain until then; GMX pricing, not mempool ordering, bounds what a front-runner can gain.
7. **Settlement.** Funds settle to the clone as `receiver`, with `cancellationReceiver` also set to the clone so collateral returned on a cancel lands back under the lock. On fill, the collateral lock is released. On a slippage cancel, the lock stays until the re-arm fills or fails. The callback only records the outcome; the order becomes `Rearmable` and anyone may call `rearm(orderId)` once (D4). From here the position is an ordinary public GMX position.

**Cost trade-off.** Step 4 decrypts every field on every check, not just a boolean. That buys a full round trip of latency on each fire at the cost of more decryption volume per check. Batching spreads the report-verification cost across orders but not the per-order FHE and decryption cost. Measure both on live Sepolia (§10) before committing.

---

## 5. What stays sealed, and for how long

Before fire, only side, size, trigger and slippage are hidden, and for stop-loss or take-profit only the trigger price is truly secret. At fire, everything is revealed; the trigger price is revealed to within one polling interval's price move.

| Field | Encrypted | Limit entry: effective secrecy | Stop-loss / take-profit: effective secrecy | Revealed |
| --- | --- | --- | --- | --- |
| Market | No (D1) | Public | Public | At intake |
| Order type (limit entry / stop-loss / take-profit) | No | Public | Public; an open position already implies a decrease order | At intake |
| Side | Yes | Hidden | Inferable from the open position | At fire |
| Size | Yes | Hidden, bounded by locked collateral × max leverage | Bounded by position size, often all of it | At fire |
| Trigger price | Yes | Hidden | Hidden | At fire, to within the price move since the last "not yet" check |
| Slippage bound | Yes | Hidden | Hidden | At fire |
| Collateral locked for the order | No | Public | Public | At intake |
| Order existence | No | Public (a handle exists) | Public | At intake |

**How the trigger price leaks.** For a single threshold, each "not yet" result only says the trigger lies beyond the most extreme price since placement, which is close to public knowledge already. The real leak is at fire: the trigger lies between the last "not yet" price and the firing price. The D3 minimum check interval sets how wide that bracket stays.

**Order type is public by design.** Encrypting it would add another encrypted select per check and hide little: take-profit and stop-loss on the same position differ only in comparison direction, and that direction is what side already hides for limit entries.

---

## 6. Trust model

Order confidentiality today rests on one Fhenix-operated enclave, not a threshold network. On-chain caps limit what a bad decrypt can do to funds, but nothing limits what a compromised decryptor can read.

### Decryption: single TEE, split key

Per Fhenix's current docs (checked 2026-09-24):

- Decryption is done by **Teecryptor**, one TEE component on Intel TDX, **operated by Fhenix**.
- The FHE key is split **3-of-6** with Shamir secret sharing among independent partners. Each partner releases its share only to an attested enclave image, and the key is rebuilt in enclave memory. The result-signing key travels inside the same split secret. Source: [Teecryptor page](https://github.com/FhenixProtocol/fhenix-developer-docs/blob/main/deep-dive/cofhe-components/teecryptor.mdx) and [Key Management page](https://github.com/FhenixProtocol/fhenix-developer-docs/blob/main/deep-dive/cofhe-components/key-management.mdx), docs commit d8c9bd2 (2026-09-17). This 3-of-6 figure is for the FHE decryption keyset. The ZK Verifier's signing key is split separately, and its share counts reported elsewhere (5 on staging, 3 on testnet) are not this number. Confirm the Arbitrum Sepolia figure with Fhenix, since keygen parameters may differ per environment.
- Encrypted inputs are checked by a **ZK Verifier**, also TDX and also Fhenix-operated. It signs a digest covering sender, chain id and consuming contract.
- A threshold or MPC decryption network, MPC for the ZK Verifier, verified computation and an audit are listed as **planned**, not live. The codebase is described as unaudited and not fully open source.
- The six key-share partners are not named in the docs.

What this means for us: the 3-of-6 split protects the key at rest, but at runtime the whole key sits inside one enclave that Fhenix runs. Confidentiality depends on TDX holding and Fhenix operating it honestly. v0.1's claim that shares are held "by independent parties" is true only for storage.

### Trust assumptions

| Area | What we rely on | If it fails |
| --- | --- | --- |
| Confidentiality | Teecryptor enclave (Intel TDX) and Fhenix as operator | Every sealed order can be read, silently. Caps don't help. |
| Decrypt correctness | Teecryptor signs results; the adapter checks the signature against Fhenix's registered signer | A wrong result can fire an order or set its fields. Bounded by independent caps below. |
| Input validity | ZK Verifier signature bound to sender, chain and contract | Forged or replayed inputs. Mitigated by the binding plus our handle rules. |
| FHE compute correctness | CoFHE coprocessor; replay against commitments is possible but after the fact | Detection only after loss. |
| Prices | Chainlink Data Streams reports verified on-chain | Checks fire on bad prices; also GMX's own risk. |
| Liveness | CoFHE, Data Streams access, a checker, GMX keepers | Orders don't fire. Users can always cancel and withdraw through their clone. |
| Funds | Clone and adapter code, and whoever holds admin keys | See standing keys below. |

### Independent vs ciphertext-derived caps

Only plaintext values fixed before any decryption bound a bad decrypt:

- **Independent:** max size, max leverage, max deviation of `acceptablePrice` from the verified reference price, the D4 fallback slippage bound, locked collateral (increase orders) and live position size (decrease orders).
- **Not independent:** the encrypted slippage bound, size and side. A faulty decryptor controls these, so they are checked against the independent caps at execution, never trusted alone.

### Ciphertext replay and callback spoofing

The ZK Verifier binding stops a user from submitting another user's input proof. The adapter must still ensure it never operates on a handle it did not create from that user's own verified input: handles are stored per order, grants go only to the adapter and the owning user, and no function accepts a handle as a parameter.

Callbacks are a second spoofing surface. A forged `afterOrderCancellation` could mark an order `Rearmable` or release a collateral lock. The clone accepts callbacks only from holders of GMX's `CONTROLLER` role and only for order keys it created (§3).

Required tests:

- User B cannot make the adapter decrypt a handle belonging to user A.
- A callback from any address without the `CONTROLLER` role is rejected.
- A genuine GMX callback for an order key the clone did not create is ignored.
- A `createOrder` attempted from inside a callback is never relied on: the re-arm path works only through `rearm()`.

### Standing keys

"No standing execution key" holds for triggering and execution, which are permissionless (D3). These keys still exist and must be listed publicly:

- Adapter admin, if any: upgrades, cap parameters, Data Streams verifier address. Default: no upgradeability for v1; caps set at deployment.
- Data Streams access credentials, needed by whoever fetches reports (a data key, not an execution key).
- Fhenix's Teecryptor and ZK Verifier signers, which the CoFHE contracts trust.

---

## 7. Known limitations

These are accepted trade-offs for v1. Three entries changed from v0.1: mempool exposure is replaced by public-order exposure, slippage-failure reveal is new, and deposit-size leakage is now locked-collateral leakage.

- **No anonymity set.** Every order stands alone; no netting or pooling in v1.
- **Persistent account linkage.** One clone per user across all orders enables profiling over time.
- **Fire-time trigger bracketing.** The trigger price is revealed to within the price move of one check interval (§5).
- **Locked-collateral leakage.** Locked collateral per order is public and bounds plausible order size.
- **Stop-loss fields are mostly inferable.** For decrease orders, only the trigger price is truly hidden (§5).
- **Public order awaiting keeper (replaces "mempool exposure").** Arbitrum has no public mempool: the sequencer takes transactions first-come-first-served, with Timeboost's express lane on top. The exposure is that the revealed `createOrder` sits on-chain until a GMX keeper executes it. GMX executes at its oracle price, so front-running gains are limited to what that price allows.
- **Revealed-but-unexecuted orders (new).** If GMX's execution price breaches the slippage bound, the order is public and cancelled. D4 re-arms once; after that the user must act manually.
- **Trigger latency.** Check interval + one decrypt round trip + GMX keeper delay. In fast moves a stop fires later than a native GMX stop order would.
- **Post-fill transparency.** Position, entry, PnL and liquidation price are public once filled, as on native GMX.
- **No payout privacy.** Proceeds return to the same known clone.
- **Retroactive exposure.** Ciphertexts persist on-chain; a future compromise of Fhenix key material could expose historical orders.

---

## 8. Reveal batching — deprioritized

Unchanged from v0.1. Batching trigger decrypts to blur which order fired is close to cosmetic without randomized execution delay and relayer rotation; with them, it is substantial engineering for a benefit that only appears statistically across many concurrent orders. Not worth it at current or near-term volume.

---

## 9. Testing and deployment: Arbitrum Sepolia, two tiers

A local fork cannot exercise real FHE or GMX keepers, so testing runs in two tiers. Arbitrum Sepolia (chain 421614) is supported by both CoFHE and GMX V2.

| Tier | Environment | Covers | Doesn't cover |
| --- | --- | --- | --- |
| 1. Local | Arbitrum Sepolia fork + CoFHE mocks + our own keeper simulator | Adapter and clone logic, caps, ACL and replay tests, GMX integration against real contract state, callback handling | Real decryption, latency, gas and fees, real keeper timing |
| 2. Live | Arbitrum Sepolia | End-to-end fires, decrypt latency and cost, Data Streams verification, keeper delay (§10) | Mainnet liquidity and MEV conditions |

**CoFHE packages.** Current scope is `@cofhe/*` at 0.7.1: `sdk`, `mock-contracts`, `hardhat-plugin` (Hardhat 2), `hardhat-3-plugin`, `foundry-plugin`. Solidity contracts stay at `@fhenixprotocol/cofhe-contracts` 0.2.0. SDK 0.7 does not work with 0.6 contracts or plugins, so pin the set together. `cofhejs` and the older `@fhenixprotocol/cofhe-mock-contracts` / `cofhe-hardhat-plugin` are legacy.

**CoFHE decrypt flow to build against.** `FHE.decrypt` is gone. The adapter grants access to the handle (`FHE.allow`, or `FHE.allowGlobal` so any checker can decrypt the zeroed-unless-fired results from §4). Off-chain, the SDK's `decryptForTx` returns plaintext plus an enclave signature. Anyone then calls `FHE.publishDecryptResult` (batch variant available), and the adapter reads it with `getDecryptResultSafe`. The execute transaction in §4 can publish and consume the results in one call.

**GMX on Arbitrum Sepolia (repo config, `gmx-synthetics` main at commit a85ea34):**

| Token | Oracle provider | Markets |
| --- | --- | --- |
| WETH | Chainlink Data Streams | WETH/WETH-USDC.SG, CRV/WETH-USDC.SG |
| BTC | Chainlink Data Streams | BTC/BTC-USDC.SG |
| CRV (synthetic) | Chainlink Data Streams | CRV/WETH-USDC.SG |
| USDC.SG | Chainlink Data Streams (USDC feed) | Collateral in all three |
| USDT.SG | Chainlink Data Streams (USDC feed) | — |

Every Sepolia token defaults to Data Streams; none uses GMX's own signer or a push feed. So our trigger feed and GMX's execution feed are the same source for all three markets. The repo config lists one oracle signer (`minOracleSigners: 1`), a Data Streams verifier and a payment token for verification fees. This is repo config; confirm on-chain values before relying on them.

**GMX interfaces.** The latest release tag is v2.2 (2025-09-09); main is ahead of it. The deployment list was last regenerated 2025-11-17. Pin the commit matching the live deployment. Callbacks take `(bytes32 key, EventLogData orderData, EventLogData eventData)`; a callback that reverts is caught and logged (`AfterOrderExecutionError`). Execution does revert up front if too little gas remains to forward `callbackGasLimit`.

**Process.** Re-check GMX's testnet addresses before each live test cycle; testnet is redeployed more often than mainnet. *Update 2026-09-24:* the repo's deployment list is stale; live addresses come from GMX's official docs, pinned to commit `bf30ebb`. See [integration/gmx-v2.md](integration/gmx-v2.md#addresses).

---

## 10. Open questions to validate

These are facts to measure or confirm, as distinct from the design choices in Open decisions.

- [ ] Decrypt round-trip latency and gas on live Arbitrum Sepolia, for a boolean-only decrypt versus the collapsed all-fields decrypt (§4). Sets the D3 minimum check interval.
- [ ] Cost per check, split into fixed per-report costs (Data Streams verification) and per-order costs (FHE ops, decryption), to size `checkBatch` and set the D3 per-check fee.
- [ ] Data Streams on Arbitrum Sepolia: report availability for our target markets, verification fee model, and who holds the access credentials.
- [ ] Maximum report age that honest checkers can reliably meet (D3).
- [ ] Who the six key-share partners are, and Fhenix's timeline for threshold decryption (§6).
- [ ] Whether coprocessor result commitments are enforced on-chain or only logged on Arbitrum Sepolia.
- [ ] Hard-cap values: max size, max leverage, max deviation from reference price.
- [ ] GMX testnet keeper liveness and typical execution delay on Arbitrum Sepolia.
- [ ] Target user segment and monetization, now scoped around limit-entry privacy (D5).

---

## 11. Roadmap (Phase 2+)

Private-RPC submission is removed: it addresses an Ethereum mempool Arbitrum does not have. Remaining items, cheapest and highest value first:

1. **Shorter public-order window.** Reduce the time a revealed order waits for a keeper, for example by running our own GMX keeper where permitted or pre-funding higher execution fees. Replaces the old private-RPC item.
2. **Rotating proxy accounts per order.** Breaks persistent linkage at the cost of fragmented margin.
3. **Relayer-based submission.** Removes the user's address from the deposit and order trail.
4. **Fixed collateral denominations per order, plus withdrawal delay.** Narrows locked-collateral leakage.
5. **Pooled account with netting and internal liquidation.** Largest item; justified only once volume supports a meaningful batch size.

---

## Sources

- [gmx-synthetics `config/tokens.ts`](https://github.com/gmx-io/gmx-synthetics/blob/main/config/tokens.ts) — Arbitrum Sepolia oracle providers
- [gmx-synthetics `config/oracle.ts`](https://github.com/gmx-io/gmx-synthetics/blob/main/config/oracle.ts) — signers, Data Streams verifier
- [gmx-synthetics `contracts/oracle/OracleModule.sol`](https://github.com/gmx-io/gmx-synthetics/blob/main/contracts/oracle/OracleModule.sol) and [`Oracle.sol`](https://github.com/gmx-io/gmx-synthetics/blob/main/contracts/oracle/Oracle.sol) — prices cleared after each execution
- [gmx-synthetics `IOrderCallbackReceiver.sol`](https://github.com/gmx-io/gmx-synthetics/blob/main/contracts/callback/IOrderCallbackReceiver.sol) and [`CallbackUtils.sol`](https://github.com/gmx-io/gmx-synthetics/blob/main/contracts/callback/CallbackUtils.sol)
- [GMX Arbitrum Sepolia deployments](https://github.com/gmx-io/gmx-synthetics/blob/main/docs/arbitrumSepolia-deployments.md)
- [CoFHE docs: decryption request flow](https://cofhe-docs.fhenix.zone/deep-dive/data-flows/decryption-request-flow)
- [Fhenix docs: Teecryptor](https://github.com/FhenixProtocol/fhenix-developer-docs/blob/main/deep-dive/cofhe-components/teecryptor.mdx) and [Key Management](https://github.com/FhenixProtocol/fhenix-developer-docs/blob/main/deep-dive/cofhe-components/key-management.mdx) — 3-of-6 Shamir split of the decryption keyset
- [Fhenix developer docs repo](https://github.com/FhenixProtocol/fhenix-developer-docs) — Teecryptor, key management, ZK Verifier, future plans, compatibility pages
