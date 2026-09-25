# Build plan

Milestone order agreed 2026-09-25. Each milestone ends with something testable, and the riskiest integration points come first. Status as of 2026-09-25: setup done, milestone 1 in progress.

## Done: setup

- Monorepo with one folder per layer (see the [root README](../README.md)).
- Foundry with CoFHE mocks; unit smoke test covers encrypted input → compare → select-to-zero → public decrypt → publish → read.
- Arbitrum Sepolia fork test: GMX contracts deployed, router and handler hold CONTROLLER, router points at the configured handler.
- GMX and Chainlink interfaces copied and pinned ([integration/gmx-v2.md](integration/gmx-v2.md)).
- `checker/` and `client/` TypeScript packages with `@cofhe/sdk` and viem, placeholders only.

## Milestones

Agreed 2026-09-25: interface-first, so the end-to-end demo (milestone 4) comes before the full clone. The adapter codes against `IUserAccount`; the clone is built in two steps behind that interface, so nothing is thrown away.

| # | Milestone | Done when | Layer |
| --- | --- | --- | --- |
| 1 | GMX order round trip, no FHE | A fork test sends a real market-increase order through the live ExchangeRouter from a test contract acting as the GMX account; a real cancel produces GMX's cancellation callback; a simulated keeper executes the order and produces the execution callback. | `contracts/test/fork`, `test/helpers` |
| 2 | `IUserAccount` + minimal clone | Interface for everything the adapter calls on the clone (lock, release, create GMX order, read position) and the callbacks it receives. Minimal clone implements locks and order creation only. | `contracts/src/account` |
| 3 | Sealed intake | Adapter accepts encrypted side, size, trigger and slippage, stores handles with the right grants, runs cap checks on ciphertext against the clone's locked collateral. Includes the replay test. | `contracts/src/adapter` |
| 4 | Trigger check → execute, one order (**demo**) | `checkBatch` with one order and a mocked price report, zero-unless-fired decrypt, publish, `execute` into the clone. A full limit entry works end to end on the fork. | `contracts/src/adapter`, `src/oracle` |
| 5 | Complete the clone | Owner withdraw and cancel, callback authentication (CONTROLLER + own order keys), fee refunds. Adapter unchanged. Closes known issue 8. | `contracts/src/account` |
| 6 | Data Streams verification | Real report decoding and verification; report-age and increasing-timestamp rules. Needs credentials. | `contracts/src/oracle` |
| 7 | Decrease orders and re-arm | Stop-loss and take-profit, live-position size trim, `rearm()`. Fixes known issues 1–4. | `contracts/src/adapter`, `src/account` |
| 8 | Checker and client, live Sepolia | Real encryption with `@cofhe/sdk`, a checker loop, contracts deployed to Sepolia. Produces the latency and cost numbers in design §10. | `checker/`, `client/`, `contracts/script` |

First demo scope: limit entries only; stop-loss and take-profit arrive in milestone 7.

## Open questions

1. **Data Streams access.** Do we have Chainlink Data Streams credentials for Arbitrum Sepolia, or do we request them? Decides when milestone 6 can start.

## Working rules

- Each known issue becomes a failing test before its fix ([KNOWN_ISSUES.md](KNOWN_ISSUES.md)).
- New facts about GMX, CoFHE or Data Streams go in `integration/`; design changes go in the design doc and [decisions.md](decisions.md).
- Re-run `pnpm test:fork` before any live Sepolia session; GMX testnet addresses change.
