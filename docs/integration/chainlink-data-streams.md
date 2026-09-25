# Chainlink Data Streams reference

The price source for trigger checks. Last checked 2026-09-24.

## Why Data Streams

GMX V2 keeps no oracle price on-chain between executions, so the adapter needs its own. On Arbitrum Sepolia, every GMX token is priced from Data Streams (see [gmx-v2.md](gmx-v2.md#tokens-and-markets-sepolia)), so using the same feeds keeps our trigger price and GMX's execution price from the same source, a few blocks apart.

## How it works

- **Pull-based.** Reports are signed off-chain by Chainlink's DON and fetched by the consumer through the REST or WebSocket API (or an SDK, or Chainlink Automation's StreamsLookup). Nothing is published on-chain to read.
- **Verified on-chain.** The caller passes the signed report to the verifier proxy's `verify(payload, parameterPayload)`, which checks signatures and returns the decoded report. `parameterPayload` is the abi-encoded fee token address.
- **Metered.** Verification can charge a fee in the configured fee token.
- **Needs credentials.** Fetching reports requires Data Streams API access.

## Sepolia values

From `gmx-synthetics` `config/oracle.ts` and `config/tokens.ts` (identical at `bf30ebb` and `a85ea34`). Also in `config/networks/arbitrum-sepolia.json`.

| Item | Value |
| --- | --- |
| Verifier proxy | `0x2ff010DEbC1297f19579B4246cad07bd24F2488A` |
| Fee token | `0xb1D4538B4571d411F07960EF2838Ce337FE1E80E` |
| ETH/USD feed | `0x000359843a543ee2fe414dc14c7e7920ef10f4372990b79d6361cdc0dd1ba782` |
| BTC/USD feed | `0x00037da06d56d083fe599397a4769a042d63aa73dc4ef57709d31e9971a5b439` |
| CRV/USD feed | `0x00037c41d40228ff337f3c7339e635906bb60552d748654fe6f9ebfa6a83fc0e` |
| USDC/USD feed | `0x0003dc85e8b01946bf9dfd8b0db860129181eb6105a8c8981d9f28e00b6f60d9` |

Our interface: `contracts/src/interfaces/chainlink/IDataStreamsVerifier.sol` (same signature GMX declares).

## Rules the adapter enforces (design D3)

The caller chooses which valid report to submit, so:

- **Max report age** relative to `block.timestamp`: a few seconds, set after latency measurement.
- **Strictly increasing report timestamp per order:** stops a caller replaying an older, favourable report.
- **Feed must match the order's market.**
- **Minimum interval between checks per order:** limits how tightly repeated checks bracket the trigger.
- **One verification per batch:** `checkBatch` verifies the report once and applies it to every order in that market.

## Trust

A data-access credential is a standing key, but not an execution key: whoever holds it can fetch reports, not move funds. State it in the trust model (design §6).

## Not yet verified

- Report schema version and decoding for these Sepolia feeds.
- Verification fee amount and whether the fee token must be approved or pre-funded.
- Report availability and latency on Sepolia.
- Who will hold the credentials for the checker ([KNOWN_ISSUES.md](../KNOWN_ISSUES.md) item 6).
