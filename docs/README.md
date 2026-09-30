# Docs

Reference for the Sealed Order Privacy Layer. Current as of 2026-09-30.

| Doc | Read it for |
| --- | --- |
| [design-v0.2.md](design-v0.2.md) | The protocol: what it protects, architecture, order lifecycle, what stays sealed, trust model, limitations, open decisions with defaults. **Start here.** |
| [decisions.md](decisions.md) | Every decision and why, what it replaced, and assumptions that turned out wrong. |
| [fee-model.md](fee-model.md) | Fee model (D6): the spec as received, plus implementation notes on where the build differs and which milestone builds each part. |
| [build-plan.md](build-plan.md) | What's done, the proposed milestone order, open planning questions. |
| [KNOWN_ISSUES.md](KNOWN_ISSUES.md) | Deferred design gaps and environment gaps, each with its fix. |
| [integration/gmx-v2.md](integration/gmx-v2.md) | GMX V2: live Sepolia addresses and how to re-verify them, tokens and markets, protocol behaviour we depend on, copied interfaces. |
| [integration/cofhe.md](integration/cofhe.md) | Fhenix CoFHE: packages, components and who runs them, key custody, the contract API we use, decrypt flow, access control, testing. |
| [integration/chainlink-data-streams.md](integration/chainlink-data-streams.md) | Data Streams: pull model, Sepolia verifier and feed IDs, report rules the adapter enforces. |
| [archive/design-v0.1.md](archive/design-v0.1.md) | The original draft, kept for history. Contains statements later found wrong; don't build from it. |

Repo layout and commands are in the [root README](../README.md). Addresses used by code live in `config/networks/arbitrum-sepolia.json`.

## Status at a glance

- **Design:** v0.2, reviewed three times against GMX and Fhenix sources; the four deferred gaps (known issues 1–4) are closed.
- **Build:** milestones 1–5 and 7 done. On an Arbitrum Sepolia fork: sealed limit entries, stop-losses and take-profits fire on hidden triggers and execute on real GMX; failed fills re-arm once; accounts support USDC, owner cancel and close, and recover from lost callbacks.
- **Next:** milestone 6 (Chainlink Data Streams verification) and milestone 8 (checker and client on live Sepolia, needs Data Streams credentials). See [build-plan.md](build-plan.md).

## Key facts

- GMX V2 is not modified; we integrate from outside through per-user clone accounts.
- Fhenix decryption today is one Fhenix-operated TEE (Teecryptor) with a 3-of-6 split key; threshold decryption is planned, not live. Confidentiality depends on it.
- GMX keeps no oracle price on-chain between executions; triggers use Chainlink Data Streams, the same feeds GMX prices Sepolia markets from.
- For stop-loss and take-profit, only the trigger price is truly hidden; limit entries hide side, size and trigger. v1 leads with limit entries.
- GMX's official docs, not the repo's `main`, list the live Sepolia addresses.
