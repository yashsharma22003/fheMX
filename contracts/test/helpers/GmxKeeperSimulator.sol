// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Vm} from "forge-std/Vm.sol";
import {NetworkConfig} from "./NetworkConfig.sol";
import {
    GmxOracleUtils,
    GmxPrice,
    GmxKeys,
    IGmxDataStore,
    IGmxOracle,
    IGmxOrderHandler,
    IGmxRoleStoreMembers
} from "./GmxTestInterfaces.sol";

/// @notice Executes GMX orders on a fork the way a keeper would, without signed oracle reports.
/// @dev GMX's `executeOrder` sets prices from signed Data Streams reports via `oracle.setPrices`.
///      On a fork we can't sign those, so we set the same primary prices directly through the
///      controller-only `setPrimaryPrice`/`setTimestamps` (pranking as the OrderHandler, which holds
///      CONTROLLER), stub `setPrices` to a no-op, then call `executeOrder` as a real order keeper.
///      Everything after price-setting, including GMX's own `clearAllPrices`, runs unmodified.
library GmxKeeperSimulator {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct TokenPrice {
        address token;
        uint256 min;
        uint256 max;
    }

    /// @notice Test fixture: lift the market's reserve factors so small test positions always fit.
    /// @dev Sepolia pools are shared and drift: on 2026-09-30 the ETH/USD long side was at its reserve cap
    ///      (`InsufficientReserveForOpenInterest`), failing every fork test that opens a long. Pinning a block
    ///      needs an archive RPC; instead tests raise the caps as a CONTROLLER, like the price fixture above.
    function ensureOpenInterestCapacity(NetworkConfig.Gmx memory gmx, address market) internal {
        vm.startPrank(gmx.orderHandler);
        for (uint256 i; i < 2; i++) {
            bool isLong = i == 0;
            IGmxDataStore(gmx.dataStore).setUint(GmxKeys.reserveFactorKey(market, isLong), 1_000e30);
            IGmxDataStore(gmx.dataStore).setUint(GmxKeys.openInterestReserveFactorKey(market, isLong), 1_000e30);
        }
        vm.stopPrank();
    }

    /// @notice Test fixture: turn off position price impact on the market, so fills happen at the oracle price.
    /// @dev The Sepolia ETH/USD pool is heavily long-imbalanced; GMX holds a new long's negative price impact as
    ///      pending and applies it on close, so on 2026-09-30 a $100 long closed ~15% below the oracle price.
    ///      Tests that assert on slippage bounds use this to test our logic rather than testnet pool state.
    function disablePositionImpact(NetworkConfig.Gmx memory gmx, address market) internal {
        vm.startPrank(gmx.orderHandler);
        IGmxDataStore(gmx.dataStore).setUint(GmxKeys.positionImpactFactorKey(market, true), 0);
        IGmxDataStore(gmx.dataStore).setUint(GmxKeys.positionImpactFactorKey(market, false), 0);
        vm.stopPrank();
    }

    /// @dev GMX prices are USD per smallest token unit, scaled so that price * amount has 30 decimals.
    function usdPrice(uint256 usdWhole, uint8 tokenDecimals) internal pure returns (uint256) {
        return usdWhole * 10 ** (30 - tokenDecimals);
    }

    function orderKeeper(NetworkConfig.Gmx memory gmx) internal view returns (address) {
        return IGmxRoleStoreMembers(gmx.roleStore).getRoleMembers(GmxKeys.ORDER_KEEPER, 0, 1)[0];
    }

    function executeOrder(NetworkConfig.Gmx memory gmx, bytes32 key, TokenPrice[] memory prices) internal {
        vm.startPrank(gmx.orderHandler);
        for (uint256 i; i < prices.length; i++) {
            IGmxOracle(gmx.oracle).setPrimaryPrice(prices[i].token, GmxPrice.Props(prices[i].min, prices[i].max));
        }
        IGmxOracle(gmx.oracle).setTimestamps(block.timestamp, block.timestamp);
        vm.stopPrank();

        vm.mockCall(gmx.oracle, abi.encodeWithSelector(IGmxOracle.setPrices.selector), "");

        GmxOracleUtils.SetPricesParams memory empty;
        vm.prank(orderKeeper(gmx));
        IGmxOrderHandler(gmx.orderHandler).executeOrder(key, empty);

        vm.clearMockedCalls();
    }
}
