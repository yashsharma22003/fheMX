# Sealed Order Privacy Layer for GMX V2

A privacy adapter that keeps conditional GMX V2 orders (limit entry, stop-loss, take-profit) sealed with Fhenix CoFHE until they fire. Target network: Arbitrum Sepolia. Docs index: [docs/README.md](docs/README.md).

## Layout

| Folder | Layer | Contents |
| --- | --- | --- |
| `contracts/` | On-chain (Foundry) | `src/adapter` order book and trigger logic, `src/account` per-user GMX account clones, `src/oracle` Data Streams report handling, `src/interfaces` vendored GMX and Chainlink interfaces. `test/unit` runs on CoFHE mocks, `test/fork` against an Arbitrum Sepolia fork, `test/helpers` shared test code. `script/` deploy scripts. |
| `checker/` | Off-chain keeper (TypeScript) | Fetches Data Streams reports and calls `checkBatch`, publishes decrypt results, calls `execute` / `rearm`. Permissionless. |
| `client/` | User side (TypeScript) | Encrypts order fields with `@cofhe/sdk` and submits sealed orders. |
| `config/networks/` | Shared config | Network addresses (GMX, tokens, Data Streams), read by contracts tests, scripts and both TypeScript packages. |
| `docs/` | Docs | Design, decisions, build plan, known issues, GMX / CoFHE / Data Streams references. Index: `docs/README.md`. |

## Setup

Requires Foundry ≥ 1.0, Node 24 and pnpm 10.

```sh
pnpm install
cp .env.example .env   # optional; fork tests fall back to the public RPC
```

## Commands

| Command | What it does |
| --- | --- |
| `pnpm build` | Compile contracts |
| `pnpm test` | Unit tests on CoFHE mocks (no network) |
| `pnpm test:fork` | Fork tests against Arbitrum Sepolia; checks the GMX addresses in `config/` are still live |
| `pnpm typecheck` | Typecheck `checker` and `client` |

## Pinned versions

- CoFHE: `@cofhe/*` 0.7.1 with `@fhenixprotocol/cofhe-contracts` 0.2.0. Upgrade as a set.
- GMX interfaces: vendored from `gmx-synthetics` @ `bf30ebb`, the commit GMX's docs pin the Sepolia deployment to; see [contracts/src/interfaces/gmx/README.md](contracts/src/interfaces/gmx/README.md).
