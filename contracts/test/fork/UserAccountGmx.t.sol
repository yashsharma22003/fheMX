// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {UserAccountFactory} from "../../src/account/UserAccountFactory.sol";
import {IGmxExchangeRouter} from "../../src/interfaces/gmx/IGmxExchangeRouter.sol";
import {NetworkConfig} from "../helpers/NetworkConfig.sol";
import {GmxKeeperSimulator} from "../helpers/GmxKeeperSimulator.sol";
import {IGmxDataStore, GmxKeys} from "../helpers/GmxTestInterfaces.sol";

/// @notice Milestone 2: the user clone placing real GMX orders on an Arbitrum Sepolia fork.
///         The test contract plays the adapter.
contract UserAccountGmxForkTest is Test {
    uint256 private constant ETH_PRICE_USD = 2500;
    uint256 private constant COLLATERAL = 0.02 ether;
    uint256 private constant EXECUTION_FEE = 0.001 ether;
    uint256 private constant PROTOCOL_FEE_RESERVE = 0.0005 ether;
    uint256 private constant SIZE_USD = 100e30;
    bytes32 private constant ORDER = keccak256("sealed-order-1");

    NetworkConfig.Gmx private gmx;
    NetworkConfig.Market private ethUsd;
    UserAccount private account;
    address private owner = makeAddr("owner");
    address private feeCollector = makeAddr("feeCollector");

    function setUp() public {
        assertEq(block.chainid, 421614, "fork must be Arbitrum Sepolia");
        string memory json = NetworkConfig.arbitrumSepolia();
        gmx = NetworkConfig.gmx(json);
        ethUsd = NetworkConfig.market(json, "ETH_USD");

        UserAccount impl =
            new UserAccount(gmx.exchangeRouter, gmx.orderVault, gmx.dataStore, gmx.roleStore, gmx.wnt, feeCollector);
        UserAccountFactory factory = new UserAccountFactory(address(impl), address(this));
        account = UserAccount(payable(factory.createAccount(owner)));

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        (bool ok,) = address(account).call{value: 0.1 ether}("");
        assertTrue(ok);

        account.lock(ORDER, gmx.wnt, COLLATERAL, EXECUTION_FEE, 2, PROTOCOL_FEE_RESERVE);
    }

    function _submit() internal returns (bytes32 gmxKey) {
        gmxKey = account.submit(
            ORDER,
            IUserAccount.OrderRequest({
                market: ethUsd.marketToken,
                isLong: true,
                isIncrease: true,
                sizeDeltaUsd: SIZE_USD,
                collateralDelta: COLLATERAL,
                acceptablePrice: type(uint256).max,
                callbackGasLimit: 500_000
            })
        );
    }

    function _prices() internal view returns (GmxKeeperSimulator.TokenPrice[] memory prices) {
        prices = new GmxKeeperSimulator.TokenPrice[](2);
        uint256 eth = GmxKeeperSimulator.usdPrice(ETH_PRICE_USD, 18);
        uint256 usdc = GmxKeeperSimulator.usdPrice(1, 6);
        prices[0] = GmxKeeperSimulator.TokenPrice(ethUsd.longToken, eth, eth);
        prices[1] = GmxKeeperSimulator.TokenPrice(ethUsd.shortToken, usdc, usdc);
    }

    function _outcome() internal view returns (IUserAccount.GmxOutcome outcome) {
        (outcome,) = account.outcomeOf(ORDER);
    }

    function test_submit_createsGmxOrderOwnedByClone() public {
        _submit();
        assertEq(uint8(_outcome()), uint8(IUserAccount.GmxOutcome.Pending));
        assertEq(IGmxDataStore(gmx.dataStore).getBytes32Count(GmxKeys.accountOrderListKey(address(account))), 1);
    }

    function test_execution_opensPosition_recordsExecuted_thenFeeAndRelease() public {
        bytes32 gmxKey = _submit();
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _prices());

        assertEq(uint8(_outcome()), uint8(IUserAccount.GmxOutcome.Executed), "callback recorded");
        assertEq(account.positionSizeUsd(ethUsd.marketToken, gmx.wnt, true), SIZE_USD, "position read from GMX");

        uint256 fee = 0.0001 ether;
        account.payProtocolFee(ORDER, fee);
        assertEq(feeCollector.balance, fee);

        uint256 freeBefore = account.freeBalance(gmx.wnt);
        account.release(ORDER);
        assertEq(account.freeBalance(gmx.wnt), freeBefore + EXECUTION_FEE, "unused second fee freed");
        assertEq(address(account).balance, account.freeBalance(gmx.wnt), "nothing left locked");
    }

    function test_cancellation_returnsCollateralUnderLock_thenRearmSucceeds() public {
        bytes32 gmxKey = _submit();
        uint256 freeBefore = account.freeBalance(gmx.wnt);

        uint256 expiry = IGmxDataStore(gmx.dataStore).getUint(GmxKeys.REQUEST_EXPIRATION_TIME);
        vm.warp(block.timestamp + expiry + 1);
        vm.prank(address(account)); // stands in for the owner cancel path built in milestone 5
        IGmxExchangeRouter(gmx.exchangeRouter).cancelOrder(gmxKey);

        assertEq(uint8(_outcome()), uint8(IUserAccount.GmxOutcome.Cancelled));
        assertEq(account.lockOf(ORDER).collateral, COLLATERAL, "collateral back under the lock");
        assertGe(account.freeBalance(gmx.wnt), freeBefore, "free balance only grows (fee refund)");

        vm.expectRevert(abi.encodeWithSelector(IUserAccount.FeeNotPayable.selector, ORDER, IUserAccount.GmxOutcome.Cancelled));
        account.payProtocolFee(ORDER, 1);

        bytes32 secondKey = _submit();
        assertTrue(secondKey != gmxKey);
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, secondKey, _prices());
        assertEq(uint8(_outcome()), uint8(IUserAccount.GmxOutcome.Executed), "re-armed order filled");
        assertEq(account.positionSizeUsd(ethUsd.marketToken, gmx.wnt, true), SIZE_USD);
    }
}
