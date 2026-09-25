# Sealed Order Privacy Layer for GMX Perpetuals
### Internal Protocol Overview — Draft v0.1

> **Archived.** Superseded by [design-v0.2.md](../design-v0.2.md). Kept for history only: several statements here were found to be wrong (see [decisions.md](../decisions.md)). Do not build from this version.

*Internal working document. Consolidates the technical design with decisions made since, for team-wide context.*

---

## 1. What We're Building

A privacy adapter that sits between users and GMX Perpetuals V2, keeping conditional order intent (stop-loss, take-profit, limit entry) hidden while it's pending, until the moment it fires. We use Fhenix's confidential compute layer (CoFHE / FHE) to do this.

We are **not** modifying GMX's core contracts. We're integrating with the live, deployed system as an external adapter, not forking its logic.

**The problem we're solving:** on GMX today, a resting conditional order is public on-chain data the instant it's placed. That enables:
- **Stop hunting** — trigger price, size, and side are readable, so price can be pushed toward a known trigger.
- **Copy trading / strategy leakage** — a visible pending order can be mirrored before it fills.
- **Signaling on cancellation** — an order that's placed and later cancelled was still visible for its whole life, leaking intent even when the user backs out.

---

## 2. Scope

**In scope for v1:**
- Sealed order intake via FHE — order fields encrypted client-side before submission.
- Non-custodial, per-user accounts. No shared pool, no omnibus custody.
- Continuous polled trigger evaluation via encrypted comparison against a public oracle price.
- Reveal at trigger, gated by hard on-chain caps (max size, max leverage, slippage bound).
- Direct execution on GMX V2, direct payout back to the same user account.

