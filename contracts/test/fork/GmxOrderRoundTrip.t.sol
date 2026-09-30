// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IGmxRoleStore, GmxRole} from "../../src/interfaces/gmx/IGmxRoleStore.sol";
import {NetworkConfig} from "../helpers/NetworkConfig.sol";
import {GmxAccountProbe} from "../helpers/GmxAccountProbe.sol";
import {GmxKeeperSimulator} from "../helpers/GmxKeeperSimulator.sol";
import {IGmxDataStore, IGmxOracle, GmxKeys} from "../helpers/GmxTestInterfaces.sol";

/// @notice Milestone 1: a real GMX V2 order round trip on an Arbitrum Sepolia fork, no FHE.
///         Proves our vendored CreateOrderParams are accepted by the live router and that GMX's
///         cancellation and execution callbacks reach the account contract.
contract GmxOrderRoundTripForkTest is Test {
    uint256 private constant ETH_PRICE_USD = 2500;
    uint256 private constant COLLATERAL = 0.02 ether; // ~$50
    uint256 private constant EXECUTION_FEE = 0.001 ether;
    uint256 private constant SIZE_USD = 100e30; // 2x leverage
    uint256 private constant CALLBACK_GAS_LIMIT = 500_000;

    NetworkConfig.Gmx private gmx;
    NetworkConfig.Market private ethUsd;
    GmxAccountProbe private probe;

    function setUp() public {
        assertEq(block.chainid, 421614, "fork must be Arbitrum Sepolia");
        string memory json = NetworkConfig.arbitrumSepolia();
        gmx = NetworkConfig.gmx(json);
        ethUsd = NetworkConfig.market(json, "ETH_USD");
        GmxKeeperSimulator.ensureOpenInterestCapacity(gmx, ethUsd.marketToken);
        probe = new GmxAccountProbe(gmx.exchangeRouter, gmx.orderVault, gmx.wnt);
        vm.deal(address(this), 10 ether);
    }

    function _createLong() internal returns (bytes32 key) {
        key = probe.createMarketIncrease{value: COLLATERAL + EXECUTION_FEE}(
            ethUsd.marketToken, true, SIZE_USD, type(uint256).max, EXECUTION_FEE, CALLBACK_GAS_LIMIT
        );
    }

    function _orderCount() internal view returns (uint256) {
        return IGmxDataStore(gmx.dataStore).getBytes32Count(GmxKeys.accountOrderListKey(address(probe)));
    }

    function _positionCount() internal view returns (uint256) {
        return IGmxDataStore(gmx.dataStore).getBytes32Count(GmxKeys.accountPositionListKey(address(probe)));
    }

    function _isController(address account) internal view returns (bool) {
        return IGmxRoleStore(gmx.roleStore).hasRole(account, GmxRole.CONTROLLER);
    }

    function _ethUsdPrices() internal view returns (GmxKeeperSimulator.TokenPrice[] memory prices) {
        prices = new GmxKeeperSimulator.TokenPrice[](2);
        uint256 eth = GmxKeeperSimulator.usdPrice(ETH_PRICE_USD, 18);
        uint256 usdc = GmxKeeperSimulator.usdPrice(1, 6);
        prices[0] = GmxKeeperSimulator.TokenPrice(ethUsd.longToken, eth, eth);
        prices[1] = GmxKeeperSimulator.TokenPrice(ethUsd.shortToken, usdc, usdc);
    }

    function test_createOrder_storesOrderForAccount() public {
        bytes32 key = _createLong();

        assertTrue(key != bytes32(0), "order key");
        assertEq(_orderCount(), 1, "order stored under the probe account");
        assertEq(probe.callbackCount(), 0, "no callback on creation");
    }

    function test_cancelOrder_beforeRequestExpiry_reverts() public {
        bytes32 key = _createLong();
        uint256 expiry = IGmxDataStore(gmx.dataStore).getUint(GmxKeys.REQUEST_EXPIRATION_TIME);

        vm.expectRevert(abi.encodeWithSignature("RequestNotYetCancellable(uint256,uint256,string)", 0, expiry, "Order"));
        probe.cancelOrder(key);
    }

    function test_cancelOrder_afterRequestExpiry_triggersCancellationCallback() public {
        bytes32 key = _createLong();
        uint256 expiry = IGmxDataStore(gmx.dataStore).getUint(GmxKeys.REQUEST_EXPIRATION_TIME);
        vm.warp(block.timestamp + expiry + 1);

        uint256 balanceBefore = address(probe).balance;
        probe.cancelOrder(key);

        GmxAccountProbe.Callback memory cb = probe.lastCallbackOfKind(GmxAccountProbe.CallbackKind.Cancellation);
        assertEq(cb.key, key, "cancellation callback for our order");
        assertTrue(_isController(cb.sender), "callback sender holds CONTROLLER");
        assertEq(_orderCount(), 0, "order removed");
        assertGe(address(probe).balance - balanceBefore, COLLATERAL, "collateral returned to cancellationReceiver");
    }

    function test_keeperExecutesOrder_opensPositionAndTriggersExecutionCallback() public {
        bytes32 key = _createLong();
        vm.warp(block.timestamp + 1);

        GmxKeeperSimulator.executeOrder(gmx, key, _ethUsdPrices());

        assertEq(probe.lastCallbackOfKind(GmxAccountProbe.CallbackKind.Cancellation).key, bytes32(0), "not cancelled");
        GmxAccountProbe.Callback memory cb = probe.lastCallbackOfKind(GmxAccountProbe.CallbackKind.Execution);
        assertEq(cb.key, key, "execution callback for our order");
        assertTrue(_isController(cb.sender), "callback sender holds CONTROLLER");
        assertEq(_orderCount(), 0, "order consumed");
        assertEq(_positionCount(), 1, "position opened for the probe account");
        assertEq(IGmxOracle(gmx.oracle).getTokensWithPricesCount(), 0, "GMX cleared oracle prices");

        GmxAccountProbe.Callback memory refund = probe.lastCallbackOfKind(GmxAccountProbe.CallbackKind.FeeRefund);
        assertEq(refund.key, key, "unused execution fee refunded through refundExecutionFee");
        assertGt(refund.value, 0, "refund carries ETH");
    }
}
