# Build plan

Milestone order agreed 2026-09-25. Each milestone ends with something testable, and the riskiest integration points come first. Status as of 2026-09-25: milestones 1–4 done (end-to-end demo working on a fork); milestone 5 next.

## Done: setup

- Monorepo with one folder per layer (see the [root README](../README.md)).
- Foundry with CoFHE mocks; unit smoke test covers encrypted input → compare → select-to-zero → public decrypt → publish → read.
- Arbitrum Sepolia fork test: GMX contracts deployed, router and handler hold CONTROLLER, router points at the configured handler.
- GMX and Chainlink interfaces copied and pinned ([integration/gmx-v2.md](integration/gmx-v2.md)).
- `checker/` and `client/` TypeScript packages with `@cofhe/sdk` and viem, placeholders only.

## Done: milestone 1, GMX order round trip

`contracts/test/fork/GmxOrderRoundTrip.t.sol` (4 tests) against the live Sepolia deployment: our copied `CreateOrderParams` are accepted, early cancel reverts, cancel after expiry produces the cancellation callback and returns collateral, and a simulated keeper execution opens the position, produces the execution callback and refunds the fee. Reusable helpers in `contracts/test/helpers/`: `GmxKeeperSimulator`, `GmxAccountProbe`, `NetworkConfig`, `GmxTestInterfaces`. Details in [integration/gmx-v2.md](integration/gmx-v2.md#verified-on-a-fork-milestone-1).

## Done: milestone 2, `IUserAccount` and the clone

- `contracts/src/account/`: `IUserAccount` (what the adapter calls), `UserAccount` (EIP-1167 clone implementation), `UserAccountFactory` (one deterministic clone per owner, adapter fixed).
- Locks for collateral, two execution fees (D4) and the protocol-fee reserve (D6); `submit` builds GMX params itself and always routes funds and callbacks to the clone; callbacks record outcomes and accept only GMX `CONTROLLER` holders; cancelled collateral returns under the lock for a re-arm; `positionSizeUsd` reads GMX's DataStore.
- Tests: 25 unit tests on GMX mocks (`test/unit/UserAccount.t.sol`); 3 fork tests on live GMX (`test/fork/UserAccountGmx.t.sol`) covering fill + fee + release, and cancel + successful second attempt.

## Done: milestone 3, sealed intake

- `contracts/src/adapter/SealedOrderAdapter.sol`: `submitOrder` verifies four encrypted inputs (side, size, trigger, slippage) bound to the caller, runs price-independent caps on ciphertext into an encrypted `intakeValid` flag, grants access to the adapter and the owner only, and locks collateral, two execution fees and the max-order fee reserve in the user's account (created on first use). `cancelOrder` releases the lock. All parameters immutable.
- Tests: 18 unit tests on CoFHE mocks (`test/unit/SealedOrderAdapterIntake.t.sol`), including both replay cases (another user's inputs; inputs bound to another contract), cap boundaries, and that an invalid order looks like any other.
- Gas on mocks (mock overhead excluded): `submitOrder` ≈ 2.0M including first-time account creation; `cancelOrder` ≈ 60k.

## Done: milestone 4, trigger check → execute (end-to-end demo)

- `SealedOrderAdapter.checkBatch(market, orderIds, report)`: verifies the report through `IPriceVerifier` (mocked until milestone 6), enforces max report age, strictly newer report per order and a minimum check interval, then computes `fired = intakeValid AND crossed AND leverageOk` on ciphertext and makes `select(fired, value, 0)` of size, side and slippage publicly decryptable. The trigger price is never decrypted.
- `execute`: publishes the three decryptions (signature-checked by CoFHE), re-checks the independent caps in plaintext, derives `acceptablePrice` from the check price and slippage, records the protocol fee, submits through the user's account.
- `settle`: after the account reports `Executed`, pays the fee and releases the rest of the lock. Owner can close an order GMX cancelled (automatic re-arm is milestone 7).
- Tests: 20 unit tests (`SealedOrderAdapterTrigger.t.sol`); fork demo (`test/fork/SealedLimitEntryDemo.t.sol`) with live GMX, CoFHE mocks and the keeper simulator: a sealed long limit entry fires, fills and pays the fee; a zero-slippage order is cancelled by GMX with no fee and all funds recoverable.
- Gas on mocks: `checkBatch` ≈ 1.5M per order; `execute` ≈ 570k; `settle` ≈ 90k.

## Milestones

Agreed 2026-09-25: interface-first, so the end-to-end demo (milestone 4) comes before the full clone. The adapter codes against `IUserAccount`; the clone is built in two steps behind that interface, so nothing is thrown away.

| # | Milestone | Done when | Layer |
| --- | --- | --- | --- |
| 1 | GMX order round trip, no FHE ✅ | A fork test sends a real market-increase order through the live ExchangeRouter from a test contract acting as the GMX account; a real cancel produces GMX's cancellation callback; a simulated keeper executes the order and produces the execution callback. | `contracts/test/fork`, `test/helpers` |
| 2 | `IUserAccount` + minimal clone ✅ | Interface for everything the adapter calls on the clone (lock, release, create GMX order, read position, pay protocol fee) and the callbacks it receives. | `contracts/src/account` |
| 3 | Sealed intake ✅ | Adapter accepts encrypted side, size, trigger and slippage, stores handles with the right grants, runs price-independent cap checks on ciphertext. Includes the replay tests. | `contracts/src/adapter` |
| 4 | Trigger check → execute, one order (**demo**) ✅ | `checkBatch` with one order and a mocked price report, zero-unless-fired decrypt, publish, `execute` into the clone. A full limit entry works end to end on the fork. Leverage cap evaluated in the check against the report price. Protocol fee (D6) computed at execute and collected after the fill. | `contracts/src/adapter`, `src/oracle` |
| 5 | Complete the clone | Owner cancel and manual close, ERC20 collateral, reconcile for lost callbacks. Adapter unchanged. Closes known issues 8 and 9. | `contracts/src/account` |
| 6 | Data Streams verification | Real report decoding and verification; report-age and increasing-timestamp rules; D3 per-check fee with its spread to the fee collector. Needs credentials. | `contracts/src/oracle` |
| 7 | Decrease orders and re-arm | Stop-loss and take-profit, live-position size trim, `rearm()`, decrease fee (default 0). Fixes known issues 1–4. | `contracts/src/adapter`, `src/account` |
| 8 | Checker and client, live Sepolia | Real encryption with `@cofhe/sdk`, a checker loop, contracts deployed to Sepolia. Produces the latency and cost numbers in design §10. | `checker/`, `client/`, `contracts/script` |

First demo scope: limit entries only; stop-loss and take-profit arrive in milestone 7.

## Open questions

1. **Data Streams access.** Do we have Chainlink Data Streams credentials for Arbitrum Sepolia, or do we request them? Decides when milestone 6 can start.

## Working rules

- Each known issue becomes a failing test before its fix ([KNOWN_ISSUES.md](KNOWN_ISSUES.md)).
- New facts about GMX, CoFHE or Data Streams go in `integration/`; design changes go in the design doc and [decisions.md](decisions.md).
- Re-run `pnpm test:fork` before any live Sepolia session; GMX testnet addresses change.
