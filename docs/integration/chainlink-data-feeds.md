# Chainlink Data Feeds reference

The price source for trigger checks since 2026-09-30, replacing Chainlink Data Streams. Implemented by `contracts/src/oracle/ChainlinkFeedPriceVerifier.sol` behind the adapter's `IPriceVerifier` interface.

## Why Data Feeds, not Data Streams

| | Data Feeds (used) | Data Streams (not used) |
| --- | --- | --- |
| Cost | Free to read on-chain | Paid subscription, from $150/month per feed, no free tier |
| Model | Push: Chainlink writes each new answer on-chain | Pull: caller fetches a signed report off-chain and verifies it on-chain |
| Freshness | New answer on a deviation threshold or heartbeat; Sepolia ETH/USD updated every 30–120 s on 2026-09-30 | Sub-second |
| Who picks the price | Nobody: there is one current answer | The caller, among any valid report in the age window |
| What GMX uses | GMX lists these feeds as reference prices | GMX executes at Data Streams prices on Sepolia |

Trade-off accepted: triggers can fire a little later than with Data Streams, and a short spike that reverses between two feed updates can be missed. Execution still happens at GMX's own oracle price; the Reader-anchored acceptable price and the re-arm cover the small gap between the two sources. Data Streams can be added later as another `IPriceVerifier` without changing the adapter ([chainlink-data-streams.md](chainlink-data-streams.md)).

## How the adapter uses a feed

- The verifier prices **tokens**: `price(token, report)` returns the token feed's latest answer normalised to 8 decimals and its `updatedAt`; the report argument is ignored.
- Each token has its own max age; the verifier reverts with `StalePrice` beyond it. Sepolia settings: WETH and BTC 300 s, USDC.SG 90,000 s (USDC/USD updates every 24 h on Sepolia, ETH/USD and BTC/USD every 30–150 s).
- The adapter prices the index token for triggers (with its own stricter `maxReportAge`), the collateral token for leverage and fees, and long and short tokens for GMX's execution estimate.
- `checkBatch(market, orderIds, "")`: the report argument is ignored.
- The adapter's existing rules apply to `updatedAt`:
  - `maxReportAge`: rejects a stale index price for triggers. Set per deployment to at least the feed's heartbeat: 300 s is enough on Sepolia; Arbitrum One ETH/USD can go up to its 24 h heartbeat when the price is flat.
  - Strictly newer per order: an order is only re-checked after the feed publishes a new answer, since an unchanged answer carries no new information.
- Non-positive answers are rejected.
- **L2 sequencer:** on Arbitrum One, pass Chainlink's sequencer-uptime feed; prices are rejected while the sequencer is down and for a grace period after it restarts. None is configured on Sepolia.
- Feeds are fixed at deployment; no admin (design §6).

## Sepolia feeds (8 decimals)

Also in `config/networks/arbitrum-sepolia.json` under `chainlinkFeeds`.

| Feed | Address |
| --- | --- |
| ETH / USD | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` |
| BTC / USD | `0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69` |
| USDC / USD | `0x0153002d20B96532C639313c2d54c3dA09109309` |

## Verified

- Unit tests (`test/unit/ChainlinkFeedPriceVerifier.t.sol`): decimals normalisation, unknown market, non-positive answer, sequencer down and grace period.
- Fork tests (`test/fork/SealedLimitEntryFeedDemo.t.sol`): the live Sepolia ETH/USD feed is readable and fresh; a sealed limit entry fires on a feed update and fills on live GMX; the same feed round can't be checked twice; a stale feed is rejected.

## Not yet verified

- Feed behaviour on live Sepolia over time (update gaps, outages): milestone 8.
- Arbitrum One sequencer-uptime feed address and a suitable grace period.
