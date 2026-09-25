// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Vm} from "forge-std/Vm.sol";
import {NetworkConfig} from "./NetworkConfig.sol";
import {
    GmxOracleUtils,
    GmxPrice,
    GmxKeys,
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
