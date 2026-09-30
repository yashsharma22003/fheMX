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

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

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

        GmxKeeperSimulator.ensureOpenInterestCapacity(gmx, ethUsd.marketToken);
        UserAccount impl =
            new UserAccount(_gmxContracts(), feeCollector);
        UserAccountFactory factory = new UserAccountFactory(address(impl), address(this));
        account = UserAccount(payable(factory.createAccount(owner)));

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        (bool ok,) = address(account).call{value: 0.1 ether}("");
        assertTrue(ok);

        account.lock(ORDER, gmx.wnt, COLLATERAL, EXECUTION_FEE, 2, PROTOCOL_FEE_RESERVE);
    }

    function _submit() internal returns (bytes32 gmxKey) {
        gmxKey = _submitWith(500_000);
    }

    function _submitWith(uint256 callbackGasLimit) internal returns (bytes32 gmxKey) {
        gmxKey = account.submit(
            ORDER,
            IUserAccount.OrderRequest({
                market: ethUsd.marketToken,
                collateralToken: gmx.wnt,
                isLong: true,
                isIncrease: true,
                sizeDeltaUsd: SIZE_USD,
                collateralDelta: COLLATERAL,
                acceptablePrice: type(uint256).max,
                callbackGasLimit: callbackGasLimit
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

    // ─── milestone 5 ──────────────────────────────────────────────────────────

    /// A 1-gas callback budget makes GMX's callback fail (GMX catches it), so the account never hears back.
    function test_lostExecutionCallback_reconcileRecordsExecuted_andFeeStillCollectable() public {
        bytes32 gmxKey = _submitWith(1);
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _prices());
        assertEq(uint8(_outcome()), uint8(IUserAccount.GmxOutcome.Pending), "callback lost");
        assertEq(account.positionSizeUsd(ethUsd.marketToken, gmx.wnt, true), SIZE_USD, "but GMX filled it");

        assertEq(uint8(account.reconcile(ORDER)), uint8(IUserAccount.GmxOutcome.Executed));
        account.payProtocolFee(ORDER, 0.0001 ether);
        account.release(ORDER);
        assertEq(feeCollector.balance, 0.0001 ether);
    }

    function test_lostCancellationCallback_reconcileRecordsCancelled_collateralBackUnderLock() public {
        _submitWith(1);
        uint256 expiry = IGmxDataStore(gmx.dataStore).getUint(GmxKeys.REQUEST_EXPIRATION_TIME);
        vm.warp(block.timestamp + expiry + 1);
        vm.prank(owner);
        account.cancelGmxOrder(ORDER);
        assertEq(uint8(_outcome()), uint8(IUserAccount.GmxOutcome.Pending), "callback lost");

        assertEq(uint8(account.reconcile(ORDER)), uint8(IUserAccount.GmxOutcome.Cancelled));
        assertEq(account.lockOf(ORDER).collateral, COLLATERAL);
    }

    function test_reconcile_rejectedWhileOrderStillAtGmx() public {
        bytes32 gmxKey = _submitWith(1);
        vm.expectRevert(abi.encodeWithSelector(IUserAccount.OrderStillAtGmx.selector, gmxKey));
        account.reconcile(ORDER);
    }

    function test_ownerCancel_pendingGmxOrder() public {
        _submit();
        uint256 expiry = IGmxDataStore(gmx.dataStore).getUint(GmxKeys.REQUEST_EXPIRATION_TIME);
        vm.warp(block.timestamp + expiry + 1);
        vm.prank(owner);
        account.cancelGmxOrder(ORDER);
        assertEq(uint8(_outcome()), uint8(IUserAccount.GmxOutcome.Cancelled));
    }

    function test_manualClose_closesRealPosition_proceedsToFreeBalance() public {
        bytes32 gmxKey = _submit();
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _prices());
        account.payProtocolFee(ORDER, 0);
        account.release(ORDER);
        uint256 freeBefore = account.freeBalance(gmx.wnt);

        vm.prank(owner);
        bytes32 closeKey = account.closePosition(
            UserAccount.ClosePositionRequest({
                market: ethUsd.marketToken,
                collateralToken: gmx.wnt,
                isLong: true,
                sizeDeltaUsd: SIZE_USD,
                collateralDeltaAmount: 0,
                acceptablePrice: 0, // long decrease: accept any price
                executionFee: EXECUTION_FEE,
                callbackGasLimit: 500_000
            })
        );
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, closeKey, _prices());

        assertEq(account.positionSizeUsd(ethUsd.marketToken, gmx.wnt, true), 0, "position closed");
        assertEq(account.manualCloseKey(), bytes32(0), "callback cleared the manual close");
        assertGt(account.freeBalance(gmx.wnt), freeBefore, "collateral came back as free ETH");
    }

    function test_usdcCollateral_opensPositionWithUsdc() public {
        address usdc = ethUsd.shortToken;
        deal(usdc, address(account), 100e6);
        bytes32 order2 = keccak256("usdc-order");
        account.lock(order2, usdc, 50e6, EXECUTION_FEE, 2, 1e6);
        bytes32 gmxKey = account.submit(
            order2,
            IUserAccount.OrderRequest({
                market: ethUsd.marketToken,
                collateralToken: usdc,
                isLong: true,
                isIncrease: true,
                sizeDeltaUsd: SIZE_USD,
                collateralDelta: 50e6,
                acceptablePrice: type(uint256).max,
                callbackGasLimit: 500_000
            })
        );
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _prices());

        (IUserAccount.GmxOutcome outcome,) = account.outcomeOf(order2);
        assertEq(uint8(outcome), uint8(IUserAccount.GmxOutcome.Executed));
        assertEq(account.positionSizeUsd(ethUsd.marketToken, usdc, true), SIZE_USD);
        account.payProtocolFee(order2, 0.5e6);
        assertEq(IERC20Balance(usdc).balanceOf(feeCollector), 0.5e6);
    }

    function _gmxContracts() internal view returns (UserAccount.GmxContracts memory) {
        return UserAccount.GmxContracts({
            exchangeRouter: gmx.exchangeRouter,
            router: gmx.router,
            orderVault: gmx.orderVault,
            dataStore: gmx.dataStore,
            roleStore: gmx.roleStore,
            wnt: gmx.wnt
        });
    }
}
