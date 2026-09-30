# Sealed Order Privacy Layer for GMX V2

A privacy adapter that keeps conditional GMX V2 orders (limit entry, stop-loss, take-profit) sealed with Fhenix CoFHE until they fire. Target network: Arbitrum Sepolia. Docs index: [docs/README.md](docs/README.md).

## Layout

| Folder | Layer | Contents |
| --- | --- | --- |
| `contracts/` | On-chain (Foundry) | `src/adapter` order book and trigger logic, `src/account` per-user GMX account clones, `src/oracle` Data Streams report handling, `src/interfaces` vendored GMX and Chainlink interfaces. `test/unit` runs on CoFHE mocks, `test/fork` against an Arbitrum Sepolia fork, `test/helpers` shared test code. `script/` deploy scripts. |
| `checker/` | Off-chain keeper (TypeScript) | On each Chainlink feed update calls `checkBatch`, decrypts results through CoFHE, calls `execute`, `settle`, `rearm`, `reconcile`. Permissionless; logs latency and gas to `checker/metrics.jsonl`. |
| `client/` | User side (TypeScript) | CLI: fund your account, encrypt and submit sealed orders with `@cofhe/sdk`, status, cancel, withdraw. |
| `frontend/` | Web app (Next.js) | Trade, Orders, Account and Settings pages: encrypts orders in the browser with `@cofhe/sdk`, reads addresses from `deployments/` and ABIs from `shared`. Wallet through RainbowKit / wagmi. |
| `shared/` | TypeScript library | Config and deployment loading, viem + CoFHE clients, fixed-point helpers, ABIs generated from `contracts/out`. |
| `config/networks/` | Shared config | Network addresses (GMX, tokens, Chainlink feeds) and adapter deployment parameters, read by tests, the deploy script and the TypeScript packages. |
| `deployments/` | Deployed addresses | Written by the deploy script. |
| `docs/` | Docs | Design, decisions, build plan, known issues, GMX / CoFHE / Data Streams references. Index: `docs/README.md`. |

## Setup

Requires Foundry ≥ 1.0 (with anvil), Node 24 and pnpm 10.

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
| `pnpm typecheck` | Typecheck `shared`, `checker`, `client` and `frontend` |
| `pnpm abis` | Rebuild contracts and regenerate `shared/src/abis.ts` and `shared/src/deployment.ts` |
| `pnpm web` | Run the web app at http://localhost:3000 against the current deployment |
| `pnpm web:build` | Production build of the web app |

## Deploy and run on Arbitrum Sepolia

Needs a wallet with some Arbitrum Sepolia ETH in `.env` (`PRIVATE_KEY`); nothing paid.

```sh
cp .env.example .env && $EDITOR .env
set -a && . ./.env && set +a

# 1. Dry run on a fork, then deploy for real (writes deployments/arbitrum-sepolia.json)
cd contracts
forge script script/Deploy.s.sol --fork-url $ARBITRUM_SEPOLIA_RPC_URL
BROADCAST=true forge script script/Deploy.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast
cd ..

# 2. Run the checker (any funded key)
pnpm -F checker start

# 3. Place a sealed order from another terminal
pnpm -F client cli fund 0.05
pnpm -F client cli order --kind limit --side long --size 100 --trigger 2400 --slippage 100 --collateral 0.02
# other markets / collateral, e.g. BTC with USDC.SG:
pnpm -F client cli fund-token USDC_SG 50
pnpm -F client cli order --market BTC_USD --collateral-token USDC_SG --collateral 50 --side long --size 100 --trigger 80000
pnpm -F client cli status 1              # includes checks left in the order's budget
pnpm -F client cli topup 1 0.001         # add to order 1's check budget
```

Each check of an order costs a fixed fee (`checkFeeWei` in the network config, 0.00005 ETH on Sepolia) from that order's check budget (`--check-budget`, default 0.001 ETH = 20 checks); it reimburses whoever runs the checker, with a 10% spread to the fee collector.

A local rehearsal against `anvil --fork-url …` works for deploy, `fund` and `order` (real CoFHE encryption), but not for decryption, which only Fhenix's live service can do for live-chain ciphertexts. Delete `contracts/broadcast/Deploy.s.sol/421614` afterwards: the fork shares the chain id, and the checker reads its start block from there.

## Pinned versions

- CoFHE: `@cofhe/*` 0.7.1 with `@fhenixprotocol/cofhe-contracts` 0.2.0. Upgrade as a set.
- GMX interfaces: vendored from `gmx-synthetics` @ `bf30ebb`, the commit GMX's docs pin the Sepolia deployment to; see [contracts/src/interfaces/gmx/README.md](contracts/src/interfaces/gmx/README.md).
