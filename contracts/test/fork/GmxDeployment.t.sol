// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IGmxRoleStore, GmxRole} from "../../src/interfaces/gmx/IGmxRoleStore.sol";
import {NetworkConfig} from "../helpers/NetworkConfig.sol";

interface IExchangeRouterWiring {
    function orderHandler() external view returns (address);
}

/// @notice Fork smoke test: the addresses in config/networks/arbitrum-sepolia.json still point at a
///         live GMX deployment wired the way the design assumes. Run with `pnpm test:fork`.
contract GmxDeploymentForkTest is Test {
    NetworkConfig.Gmx private gmx;

    function setUp() public {
        assertEq(block.chainid, 421614, "fork must be Arbitrum Sepolia");
        gmx = NetworkConfig.gmx(NetworkConfig.arbitrumSepolia());
    }

    function test_contractsDeployed() public view {
        assertGt(gmx.dataStore.code.length, 0, "DataStore");
        assertGt(gmx.exchangeRouter.code.length, 0, "ExchangeRouter");
        assertGt(gmx.orderHandler.code.length, 0, "OrderHandler");
        assertGt(gmx.orderVault.code.length, 0, "OrderVault");
        assertGt(gmx.reader.code.length, 0, "Reader");
        assertGt(gmx.roleStore.code.length, 0, "RoleStore");
        assertGt(gmx.router.code.length, 0, "Router");
    }

    /// Callback authentication (design §3) relies on the OrderHandler holding CONTROLLER.
    function test_orderHandlerIsController() public view {
        assertTrue(IGmxRoleStore(gmx.roleStore).hasRole(gmx.orderHandler, GmxRole.CONTROLLER));
    }

    function test_exchangeRouterIsController() public view {
        assertTrue(IGmxRoleStore(gmx.roleStore).hasRole(gmx.exchangeRouter, GmxRole.CONTROLLER));
    }

    /// Two router/handler generations hold CONTROLLER on Sepolia; this pins the configured pair together.
    function test_exchangeRouterUsesConfiguredOrderHandler() public view {
        assertEq(IExchangeRouterWiring(gmx.exchangeRouter).orderHandler(), gmx.orderHandler);
    }
}
