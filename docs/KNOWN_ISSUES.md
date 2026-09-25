# Known issues

Deferred on purpose; fix as the relevant code is written. When a test harness exists for the area, turn each item into a failing test first.

## Design gaps (from the v0.2 review)

| # | Area | Issue | Fix | Test to add |
| --- | --- | --- | --- | --- |
| 1 | §4 step 7 | Wording implies every order becomes `Rearmable` after the callback. | Only a slippage cancel sets `Rearmable`. | Fill and non-slippage cancel never set `Rearmable`. |
| 2 | §4 step 5, D2 | Position closed or liquidated before a decrease order fires: the size trim yields 0 and GMX rejects a zero-size decrease. | If the position no longer exists, cancel the sealed order and release its fees instead of calling `createOrder`. | Stop-loss fires after the position was closed. |
| 3 | D4 | `rearm()` doesn't restate the execute-time checks; the user can reduce the position between cancel and re-arm. | `rearm()` applies the same checks as `execute()` (public caps, live-position size trim). | Re-arm after a manual partial close. |
| 4 | §4 step 3 | "`valid` cannot go stale" is only true for increase orders. | Wording only. | — |

| 8 | Milestones 2–4 | The clone has no owner cancel or manual close of GMX orders/positions, and supports native-ETH collateral only. Callback authentication is done (milestone 2). | Milestone 5: owner cancel and manual close, ERC20 collateral (USDC.SG) via token approval. | Owner cancels a pending GMX order after the request-expiration delay. |
| 9 | Clone, fee model | The clone learns GMX outcomes only from callbacks. A lost callback leaves the order `Pending`: the lock can't be released and the protocol fee can't be collected, contradicting "settlement never depends on the callback". | Milestone 5: permissionless `reconcile(orderId)` that infers the outcome from GMX state (order gone + position changed, or order gone + collateral returned). | Callback forced to revert; reconcile recovers both outcomes and the fee is still collected. |

## Environment

| # | Area | Issue | Status |
| --- | --- | --- | --- |
| 5 | GMX Sepolia deployment | Resolved 2026-09-24. The addresses in `gmx-synthetics` main were stale; the [official docs](https://docs.gmx.io/docs/api/contracts/addresses/) list the live deployment, pinned to commit `bf30ebb`, and its OrderHandler is the one in active use. Config and vendored interfaces now follow the docs. A second, nearly idle router/handler pair also holds CONTROLLER (recorded in the config). | Closed 2026-09-25: `GmxOrderRoundTrip.t.sol` creates, cancels and executes real orders through the live router with our vendored `CreateOrderParams`. |
| 6 | Data Streams | Fetching reports needs Chainlink Data Streams credentials; none configured yet. | Needed before the checker can run against live Sepolia. |
| 7 | RPC | Fork tests default to the public Arbitrum Sepolia RPC, which is rate-limited; the round-trip suite takes ~80 s on it. | Set `ARBITRUM_SEPOLIA_RPC_URL` to a dedicated endpoint for regular use. |