**Deliberately deferred (not v1):**
- Pooled/omnibus accounts with order netting, and the internal liquidation engine that would require.
- Epoch-based batched reveals of net deltas.
- Rotating proxy accounts per order.
- Relayer-based submission (removing the user's address from the deposit/order trail).
- Shielded/private payout.
- Reveal batching for ambiguity — evaluated and deprioritized (see §8).

None of the deferred items are required for the core privacy claim this system makes. They're a second phase of work, each substantial enough to be its own build.

---

## 3. Architecture

Four components. GMX's contracts are untouched.

| Component | Role |
|---|---|
| **User** | Holds funds; encrypts order fields client-side; submits sealed orders and deposits. |
| **Privacy Adapter** (ours) | Holds per-user accounts, the intent inbox, the trigger evaluator, and the GMX-facing interface. Registered as GMX's `callbackContract`. |
| **Fhenix CoFHE** | Encrypted storage and homomorphic compute (add/compare/select). Async decryption via the TaskManager. Decryption is currently performed by an attested enclave service, per Fhenix's docs. |
| **GMX V2 Contracts** | Unmodified. `ExchangeRouter` / `OrderVault` for order creation, `OrderHandler` and keepers for execution, callback interface for fill/cancel notifications. |

---

## 4. Order Lifecycle

1. **Deposit** — user deposits collateral into their own adapter-managed account. Public: address, token, amount, timestamp.
2. **Sealed order submission** — user encrypts order fields (market, side, size, trigger price, slippage bound) client-side, submits with a validity proof. Adapter stores ciphertext handles only.
3. **Trigger evaluation** — adapter periodically dispatches an encrypted comparison of the trigger against the current public oracle price. Only the resulting boolean is decrypted; order fields stay sealed.
4. **Reveal & execute** — once the trigger fires, order fields are decrypted, checked against hard on-chain caps, and GMX's `createOrder` is called in the same transaction. Adapter is set as receiver and `callbackContract`.
5. **GMX execution** — GMX keepers execute at the oracle price; `afterOrderExecution` / `afterOrderCancellation` call back into the adapter with fill data.
6. **Settlement** — fill data (price, size, fees) is recorded; funds and residual balance return to the user's own account.

From this point on, the order is a normal, fully public GMX position — same as native GMX.

---

## 5. What Stays Sealed, and For How Long

| Field | Encrypted? | Revealed when |
|---|---|---|
| Market | Yes | At trigger fire |
| Side (long/short) | Yes | At trigger fire |
| Size | Yes | At trigger fire |
| Trigger price | Yes | Never directly — only a crossed/not-crossed boolean is decrypted per check |
| Slippage bound | Yes | At trigger fire |
| Collateral amount | No | Public at deposit time |
| "Fired" flag (derived) | Yes internally | Decrypted result of each trigger check |

---

## 6. Trust Model

- **FHE compute correctness** — homomorphic ops run off-chain via the CoFHE coprocessor. Not proven on-chain, but auditable after the fact by replaying against the posted commitment.
- **Decryption confidentiality & correctness** — performed by an attested enclave service. Key shares held by independent parties, reassembled only inside the enclave.
- **Liveness** — both the async decrypt round trip and GMX keeper execution depend on external infrastructure staying live.
- **Custody** — non-custodial throughout. The adapter cannot move funds outside an order's own execution path and the hard caps below.
- **On-chain caps** — independent of FHE, always enforced: max size, max leverage, slippage bound, per-account caps. These bound the damage of an incorrect or malicious decrypted result, regardless of what goes wrong upstream.

**Where this system actually earns its complexity**, relative to the cheaper alternatives (a self-hosted trigger bot, a hosted stop-order service, a TEE-based order book — full comparison kept as separate internal reference): no standing execution key sitting anywhere, publicly auditable trigger and cap logic instead of an opaque backend, and an immutable on-chain commitment that the order existed with specific terms before it fired. It's a "verifiable and keyless" pitch, not a "faster or cheaper" one — a plain off-chain bot still wins decisively on cost and latency.

---

## 7. Known Limitations (accepted trade-offs, not hidden gaps)

- **No anonymity set** — every order stands alone, no netting/pooling in v1.
- **Persistent account linkage** — one account per user across all orders enables profiling over time.
- **Trigger price bracketing** — frequent polling narrows the implied trigger price through successive true/false results.
- **Deposit-size leakage** — deposit amount bounds plausible order size before anything else is revealed.
- **Post-fill transparency** — position, entry price, PnL, liquidation price are fully public the instant the order fills — identical to native GMX.
- **No payout privacy** — direct payout links proceeds and withdrawals to the same known account.
- **Mempool exposure** — the reveal-and-execute transaction is a normal, sandwichable mempool transaction until we add private RPC submission (cheap, planned — see §9).
- **Retroactive exposure** — ciphertexts persist on-chain indefinitely; a future compromise of Fhenix's key material could expose historical order data.

---

## 8. Reveal Batching — Why It's Deprioritized

We looked at batching trigger-check decrypts together to add ambiguity about which order fired. Without randomized execution delay and relayer rotation alongside it, this is close to cosmetic. With those two things added, it becomes substantial engineering for a benefit that only shows up statistically, and only across many concurrent orders. Not worth it at current or near-term expected volume.

---

## 9. Target Deployment: Arbitrum Sepolia

We're building and testing against **Arbitrum Sepolia**, not Arbitrum One, for this phase. Two things made that the right call rather than a compromise:

- **Fhenix CoFHE is live on Arbitrum Sepolia** with full support.
- **GMX V2 has a full, current testnet deployment on Arbitrum Sepolia** — in fact GMX's own docs call it their most current testnet, ahead of Avalanche Fuji. All the contracts we integrate against are there: `ExchangeRouter`, `OrderVault`, `OrderHandler`, `DataStore`, `Oracle`, and the rest.

Practically, this means a single forked test environment (Foundry/Hardhat fork of Arbitrum Sepolia) gives us both real GMX contract state *and* a live, interactable FHE coprocessor — we don't need to split testing across two forks or mock either side.

One caveat to build process around: GMX's testnet contracts are redeployed more frequently than mainnet, so addresses can go stale. We should re-verify against GMX's live docs periodically rather than hardcoding addresses once, and confirm keeper liveness on testnet specifically (a local fork won't have a keeper running unless we run one ourselves or replicate keeper behavior in the test harness).

**Forking notes:**
- We clone `gmx-synthetics` (GMX V2 — the repo with `ExchangeRouter`, `OrderVault`, `OrderHandler`, and the callback interface) locally only to pull real Solidity interfaces, so the adapter compiles against the actual ABI. We do not deploy our own copy of GMX.
- `gmx-contracts` (V1, GLP-based) is not relevant — different architecture, no isolated markets, no `callbackContract` hook.

---

## 10. Open Questions Still to Validate

- Measure real decrypt latency and gas cost on Arbitrum Sepolia — this sets the minimum viable polling interval.
- Confirm whether the on-chain commitment/verification check for coprocessor results is enforced or only logged as a warning on our target network.
- Finalize hard-cap parameters (max size, max leverage, slippage bound) before any mainnet consideration.
- Define target user segment and monetization model — not yet settled.
- Confirm GMX testnet keeper liveness for our specific fork/test setup.

---

## 11. Roadmap (Phase 2+, roughly cheapest/highest-value first)

1. **Private RPC submission** (Flashbots Protect / MEV Blocker) for the reveal-and-execute transaction — low cost, closes the mempool exposure in §7.
2. **Rotating proxy accounts per order** — breaks persistent-account linkage, at the cost of fragmented margin.
3. **Relayer-based submission** — removes the user's address from the deposit/order trail.
4. **Fixed deposit/withdrawal denominations + withdrawal delay** — narrows deposit-size leakage.
5. **Pooled/omnibus account with netting and internal liquidation** — the largest undertaking; only justified once real order volume supports a meaningful batch size.

---

*This reflects design discussion to date and will change as CoFHE availability, latency, and gas costs are confirmed on Arbitrum Sepolia.*
