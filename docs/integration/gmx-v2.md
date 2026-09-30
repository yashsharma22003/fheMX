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

## Verified on a fork (milestone 1)

`contracts/test/fork/GmxOrderRoundTrip.t.sol`, 2026-09-25:

- `multicall([sendWnt(orderVault, collateral + fee), createOrder(params)])` with our copied `CreateOrderParams` creates a market-increase order on the live router; the order is stored under the calling contract's account.
- Cancelling before `REQUEST_EXPIRATION_TIME` reverts with `RequestNotYetCancellable(age, expiration, "Order")`.
- Cancelling after it calls `afterOrderCancellation` on the callback contract, from a CONTROLLER holder, and returns the collateral as native ETH to `cancellationReceiver` (with `shouldUnwrapNativeToken`).
- A keeper execution calls `afterOrderExecution` from a CONTROLLER holder, opens the position under the account, clears oracle prices, and refunds unused execution fee through `refundExecutionFee` with ETH attached.

## Verified on a fork (milestone 5)

`contracts/test/fork/UserAccountGmx.t.sol`, 2026-09-25:

- A callback given 1 gas fails inside GMX, which catches it and still executes or cancels the order: the account receives nothing, so settlement needs `reconcile`.
- After execution or cancellation the order key is removed from DataStore `ORDER_LIST` (`containsBytes32`).
- ERC20 collateral (USDC.SG) works with an approval to the **Router** (`0x72F1…`, not the ExchangeRouter) and `sendTokens(token, orderVault, amount)` in the multicall; `deal` works on USDC.SG in fork tests.
- A `MarketDecrease` with `acceptablePrice = 0` (long) closes the full position; collateral returns as native ETH with `shouldUnwrapNativeToken`.

## Verified on a fork (milestone 7), and testnet caveats

`contracts/test/fork/SealedStopLossDemo.t.sol`, 2026-09-30:

- A `MarketDecrease` with `initialCollateralDeltaAmount = 0` closing the full size returns the collateral as native ETH; a long close with `acceptablePrice` above the execution price is cancelled with `OrderNotFulfillableAtAcceptablePrice(executionPrice, acceptablePrice)`.
- **Price impact in the execution price:** GMX validates `acceptablePrice` against an execution price that includes the trade's *own* price impact (`PositionUtils.getExecutionPriceForDecrease` / `…ForIncrease`). The position's pending impact from opening is settled separately in USD and does not move that price. On 2026-09-30 the Sepolia ETH/USD pool was short-heavy, so closing a $100 long (worsening the balance) was priced at $1,937 against a $2,290 oracle price. The adapter anchors `acceptablePrice` on `Reader.getExecutionPrice` for this reason (known issue 14).
- **Reserve cap:** on 2026-09-30 the ETH/USD long side was at its open-interest reserve cap (`InsufficientReserveForOpenInterest`), so no new long could open. Market keys (all 30-decimal factors): `RESERVE_FACTOR` 2.75e30, `OPEN_INTEREST_RESERVE_FACTOR` 2.7e30, `MAX_OPEN_INTEREST` $70M per side, `POSITION_IMPACT_FACTOR` 4.5e23 (positive) / 5e23 (negative), exponent 2.
- Test fixture in `GmxKeeperSimulator`: `ensureOpenInterestCapacity` raises the reserve factors as a CONTROLLER.

## Execution-price estimate

`Reader.getExecutionPrice(dataStore, market, prices, positionSizeInUsd, positionSizeInTokens, sizeDeltaUsd, pendingImpactAmount, isLong)` (vendored as `IGmxReader`) returns `ExecutionPriceResult.executionPrice` in GMX's per-unit 30-decimal format. `sizeDeltaUsd` is positive for an increase, negative for a decrease. Position fields come from DataStore keys `keccak256(abi.encode(positionKey, SIZE_IN_USD | SIZE_IN_TOKENS | PENDING_IMPACT_AMOUNT))` (the last is an int). The Reader is redeployed with GMX; its address is in `config/networks/arbitrum-sepolia.json`.

## Keeper simulator (tests only)

Real execution needs signed Data Streams reports, which a fork test can't produce. `contracts/test/helpers/GmxKeeperSimulator.sol` instead:

1. Pranks as the OrderHandler (a CONTROLLER) and calls the Oracle's controller-only `setPrimaryPrice` for each market token and `setTimestamps(now, now)`.
2. Stubs `Oracle.setPrices` to a no-op with `vm.mockCall`.
3. Calls `OrderHandler.executeOrder(key, emptyParams)` as the first `ORDER_KEEPER` role member.

Everything after price-setting runs unmodified, including GMX's `clearAllPrices`. Timestamps must satisfy GMX's checks: for market orders, oracle timestamps ≥ the order's `updatedAtTime` and ≤ `updatedAtTime + REQUEST_EXPIRATION_TIME`.

Price units: USD per smallest token unit, scaled so price × amount has 30 decimals. $2,500 ETH (18 decimals) = `2500e12`; $1 USDC (6 decimals) = `1e24`.

## Sepolia parameters (DataStore, read 2026-09-25)

| Key | Value |
| --- | --- |
| `WNT` | `0x980B62Da83eFf3D4576C647993b0c1D7faf17c73` (same as WETH) |
| `REQUEST_EXPIRATION_TIME` | 300 s |
| `MAX_CALLBACK_GAS_LIMIT` | 2,000,000 |
| `REFUND_EXECUTION_FEE_GAS_LIMIT` | 200,000 |
| `MIN_COLLATERAL_USD` | $1 |
| `MIN_POSITION_SIZE_USD` | $1 |
| `MAX_DATA_LENGTH` | 32 |
| Oracle | `0x0dC4e24C63C24fE898Dda574C962Ba7Fbb146964` |

Market tokens: ETH/USD `0xb6fC4C9eB02C35A134044526C62bb15014Ac0Bcc` (long WETH, short USDC.SG); BTC/USD `0x3A83246bDDD60c4e71c91c10D9A66Fd64399bBCf` (long BTC, short USDC.SG). The DataStore market list has 10 markets, all with USDC.SG as short token; the rest aren't in our config yet.

## Not yet verified

- Keeper liveness and typical execution delay on live Sepolia.
- Execution with a non-zero gas price (fork tests run at gas price 0, so the whole execution fee is refunded).
