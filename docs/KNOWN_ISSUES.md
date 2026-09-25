# Known issues

Deferred on purpose; fix as the relevant code is written. When a test harness exists for the area, turn each item into a failing test first.

## Design gaps (from the v0.2 review)

| # | Area | Issue | Fix | Test to add |
| --- | --- | --- | --- | --- |
| 1 | §4 step 7 | Wording implies every order becomes `Rearmable` after the callback. | Only a slippage cancel sets `Rearmable`. | Fill and non-slippage cancel never set `Rearmable`. |
| 2 | §4 step 5, D2 | Position closed or liquidated before a decrease order fires: the size trim yields 0 and GMX rejects a zero-size decrease. | If the position no longer exists, cancel the sealed order and release its fees instead of calling `createOrder`. | Stop-loss fires after the position was closed. |
| 3 | D4 | `rearm()` doesn't restate the execute-time checks; the user can reduce the position between cancel and re-arm. | `rearm()` applies the same checks as `execute()` (public caps, live-position size trim). | Re-arm after a manual partial close. |
| 4 | §4 step 3 | "`valid` cannot go stale" is only true for increase orders. | Wording only. | — |

| 8 | Clone | Resolved 2026-09-25 (milestone 5): owner cancel (`cancelGmxOrder`), manual close (`closePosition`), ERC20 collateral; callback authentication done in milestone 2. | — | Fork tests in `UserAccountGmx.t.sol`. |
| 9 | Clone, fee model | Resolved 2026-09-25 (milestone 5): permissionless `reconcile(orderId)` settles a Pending order from GMX state once GMX no longer holds it; verified on a fork with a real lost callback (1-gas callback budget). | — | `test_lostExecutionCallback_*`, `test_lostCancellationCallback_*`. |
| 10 | Adapter markets | The leverage check and fee conversion price collateral with the index-token report, so they are correct only for markets whose index token is the collateral (WNT): ETH/USD today. | Before adding BTC/USD or others: take a second verified report for the collateral token in `checkBatch`, or restrict each market's collateral. | BTC/USD order with WNT collateral checks leverage at the ETH price. |
| 11 | Trigger checks | No per-check fee yet (design D3), so checks are free to call; griefing is bounded only by the minimum check interval. | Milestone 6, with the fee-model check-fee spread. | Check without fee reverts; fee refunded or rewarded on a fire. |
| 12 | Reconcile | If a callback is lost and the position then shrinks before anyone reconciles (liquidation, ADL), reconcile sees neither "grew" nor "collateral back" and refuses (`CannotReconcile`); the order stays Pending and its lock stuck. Manual closes can't cause this (blocked while adapter orders are in flight). | Low likelihood (needs a lost callback plus a liquidation first). Options: record GMX's position `increasedAtTime` at submit, or an owner-only override that settles as Executed without fee. | Liquidate the position between a lost-callback fill and reconcile. |
| 13 | Clone | Only one manual close can be in flight at a time, and adapter submits wait for it to leave GMX's order list. | Acceptable for v1; revisit if users need concurrent manual orders. | — |

## Environment

| # | Area | Issue | Status |
| --- | --- | --- | --- |
| 5 | GMX Sepolia deployment | Resolved 2026-09-24. The addresses in `gmx-synthetics` main were stale; the [official docs](https://docs.gmx.io/docs/api/contracts/addresses/) list the live deployment, pinned to commit `bf30ebb`, and its OrderHandler is the one in active use. Config and vendored interfaces now follow the docs. A second, nearly idle router/handler pair also holds CONTROLLER (recorded in the config). | Closed 2026-09-25: `GmxOrderRoundTrip.t.sol` creates, cancels and executes real orders through the live router with our vendored `CreateOrderParams`. |
| 6 | Data Streams | Fetching reports needs Chainlink Data Streams credentials; none configured yet. | Needed before the checker can run against live Sepolia. |
| 7 | RPC | Fork tests default to the public Arbitrum Sepolia RPC, which is rate-limited; the round-trip suite takes ~80 s on it. | Set `ARBITRUM_SEPOLIA_RPC_URL` to a dedicated endpoint for regular use. |
