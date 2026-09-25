# Known issues

Deferred on purpose; fix as the relevant code is written. When a test harness exists for the area, turn each item into a failing test first.

## Design gaps (from the v0.2 review)

| # | Area | Issue | Fix | Test to add |
| --- | --- | --- | --- | --- |
| 1 | §4 step 7 | Wording implies every order becomes `Rearmable` after the callback. | Only a slippage cancel sets `Rearmable`. | Fill and non-slippage cancel never set `Rearmable`. |
| 2 | §4 step 5, D2 | Position closed or liquidated before a decrease order fires: the size trim yields 0 and GMX rejects a zero-size decrease. | If the position no longer exists, cancel the sealed order and release its fees instead of calling `createOrder`. | Stop-loss fires after the position was closed. |
| 3 | D4 | `rearm()` doesn't restate the execute-time checks; the user can reduce the position between cancel and re-arm. | `rearm()` applies the same checks as `execute()` (public caps, live-position size trim). | Re-arm after a manual partial close. |
| 4 | §4 step 3 | "`valid` cannot go stale" is only true for increase orders. | Wording only. | — |

| 8 | Milestones 2–4 | The minimal clone used for the first demo has no callback authentication, owner withdraw or cancel. It must not be deployed beyond tests. | Milestone 5: callbacks only from GMX `CONTROLLER` holders and only for the clone's own order keys; owner paths. | A callback from a non-CONTROLLER address is rejected (write it failing in milestone 2). |

## Environment

| # | Area | Issue | Status |
| --- | --- | --- | --- |
| 5 | GMX Sepolia deployment | Resolved 2026-09-24. The addresses in `gmx-synthetics` main were stale; the [official docs](https://docs.gmx.io/docs/api/contracts/addresses/) list the live deployment, pinned to commit `bf30ebb`, and its OrderHandler is the one in active use. Config and vendored interfaces now follow the docs. A second, nearly idle router/handler pair also holds CONTROLLER (recorded in the config). | Still worth a fork test that creates a real order through the live router with our vendored `CreateOrderParams`, as the first GMX integration step. |
| 6 | Data Streams | Fetching reports needs Chainlink Data Streams credentials; none configured yet. | Needed before the checker can run against live Sepolia. |
| 7 | RPC | Fork tests default to the public Arbitrum Sepolia RPC, which is rate-limited. | Set `ARBITRUM_SEPOLIA_RPC_URL` to a dedicated endpoint for regular use. |
