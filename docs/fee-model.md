# Fee Model — Implementation Spec

*Companion to [design-v0.2.md](design-v0.2.md). New decision D6 and new §12. Received 2026-09-25. The spec is kept as written below; **[Implementation notes](#implementation-notes-2026-09-25)** at the end record where the build deviates and why, and which milestone implements each part.*

---

## 1. Goal

Cover the protocol's real operating costs — FHE compute, Data Streams verification, adapter gas, checker incentives, infra — without:

- Leaking anything that isn't already public at the point the fee is taken
- Adding a standing admin key beyond what §6 already discloses
- Punishing cancelled, invalid, or never-triggered orders
- Pricing stop-loss/take-profit so far above native GMX that it undermines the one clean retention feature (hidden trigger + hidden cancellation) those order types actually have

This is a **sustain-the-lifecycle** fee model, not a growth or token-economics model. No token, no treasury governance, no LP mechanics — out of scope here.

## 2. Benchmark: what GMX itself charges

Your fee is **additive on top of GMX's own fee**, not a replacement — the adapter doesn't modify GMX, so every fill still pays GMX's native fee regardless of what you charge.

GMX V2's own position fee: 0.04% (4 bps) if the trade improves long/short open-interest balance, or 0.06% (6 bps) if it worsens it. Same range applies to closes. There is no maker/taker split, since GMX prices from an oracle rather than an order book.

For sizing context: GMX V2 Perps generated $1.72m in fees over the trailing 30 days at time of writing, of which $636,991 (37%) was taken as protocol revenue — 10% to treasury, 27% to token stakers. That revenue share is a mature, high-volume protocol's number, not a target for a v1 sustain-the-lifecycle model; it's included here only so the fee sizing below isn't picked in a vacuum.

**Implication for sizing:** stacking your fee on GMX's means a limit entry through the adapter will cost more in total than the same trade placed natively. That's the accepted, disclosed cost of "verifiable and keyless" (§6's positioning) — keep the adapter's own cut modest enough that the stack stays defensible next to that pitch, not next to a token's revenue target.

## 3. D6 — Fee model (new open decision)

| # | Decision | Recommended default | Main alternative | Depends on |
| --- | --- | --- | --- | --- |
| D6 | Fee model | Notional-based fee on increase-order fill (8–15 bps, placeholder pending §10 cost data); flat, minimal fee on decrease-order fill; fee only charged on success; check-fee spread as secondary revenue | Flat fee on all order types regardless of privacy delivered; fee charged at intake regardless of outcome | §10 (cost measurements), D5 (lead use case) |

**Why fee-on-fill, not fee-at-intake:** charging at intake means charging users for orders that get cancelled or never trigger — most of what "no anonymity set, every order stands alone" (§7) actually looks like in practice. Charging only on a successful fill keeps the fee aligned with delivered value and matches the existing principle from §4 step 3 (cap checks never punish an order that doesn't fire).

**Why the increase/decrease split:** §5's own finding is that limit entries are where side, size and trigger are all genuinely hidden — that's where you're delivering the strongest privacy claim, so that's where the fee should sit. Stop-loss/take-profit orders only hide the trigger price; loading the same fee onto them taxes a retention feature (hidden cancellation, hidden trigger) more than it monetizes a privacy delivery.

## 4. Fee parameters

All fee parameters are **public, immutable constants set at deployment** — consistent with the existing §6 decision ("no upgradeability for v1; caps set at deployment"). This keeps the fee model from introducing a new standing key. If a future version makes these adjustable, the fee-setter key must be added to §6's standing-keys list explicitly, same as any other admin parameter.

| Parameter | Description | Placeholder default | Notes |
| --- | --- | --- | --- |
| `INCREASE_FEE_BPS` | Fee on increase-order (limit entry) notional at fill | 8–15 bps | Final value depends on §10's decrypt latency/gas measurements — this is a placeholder, not a committed number |
| `DECREASE_FEE_BPS` or `DECREASE_FEE_FLAT` | Fee on decrease-order (stop-loss/take-profit) fill | Low bps, or a small flat amount | Keep materially below `INCREASE_FEE_BPS`; consider zero for v1 and revisit once volume data exists |
| `CHECK_FEE_SPREAD_BPS` or `CHECK_FEE_SPREAD_FLAT` | Amount the D3 per-check fee exceeds actual measured FHE + Data Streams cost | Set after §10 cost measurement | This is margin on top of checker cost-recovery, not a separate fee the user sees directly |
| `FEE_COLLECTOR` | Address that receives swept fees | Protocol-owned address, set at deployment | Not a role that can call into user clones or the adapter's order path — receive-only |

## 5. Collection mechanics — where this sits in the existing lifecycle

This slots into **§4 step 7 (Settlement)** of the main design doc. No other step changes.

**Sequence, extending the existing settlement step:**

1. GMX's keeper fills the order (existing §4 step 6). Proceeds land in the user's clone as `receiver` (existing).
2. **New:** the adapter computes the fee owed:
   - Increase order: `fee = INCREASE_FEE_BPS * filledSizeUsd / 10000`
   - Decrease order: `fee = DECREASE_FEE_BPS * filledSizeUsd / 10000` (or the flat amount)
   - `filledSizeUsd` comes from GMX's own fill event data in the `afterOrderExecution` callback (already consumed for settlement bookkeeping) — no new oracle read, no new trust assumption.
3. **New:** the adapter sweeps `fee` from the clone's settled proceeds to `FEE_COLLECTOR`, in the same transaction that processes the callback, or in a follow-up transaction if callback gas is too constrained (consistent with §3's existing rule that a failed callback never blocks settlement — the fee sweep must follow the same "never depends on the callback succeeding" pattern already established for fund delivery).
4. The remainder is the user's free, withdrawable balance in the clone — unchanged from the existing settlement flow otherwise.
5. **No fee on cancellation.** If the order is cancelled (slippage failure, manual cancel, liquidation-triggered cancel per D2/D4), no fee is taken. If D4's re-arm eventually fills, the fee is taken once, on that eventual fill — never on the failed first attempt.

**What does not change:** the sealed intake path (§4 steps 1–3), the trigger check (step 4), the execute step's cap re-checks and decrease-order size clamp (step 5, per the DecreasePositionUtils fix), and the collateral lock/release logic (D2, §6). The fee model is entirely a post-fill concern — it never touches ciphertext, never adds a decision point before reveal, and never changes what's visible pre-fire.

## 6. Secondary revenue: check-fee spread

D3 already specifies a per-check fee "paid by the caller, refunded or rewarded on a successful fire, to cover FHE and verification costs and make griefing cost the griefer." Set that fee at `actual_measured_cost + CHECK_FEE_SPREAD`, and route the spread to `FEE_COLLECTOR` rather than back to the checker.

This is close to free money on top of a mechanism that already exists, but treat it as supplementary, not primary: it scales with **poll frequency**, not delivered value, so a quiet order that checks thousands of times without firing costs compute regardless of whether it ever earns a fee. Don't size the sustain-the-lifecycle plan around this line alone.

## 7. Required tests

- Fee is charged on a successful increase-order fill, at the correct bps of `filledSizeUsd`.
- Fee is charged on a successful decrease-order fill (including a re-armed one, per D4), at the correct (lower) rate.
- No fee is charged on a cancelled order, a failed cap check, or an order that never triggers.
- No fee is charged twice on a re-armed order (only the eventual successful fill pays).
- Fee sweep does not depend on the `afterOrderExecution`/`afterOrderCancellation` callback succeeding — verify fee collection still completes (via the follow-up-transaction path) if the callback reverts, mirroring the existing "settlement never depends on the callback" test already required in §6.
- `FEE_COLLECTOR` cannot be changed post-deployment (or, if a future version makes it changeable, that it requires whatever standing-key process is documented in §6 at that time).
- Fee parameters (`INCREASE_FEE_BPS`, `DECREASE_FEE_BPS`, `CHECK_FEE_SPREAD_BPS`) are immutable after deployment for v1.

## 8. Open items — resolve before setting real numbers

These block picking actual `INCREASE_FEE_BPS` / `DECREASE_FEE_BPS` / `CHECK_FEE_SPREAD` values; they're the same category of open item as §10 in the main design doc, not new unknowns:

- [ ] Real decrypt latency and gas cost on live Arbitrum Sepolia (§10) — sets the floor for `CHECK_FEE_SPREAD` and indirectly for how much of the cost `INCREASE_FEE_BPS` needs to absorb versus the check-fee already covering.
- [ ] Data Streams verification fee model on Arbitrum Sepolia (§10) — same reason.
- [ ] Expected order volume and average position size for the target user segment (§10's open target-user question, now scoped around limit-entry privacy per D5) — needed to sanity-check whether 8–15 bps on fill volume actually covers fixed infra costs, or whether the check-fee spread needs to carry more of the load in a low-volume early period.
- [ ] Whether GMX's own fee schedule (currently 4/6 bps) changes before launch — re-check against GMX's live fees page before finalizing the stacked total shown to users.

---

## Check-fee sizing (2026-09-30)

From the live run: a single-order check costs ~700k gas (565k per order in a 2-order batch); at Sepolia's 0.03–0.06 gwei that's 0.00002–0.00004 ETH. `checkFee` = 0.00005 ETH covers it with headroom; `checkFeeSpread` = 0.000005 ETH (10%). Per order per day, cost scales with how often the index feed updates: up to ~1,000 checks/day on Sepolia's ETH/USD feed, far fewer on mainnet deviation-triggered feeds. Users choose a check budget; see known issues 18 and 19.

## Implementation notes (2026-09-25)

The principles above hold: fee on success only, increase/decrease split, immutable public parameters, receive-only collector, nothing touches ciphertext. Four mechanics change.

### 1. An increase fill has no proceeds to sweep: the fee is reserved at lock

§5 step 3 sweeps the fee "from the clone's settled proceeds". For a limit entry, the collateral goes into the GMX position; the clone receives nothing but the execution-fee refund. So the clone reserves the fee when the order is locked (`IUserAccount.lock(..., protocolFeeReserve)`), pays from that reserve only once GMX reports the order executed (`payProtocolFee`), and frees the unused remainder. Decrease orders do produce proceeds, but use the same reserve path for one code path.

### 2. The reserve must not reveal the sealed size

The reserve is public. Sizing it from the actual order size would publish the size at intake. It is sized from the **maximum possible** order instead: `locked collateral × max leverage × INCREASE_FEE_BPS`, which is already public. The actual fee is computed after reveal.

### 3. `filledSizeUsd` comes from the revealed size at execute, not from callback event data

- Callbacks only record the outcome (design D4, pull-based). Parsing GMX's `EventLogData` inside a gas-capped callback is fragile, and a lost callback would lose the fee data.
- GMX market-increase orders fill in full or are cancelled; there are no partial fills. So the size revealed and submitted at execute (§4 step 5) equals the filled size.
- The USD fee is converted to the collateral token at the verified reference price already used for `acceptablePrice` at execute. No new oracle read, as the spec requires.

The adapter records the fee owed at execute and collects it with `payProtocolFee` after the clone reports `Executed`.

### 4. "Never depends on the callback" needs reconciliation

Today the clone learns the outcome only from GMX's callback. If a callback is lost, the order stays `Pending`: no fee can be collected and the lock can't be released. Resolved in milestone 5 ([known issue 9](KNOWN_ISSUES.md)): a permissionless reconcile that reads GMX state (order gone + position size changed ⇒ executed; order gone + collateral returned ⇒ cancelled). The §7 test "fee collection completes if the callback reverts" depends on it.

### Where each part is built

| Part | Milestone | Status |
| --- | --- | --- |
| Fee reserve at lock, pay only after `Executed`, at most once, receive-only immutable collector, none on cancel | 2 | **Done** (`UserAccount`, tests in `UserAccount.t.sol` and `UserAccountGmx.t.sol`) |
| Reserve sizing from max order, `INCREASE_FEE_BPS` as an immutable placeholder (10 bps), fee computed at execute, collected after fill | 4 | Planned |
| Reconcile path for lost callbacks (known issue 9) | 5 | **Done**: fee collected after a real lost callback on a fork |
| Check-fee spread routed to the collector | After milestone 8 (with the D3 per-check fee) | **Done** 2026-09-30: `checkFeeSpread` of each `checkFee` goes to the collector; the rest reimburses the checker. Sepolia: 0.000005 of 0.00005 ETH |
| `DECREASE_FEE_BPS` (default 0), re-armed fill charged once | 7 | Planned |
| Real fee values | After 8 (live measurements) | Blocked on §8 open items |
