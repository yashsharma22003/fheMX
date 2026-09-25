# GMX V2 integration reference

What we rely on from GMX V2 and how each fact was checked. Last verified 2026-09-24 against `gmx-synthetics` source and the live Arbitrum Sepolia deployment.

## Source and versions

| Item | Value |
| --- | --- |
| Repo | [gmx-io/gmx-synthetics](https://github.com/gmx-io/gmx-synthetics) |
| Commit our interfaces are pinned to | `bf30ebb4cff17b7f92f8c738f145e75b871a1576` (`updates` branch, 2026-07-24), the commit GMX's docs pin the Sepolia addresses to |
| Also checked | `main` @ `a85ea34` (2026-07-31). Every type we copy is identical; the differences are TWAP orders and an internal `uiFeeFactor` order field. |
| Latest release tag | v2.2 (2025-09-09) |
| Our copies | `contracts/src/interfaces/gmx/`, with a README mapping each file to its upstream source |

We copy only the types we call rather than compiling GMX: `IExchangeRouter` pulls in most of the protocol. Field order in copied structs is ABI-significant and must stay verbatim.

## Addresses

Arbitrum Sepolia (chain 421614). Source of truth: [docs.gmx.io/docs/api/contracts/addresses](https://docs.gmx.io/docs/api/contracts/addresses/). Machine-readable copy: `config/networks/arbitrum-sepolia.json`.

| Contract | Address |
| --- | --- |
| ExchangeRouter | `0x6B489dD5bB1AAE8df246359d59aA7316760a75d2` |
| OrderHandler | `0xC881c2391611829d7bc81c12a285cB0201F08f8c` |
| OrderVault | `0x1b8AC606de71686fd2a1AEDEcb6E0EFba28909a2` |
| Router | `0x72F13a44C8ba16a678CAD549F17bc9e06d2B8bD2` |
| DataStore | `0xCF4c2C4c53157BcC01A596e3788fFF69cBBCD201` |
| RoleStore | `0x433E3C47885b929aEcE4149E3c835E565a20D95c` |
| Reader | `0x92659fEf40582ceCC3CBa4D096d28291C238D358` |
| EventEmitter | `0xa973c2692C1556E1a3d478e745e9a75624AEDc73` |
| SubaccountRouter | `0xAFdD3e0B6c162974594AcA157eA642B8847CC5b1` |
| GlvRouter | `0x792D48B94F430965FE85645cF72527b3343d4BdD` |

**Pitfalls found:**

- The addresses in `gmx-synthetics` main (`deployments/arbitrumSepolia/`, `docs/arbitrumSepolia-deployments.md`) are stale for ExchangeRouter and OrderHandler. Use the docs site.
- Two router/handler generations hold CONTROLLER at once. The other pair (`0x914afAA9…` / `0xc63632D7…`) was nearly idle: one EventEmitter event versus steady traffic from the docs' OrderHandler over ~800k blocks. Holding CONTROLLER does not identify the live pair.
- Testnet is redeployed more often than mainnet. `pnpm test:fork` checks the configured contracts exist, hold CONTROLLER, and that the router points at the configured handler.

**Re-verifying:** read `orderHandler()` on the router, `hasRole(addr, CONTROLLER)` on RoleStore, and count recent EventEmitter logs by emitter (first data word is the emitting contract).

## Tokens and markets (Sepolia)

From `config/tokens.ts` and `config/markets.ts`, identical at both commits.

| Token | Address | Oracle provider | Data Streams feed id |
| --- | --- | --- | --- |
| WETH | `0x980b62da83eff3d4576c647993b0c1d7faf17c73` | Chainlink Data Streams | `0x000359843a543ee2fe414dc14c7e7920ef10f4372990b79d6361cdc0dd1ba782` |
| BTC | `0xF79cE1Cf38A09D572b021B4C5548b75A14082F12` | Chainlink Data Streams | `0x00037da06d56d083fe599397a4769a042d63aa73dc4ef57709d31e9971a5b439` |
| CRV (synthetic) | — | Chainlink Data Streams | `0x00037c41d40228ff337f3c7339e635906bb60552d748654fe6f9ebfa6a83fc0e` |
| USDC.SG | `0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773` | Chainlink Data Streams (Circle USDC feed) | `0x0003dc85e8b01946bf9dfd8b0db860129181eb6105a8c8981d9f28e00b6f60d9` |

Markets: WETH/WETH-USDC.SG, BTC/BTC-USDC.SG, CRV/WETH-USDC.SG. No Sepolia token sets `oracleProvider`, so all default to Data Streams: our trigger feed and GMX's execution feed are the same source. Repo config, not yet read from on-chain DataStore.

## Behaviour we depend on

| Fact | Source | Consequence for us |
| --- | --- | --- |
| Positions are keyed by (account, market, collateralToken, isLong). | `Position.getPositionKey` | Per-user clone is the GMX account (D2). |
| Orders are two-step: `createOrder`, then a keeper calls `executeOrder` with signed prices. | `OrderHandler` | Orders fired by us execute a few blocks later at GMX's oracle price. |
| Oracle prices exist only inside the executing transaction, then are cleared. | `OracleModule.withOraclePrices` → `Oracle.clearAllPrices` (`setPrices` reverts `NonEmptyTokensWithPrices` if any remain) | We need our own price source for triggers: Data Streams. |
| `executeOrder`, `createOrder` and `cancelOrder` in OrderHandler are `globalNonReentrant`. | `OrderHandler.sol` | A callback cannot create an order; re-arm is a separate transaction (D4). |
| Callbacks are called with `try … {gas: callbackGasLimit}`; failures are caught and logged (`AfterOrderExecutionError`, etc.), not reverted. | `CallbackUtils.sol` | Settlement must not depend on callbacks succeeding. |
| Execution reverts up front with `InsufficientGasLeftForCallback` if too little gas remains to forward `callbackGasLimit`. | `CallbackUtils.validateGasLeftForCallback` | Keep `callbackGasLimit` modest. |
| `callbackContract` must have code or callbacks are skipped. | `CallbackUtils.isValidCallbackContract` | Clone must be deployed before its first order. |
| Unused execution fee is refunded via `IGasFeeCallbackReceiver.refundExecutionFee{value}` on the callback contract, with its own gas limit (`REFUND_EXECUTION_FEE_GAS_LIMIT`). | `CallbackUtils.refundExecutionFee`, `GasUtils` | Clone implements it and `receive()`. |
| Oversized decrease orders: `LimitDecrease` and `StopLossDecrease` are trimmed to position size; `MarketDecrease` reverts `InvalidDecreaseOrderSize`. | `DecreasePositionUtils.sol` lines 80–94 | Trim to live position size before submitting a market decrease. |
| `initialCollateralDeltaAmount` for decrease orders is capped to position collateral. | `DecreasePositionUtils.sol` | — |
| For increase orders, collateral is whatever was sent to OrderVault in the same multicall (`recordTransferIn`), minus the execution fee if the collateral is WNT. | `OrderUtils.createOrder` | Use `multicall([sendWnt, sendTokens, createOrder])`. |
| `cancelOrder` on the router: only the order's account may cancel. Market orders can only be cancelled after the request-expiration delay (`validateRequestCancellation`). Since `bf30ebb`, OrderHandler also lets order keepers cancel market orders. On cancel, the account gets the execution fee for the cancel's gas and `cancellationReceiver` gets the excess refund. | `ExchangeRouter.cancelOrder`, `OrderHandler.cancelOrder` | Clone can cancel its own pending GMX order, but not immediately after creating it. |
| CONTROLLER role key is `keccak256(abi.encode("CONTROLLER"))`. | `Role.sol` | Used for callback authentication. |

## Interfaces we copied

| Our file | Upstream |
| --- | --- |
| `GmxTypes.sol` | `Order.OrderType`, `Order.DecreasePositionSwapType`, `IBaseOrderUtils.CreateOrderParams*`, `EventUtils.EventLogData` and item structs |
| `IGmxExchangeRouter.sol` | `multicall`, `sendWnt`, `sendTokens`, `createOrder`, `updateOrder`, `cancelOrder` |
| `IGmxOrderCallbackReceiver.sol` | `afterOrderExecution`, `afterOrderCancellation`, `afterOrderFrozen` |
| `IGmxGasFeeCallbackReceiver.sol` | `refundExecutionFee` |
| `IGmxRoleStore.sol` | `hasRole`, `CONTROLLER` constant |

`OrderType` values we will use: `MarketIncrease` (2), `MarketDecrease` (4). The trigger logic lives in our adapter, so we submit market orders at reveal, not GMX limit or stop types.

## Not yet verified

- That `createOrder` with our copied `CreateOrderParams` succeeds against the live router (first integration test; [build-plan.md](../build-plan.md) milestone 1).
- Keeper liveness and typical execution delay on Sepolia.
- `maxCallbackGasLimit` and `REFUND_EXECUTION_FEE_GAS_LIMIT` values on the Sepolia DataStore.
