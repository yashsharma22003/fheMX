# Build plan

Milestone order agreed 2026-09-25. Each milestone ends with something testable, and the riskiest integration points come first. Status as of 2026-09-30: all milestones 1–8 done. Deployed and run end to end on live Arbitrum Sepolia ([live-run-2026-09-30.md](live-run-2026-09-30.md)).

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

## Done: milestone 5, complete the clone

- `UserAccount`: per-token balances with ERC20 collateral (Router approval + `sendTokens`), owner `withdraw(token, …)`, `cancelGmxOrder`, `closePosition` (GMX market decrease, fee from free ETH), and permissionless `reconcile` for lost callbacks. Adapter unchanged.
- Tests: 14 unit tests (`UserAccountRecovery.t.sol`); 6 new fork tests on live GMX: lost execution and cancellation callbacks recovered by reconcile (fee still collected), owner cancel, manual close of a real position, USDC collateral.
- Closes known issues 8 and 9; adds 12 (reconcile refuses if the position shrank after a lost-callback fill) and 13 (one manual close at a time).

## Done: milestone 7, stop-loss, take-profit and re-arm

- `SealedOrderAdapter`: `OrderKind.StopLoss` / `TakeProfit` against the account's existing position (no collateral; flat ETH fee reserve); direction by kind with the side selected on ciphertext; decreases skip the leverage check; execute trims to the live position or voids if it's gone; acceptable price below the check price when selling, above when buying. `rearm(orderId)` per D4.
- `UserAccount`: decrease orders (`MarketDecrease`, no collateral moves), decrease-aware `reconcile`, `cancelledByOwner`.
- Tests: 19 adapter unit tests (`SealedOrderAdapterDecrease.t.sol`), 4 more account tests; fork demo (`test/fork/SealedStopLossDemo.t.sol`): a sealed stop-loss closes a real position opened by a sealed limit entry, and a stop GMX rejects on slippage fills on the re-arm.
- Closes known issues 1–4. Found and recorded 14 (GMX pending price impact makes tight stop-loss bounds fail) and 15 (testnet drift; fixed in tests with fixtures).

## Done: known issue 14, GMX execution-price anchoring

- `acceptablePrice` is the user's slippage around GMX's own execution-price estimate (`Reader.getExecutionPrice`) at the check price, for increases, decreases and re-arms. The fork stop-loss demo now runs with real price impact.

## Done: milestone 6 (revised), Chainlink Data Feeds

- Data Streams replaced by free Chainlink Data Feeds (D7): `ChainlinkFeedPriceVerifier` behind the unchanged `IPriceVerifier`; decimals normalised to 8; optional L2 sequencer-uptime check. The adapter's age and newer-report rules apply to the feed's `updatedAt`.
- Tests: 8 unit tests; fork demo (`SealedLimitEntryFeedDemo.t.sol`) against the live Sepolia ETH/USD feed.
- The per-check fee (known issue 11) moves to after milestone 8, once live costs are measured.

## Milestone 8 so far: deploy, checker, client

