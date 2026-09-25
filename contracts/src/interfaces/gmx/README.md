# Vendored GMX V2 interfaces

Minimal copies of the GMX V2 types this project calls, so we don't compile the whole of `gmx-synthetics`.

- Source: https://github.com/gmx-io/gmx-synthetics
- Pinned commit: `bf30ebb4cff17b7f92f8c738f145e75b871a1576` (`updates` branch, 2026-07-24). This is the commit GMX's docs pin the Arbitrum Sepolia addresses to (https://docs.gmx.io/docs/api/contracts/addresses/).
- Every vendored type and signature is identical at `main` @ `a85ea34`; the only differences between the two commits in these files are additions we don't use (TWAP orders, an internal `uiFeeFactor` order field).
- License of the originals: BUSL-1.1

Structs, enums and function signatures are copied verbatim, including field order, because ABI encoding depends on it. Before relying on these against a live deployment, confirm the deployment matches this commit (see `config/networks/arbitrum-sepolia.json`) and re-diff if GMX redeploys.

| File | Upstream source |
| --- | --- |
| `GmxTypes.sol` | `contracts/order/Order.sol` (enums), `contracts/order/IBaseOrderUtils.sol`, `contracts/event/EventUtils.sol` (structs) |
| `IGmxExchangeRouter.sol` | `contracts/router/IExchangeRouter.sol`, `BaseRouter.sol`, `utils/PayableMulticall.sol` |
| `IGmxOrderCallbackReceiver.sol` | `contracts/callback/IOrderCallbackReceiver.sol` |
| `IGmxGasFeeCallbackReceiver.sol` | `contracts/callback/IGasFeeCallbackReceiver.sol` |
| `IGmxRoleStore.sol` | `contracts/role/RoleStore.sol`, `contracts/role/Role.sol` |
