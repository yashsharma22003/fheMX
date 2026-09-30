// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {NetworkConfig} from "../helpers/NetworkConfig.sol";
import {GmxKeeperSimulator} from "../helpers/GmxKeeperSimulator.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

/// @notice Milestone 7 demo on an Arbitrum Sepolia fork with live GMX: a sealed stop-loss closes a real
///         position, and a stop GMX rejects on slippage is re-armed and fills.
contract SealedStopLossDemoForkTest is SealedOrderAdapterTestBase {
    uint256 private constant COLLATERAL = 0.02 ether;
    uint256 private constant EXEC_FEE = 0.001 ether;
    uint64 private constant SIZE = 100e6; // $100

    NetworkConfig.Gmx private gmx;
    NetworkConfig.Market private ethUsd;
    address private feeCollector = makeAddr("feeCollector");
    address private account;

    function setUp() public {
        assertEq(block.chainid, 421614, "fork must be Arbitrum Sepolia");
        string memory json = NetworkConfig.arbitrumSepolia();
        gmx = NetworkConfig.gmx(json);
        ethUsd = NetworkConfig.market(json, "ETH_USD");

        GmxKeeperSimulator.ensureOpenInterestCapacity(gmx, ethUsd.marketToken);
        GmxKeeperSimulator.disablePositionImpact(gmx, ethUsd.marketToken);
        UserAccount impl = new UserAccount(
            UserAccount.GmxContracts({
                exchangeRouter: gmx.exchangeRouter,
                router: gmx.router,
                orderVault: gmx.orderVault,
                dataStore: gmx.dataStore,
                roleStore: gmx.roleStore,
                wnt: gmx.wnt
            }),
            feeCollector
        );
        _deployAdapter(address(impl), gmx.wnt, ethUsd.marketToken);
        _fund(alice.account(), 0.1 ether);
        account = adapter.accountOf(alice.account());
        _openLongViaSealedEntry();
    }

    function _gmxPrices(uint256 ethUsdWhole) internal view returns (GmxKeeperSimulator.TokenPrice[] memory p) {
        p = new GmxKeeperSimulator.TokenPrice[](2);
        uint256 eth = GmxKeeperSimulator.usdPrice(ethUsdWhole, 18);
        uint256 usdc = GmxKeeperSimulator.usdPrice(1, 6);
        p[0] = GmxKeeperSimulator.TokenPrice(ethUsd.longToken, eth, eth);
        p[1] = GmxKeeperSimulator.TokenPrice(ethUsd.shortToken, usdc, usdc);
    }

    function _positionSize() internal view returns (uint256) {
        return IUserAccount(account).positionSizeUsd(ethUsd.marketToken, gmx.wnt, true);
    }

    function _outcome(bytes32 orderId) internal view returns (IUserAccount.GmxOutcome o) {
        (o,) = IUserAccount(account).outcomeOf(orderId);
    }

    /// A sealed $100 long limit entry that fires at $2,390 and fills: the position the stop-loss protects.
    function _openLongViaSealedEntry() internal {
        bytes32 entry = _submitAs(
            alice, _input(alice, ethUsd.marketToken, COLLATERAL, EXEC_FEE, Plain(true, SIZE, 2_400e8, 100))
        );
        _check(ethUsd.marketToken, entry, 2_390e8);
        bytes32 gmxKey = _execute(entry, _decryptCheck(entry));
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _gmxPrices(2_390));
        adapter.settle(entry);
        assertEq(_positionSize(), uint256(SIZE) * 1e24, "position open");
    }

    function _sealedStopLoss(uint32 slippageBps) internal returns (bytes32) {
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        return _submitAs(
            alice,
            _decreaseInput(
                alice,
                ethUsd.marketToken,
                SealedOrderAdapter.OrderKind.StopLoss,
                gmx.wnt,
                EXEC_FEE,
                Plain({isLong: true, size: SIZE, trigger: 2_300e8, slippage: slippageBps})
            )
        );
    }

    function test_demo_sealedStopLoss_closesRealPosition() public {
        bytes32 stop = _sealedStopLoss(100);

        _check(ethUsd.marketToken, stop, 2_350e8);
        assertEq(_decryptCheck(stop).size, 0, "above the stop: not yet");

        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        _check(ethUsd.marketToken, stop, 2_290e8);
        bytes32 gmxKey = _execute(stop, _decryptCheck(stop));

        uint256 freeBefore = IUserAccount(account).freeBalance(gmx.wnt);
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _gmxPrices(2_290));

        assertEq(uint8(_outcome(stop)), uint8(IUserAccount.GmxOutcome.Executed));
        assertEq(_positionSize(), 0, "position closed");
        assertGt(IUserAccount(account).freeBalance(gmx.wnt), freeBefore, "collateral back as free ETH");

        adapter.settle(stop);
        assertEq(uint8(adapter.orderOf(stop).status), uint8(SealedOrderAdapter.Status.Filled));
        assertEq(address(account).balance, IUserAccount(account).freeBalance(gmx.wnt), "nothing left locked");
    }

    function test_demo_stopRejectedOnSlippage_rearmFills() public {
        bytes32 stop = _sealedStopLoss(0); // zero tolerance; fallback 8% (test base)
        _check(ethUsd.marketToken, stop, 2_290e8);
        bytes32 firstKey = _execute(stop, _decryptCheck(stop));

        // Price gaps down to $2,250 before the keeper runs: below the $2,290 minimum, so GMX cancels.
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, firstKey, _gmxPrices(2_250));
        assertEq(uint8(_outcome(stop)), uint8(IUserAccount.GmxOutcome.Cancelled));
        assertEq(_positionSize(), uint256(SIZE) * 1e24, "still open after the rejected stop");

        // Anyone re-arms: same fire price, 8% fallback, so a $2,250 fill is acceptable.
        bytes32 secondKey = adapter.rearm(stop);
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, secondKey, _gmxPrices(2_250));

        assertEq(uint8(_outcome(stop)), uint8(IUserAccount.GmxOutcome.Executed));
        assertEq(_positionSize(), 0, "closed on the re-arm");
        adapter.settle(stop);
        assertEq(uint8(adapter.orderOf(stop).status), uint8(SealedOrderAdapter.Status.Filled));
    }
}