- `contracts/script/Deploy.s.sol`: deploys account implementation, feed verifier and adapter from `config/networks/arbitrum-sepolia.json` (new `adapter` section), writes `deployments/`.
- `shared/` (new TypeScript package): config and deployment loading, viem and CoFHE clients, fixed-point helpers, ABIs generated from Foundry output.
- `checker/`: loop that checks open orders on feed updates, decrypts through CoFHE (`decryptForTx().withoutACP()`), executes, settles, re-arms and reconciles, logging latency and gas to `checker/metrics.jsonl`.
- `client/`: CLI for account, fund, order (local encryption with `@cofhe/sdk`), status, cancel, withdraw.
- Adapter intake now takes **one proof for all four encrypted fields** (what `encryptInputs` returns), verified with `Impl.verifyBatchInputs`; tests use a `BatchCofheClient` helper.
- **Rehearsed on a local anvil fork of Sepolia:** deploy succeeded; the client encrypted an order with the real CoFHE SDK and Fhenix's live verifier, and the adapter accepted the proof against the real TaskManager. `submitOrder` used 1,155,323 gas; one-order `checkBatch` 742,959 gas. Decryption can't run on a local fork (`not_publicly_allowed`: Fhenix's service checks the live chain) and waits for the live deployment.
- **Live run 2026-09-30:** deployed to Arbitrum Sepolia; a sealed short limit entry fired, filled on GMX and settled; a sealed stop-loss closed it; a non-firing order was checked three times and cancelled. Real CoFHE decryption 0.64–0.98 s per value; full numbers in [live-run-2026-09-30.md](live-run-2026-09-30.md).

## Milestones

Agreed 2026-09-25: interface-first, so the end-to-end demo (milestone 4) comes before the full clone. The adapter codes against `IUserAccount`; the clone is built in two steps behind that interface, so nothing is thrown away.

| # | Milestone | Done when | Layer |
| --- | --- | --- | --- |
| 1 | GMX order round trip, no FHE ✅ | A fork test sends a real market-increase order through the live ExchangeRouter from a test contract acting as the GMX account; a real cancel produces GMX's cancellation callback; a simulated keeper executes the order and produces the execution callback. | `contracts/test/fork`, `test/helpers` |
| 2 | `IUserAccount` + minimal clone ✅ | Interface for everything the adapter calls on the clone (lock, release, create GMX order, read position, pay protocol fee) and the callbacks it receives. | `contracts/src/account` |
| 3 | Sealed intake ✅ | Adapter accepts encrypted side, size, trigger and slippage, stores handles with the right grants, runs price-independent cap checks on ciphertext. Includes the replay tests. | `contracts/src/adapter` |
| 4 | Trigger check → execute, one order (**demo**) ✅ | `checkBatch` with one order and a mocked price report, zero-unless-fired decrypt, publish, `execute` into the clone. A full limit entry works end to end on the fork. Leverage cap evaluated in the check against the report price. Protocol fee (D6) computed at execute and collected after the fill. | `contracts/src/adapter`, `src/oracle` |
| 5 | Complete the clone ✅ | Owner cancel and manual close, ERC20 collateral, reconcile for lost callbacks. Adapter unchanged. Closes known issues 8 and 9. | `contracts/src/account` |
| 6 | Price source ✅ (revised) | Chainlink Data Feeds verifier instead of Data Streams (D7); report-age and newer-update rules on the feed's update time. Per-check fee deferred until live costs are known. | `contracts/src/oracle` |
| 7 | Decrease orders and re-arm ✅ | Stop-loss and take-profit, live-position size trim, `rearm()`, decrease fee (default 0). Fixes known issues 1–4. | `contracts/src/adapter`, `src/account` |
| 8 | Checker and client, live Sepolia ✅ | Contracts deployed to Sepolia with the feed verifier; real encryption with `@cofhe/sdk`; a checker loop that calls `checkBatch` on each feed update, decrypts and executes. Produces the latency and cost numbers in design §10. No paid services needed. | `checker/`, `client/`, `contracts/script` |

First demo scope: limit entries only; stop-loss and take-profit arrive in milestone 7.

## Next candidates

1. Per-check fee (known issue 11), sized from the live numbers.
2. Checker hardening (known issues 16, 17): own key, retry executes, batch reads, parallel decrypts, persisted cursor.
3. More markets (known issue 10: second price for non-ETH collateral).
4. Mainnet readiness: parameters, sequencer-uptime feed, audit.

## Working rules

- Each known issue becomes a failing test before its fix ([KNOWN_ISSUES.md](KNOWN_ISSUES.md)).
- New facts about GMX, CoFHE or Data Streams go in `integration/`; design changes go in the design doc and [decisions.md](decisions.md).
- Re-run `pnpm test:fork` before any live Sepolia session; GMX testnet addresses change.
