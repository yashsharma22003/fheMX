// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {NetworkConfig} from "../helpers/NetworkConfig.sol";
import {GmxKeeperSimulator} from "../helpers/GmxKeeperSimulator.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

/// @notice Milestone 4 demo: a sealed limit entry from intake to a filled GMX position, on an Arbitrum
///         Sepolia fork with the live GMX contracts, CoFHE mocks and the keeper simulator.
contract SealedLimitEntryDemoForkTest is SealedOrderAdapterTestBase {
    uint256 private constant COLLATERAL = 0.02 ether;
    uint256 private constant EXEC_FEE = 0.001 ether;
    uint64 private constant SIZE = 100e6; // $100
    uint64 private constant TRIGGER = 2_400e8; // buy ETH at or below $2,400

    NetworkConfig.Gmx private gmx;
    NetworkConfig.Market private ethUsd;
    address private feeCollector = makeAddr("feeCollector");

    function setUp() public {
        assertEq(block.chainid, 421614, "fork must be Arbitrum Sepolia");
        string memory json = NetworkConfig.arbitrumSepolia();
        gmx = NetworkConfig.gmx(json);
        ethUsd = NetworkConfig.market(json, "ETH_USD");

        GmxKeeperSimulator.ensureOpenInterestCapacity(gmx, ethUsd.marketToken);
        UserAccount impl =
            new UserAccount(_gmxContracts(), feeCollector);
        _deployAdapter(address(impl), gmx.wnt, ethUsd.marketToken);
        _fund(alice.account(), 0.1 ether);
    }

    function _sealedLong(uint32 slippageBps) internal returns (bytes32 orderId) {
        orderId = _submitAs(
            alice,
            _input(
                alice,
                ethUsd.marketToken,
                COLLATERAL,
                EXEC_FEE,
                Plain({isLong: true, size: SIZE, trigger: TRIGGER, slippage: slippageBps})
            )
        );
    }

    function _gmxPrices(uint256 ethUsdWhole) internal view returns (GmxKeeperSimulator.TokenPrice[] memory p) {
        p = new GmxKeeperSimulator.TokenPrice[](2);
        uint256 eth = GmxKeeperSimulator.usdPrice(ethUsdWhole, 18);
        uint256 usdc = GmxKeeperSimulator.usdPrice(1, 6);
        p[0] = GmxKeeperSimulator.TokenPrice(ethUsd.longToken, eth, eth);
        p[1] = GmxKeeperSimulator.TokenPrice(ethUsd.shortToken, usdc, usdc);
    }

    function _outcome(bytes32 orderId) internal view returns (IUserAccount.GmxOutcome outcome) {
        (outcome,) = IUserAccount(adapter.accountOf(alice.account())).outcomeOf(orderId);
    }

    function test_demo_sealedLimitEntry_firesFillsAndPaysFee() public {
        // 1. Sealed intake: side, size, trigger and slippage are ciphertext on-chain.
        bytes32 orderId = _sealedLong(100);
        SealedOrderAdapter.SealedOrder memory o = adapter.orderOf(orderId);
        assertFalse(mockAcl.globalAllowed(uint256(euint64.unwrap(o.triggerPrice8))), "trigger sealed");

        // 2. Price above the trigger: the check reveals only "not yet".
        _check(ethUsd.marketToken, orderId, 2_500e8);
        assertEq(_decryptCheck(orderId).size, 0);

        // 3. Price drops through the trigger: the next check fires.
        vm.warp(block.timestamp + MIN_CHECK_INTERVAL);
        _check(ethUsd.marketToken, orderId, 2_390e8);
        Decrypted memory d = _decryptCheck(orderId);
        assertEq(d.size, SIZE);
        assertTrue(d.isLong);

        // 4. Anyone executes: decryptions are published and a real GMX market increase is created.
        bytes32 gmxKey = _execute(orderId, d);
        assertEq(uint8(adapter.orderOf(orderId).status), uint8(SealedOrderAdapter.Status.Fired));

        // 5. A GMX keeper fills it within the 1% slippage the user sealed.
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _gmxPrices(2_395));
        assertEq(uint8(_outcome(orderId)), uint8(IUserAccount.GmxOutcome.Executed));
        address account = adapter.accountOf(alice.account());
        assertEq(IUserAccount(account).positionSizeUsd(ethUsd.marketToken, gmx.wnt, true), uint256(SIZE) * 1e24);

        // 6. Settlement: 10 bps of $100 at the check price goes to the collector; the rest is freed.
        adapter.settle(orderId);
        uint256 expectedFee = uint256(SIZE) * FEE_BPS / 10_000 * 1e20 / 2_390e8;
        assertEq(feeCollector.balance, expectedFee);
        assertEq(uint8(adapter.orderOf(orderId).status), uint8(SealedOrderAdapter.Status.Filled));
        assertEq(address(account).balance, IUserAccount(account).freeBalance(gmx.wnt), "nothing left locked");
    }

    function test_demo_gmxRejectsOnSlippage_noFee_ownerRecoversFunds() public {
        bytes32 orderId = _sealedLong(0); // zero slippage tolerance
        _check(ethUsd.marketToken, orderId, 2_390e8);
        bytes32 gmxKey = _execute(orderId, _decryptCheck(orderId));

        // GMX's execution price is above the acceptable price, so GMX cancels the order.
        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _gmxPrices(2_450));
        assertEq(uint8(_outcome(orderId)), uint8(IUserAccount.GmxOutcome.Cancelled));

        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.NotFilled.selector, orderId));
        adapter.settle(orderId);

        address account = adapter.accountOf(alice.account());
        vm.prank(alice.account());
        adapter.cancelOrder(orderId);
        assertEq(feeCollector.balance, 0, "no fee on a failed fill");
        assertEq(address(account).balance, IUserAccount(account).freeBalance(gmx.wnt), "all funds withdrawable");
        assertGe(address(account).balance, 0.1 ether - EXEC_FEE, "at most the first execution fee was spent");
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
