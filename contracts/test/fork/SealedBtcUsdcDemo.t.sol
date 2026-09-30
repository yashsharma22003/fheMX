// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {ChainlinkFeedPriceVerifier} from "../../src/oracle/ChainlinkFeedPriceVerifier.sol";
import {NetworkConfig} from "../helpers/NetworkConfig.sol";
import {GmxKeeperSimulator} from "../helpers/GmxKeeperSimulator.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Known issue 10: a sealed limit entry on the BTC/USD market with USDC.SG collateral, priced by the real
///         Chainlink BTC/USD and USDC/USD feeds, filled on live GMX (Arbitrum Sepolia fork).
contract SealedBtcUsdcDemoForkTest is SealedOrderAdapterTestBase {
    uint256 private constant EXEC_FEE = 0.001 ether;
    uint256 private constant COLLATERAL = 50e6; // 50 USDC
    uint64 private constant SIZE = 100e6; // $100

    NetworkConfig.Gmx private gmx;
    NetworkConfig.Market private btcUsd;
    ChainlinkFeedPriceVerifier private verifier;
    address private feeCollector = makeAddr("feeCollector");

    function setUp() public {
        assertEq(block.chainid, 421614, "fork must be Arbitrum Sepolia");
        string memory json = NetworkConfig.arbitrumSepolia();
        gmx = NetworkConfig.gmx(json);
        btcUsd = NetworkConfig.market(json, "BTC_USD");
        GmxKeeperSimulator.ensureOpenInterestCapacity(gmx, btcUsd.marketToken);

        address[] memory tokens = new address[](2);
        address[] memory feeds = new address[](2);
        uint32[] memory maxAges = new uint32[](2);
        (tokens[0], feeds[0], maxAges[0]) = (btcUsd.indexToken, NetworkConfig.chainlinkFeed(json, "BTC_USD"), 300);
        (tokens[1], feeds[1], maxAges[1]) = (btcUsd.shortToken, NetworkConfig.chainlinkFeed(json, "USDC_USD"), 90_000);
        verifier = new ChainlinkFeedPriceVerifier(tokens, feeds, maxAges, address(0), 0);

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
        _deployAdapterFor(
            address(impl),
            gmx.wnt,
            _market(btcUsd.marketToken, btcUsd.indexToken, btcUsd.longToken, btcUsd.shortToken),
            gmx.reader,
            gmx.dataStore,
            address(verifier),
            300
        );
        address account = adapter.accountOf(alice.account());
        vm.deal(account, 0.01 ether); // execution fees
        deal(btcUsd.shortToken, account, 100e6); // 100 USDC.SG
    }

    function test_demo_btcLongWithUsdcCollateral_firesFillsFeeInUsdc() public {
        (uint256 btc8,) = verifier.price(btcUsd.indexToken, "");
        (uint256 usdc8,) = verifier.price(btcUsd.shortToken, "");
        assertApproxEqRel(usdc8, 1e8, 0.02e18, "live USDC feed ~ $1");

        // Long limit entry with its trigger just above the live BTC price, so the first check fires.
        SealedOrderAdapter.SealedOrderInput memory input = _input(
            alice,
            btcUsd.marketToken,
            COLLATERAL,
            EXEC_FEE,
            Plain({isLong: true, size: SIZE, trigger: uint64(btc8 * 101 / 100), slippage: 100})
        );
        input.collateralToken = btcUsd.shortToken;
        bytes32 orderId = _submitAs(alice, input);
        address account = adapter.accountOf(alice.account());
        assertEq(IUserAccount(account).lockOf(orderId).token, btcUsd.shortToken, "collateral locked in USDC");

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = orderId;
        adapter.checkBatch(btcUsd.marketToken, ids, "");
        assertEq(adapter.checkOf(orderId).collateralPrice8, usdc8, "leverage priced with the USDC feed");
        bytes32 gmxKey = _execute(orderId, _decryptCheck(orderId));

        vm.warp(block.timestamp + 1);
        GmxKeeperSimulator.executeOrder(gmx, gmxKey, _gmxPrices(btc8));
        assertEq(IUserAccount(account).positionSizeUsd(btcUsd.marketToken, btcUsd.shortToken, true), uint256(SIZE) * 1e24);

        adapter.settle(orderId);
        uint256 fee = adapter.fillOf(orderId).protocolFee;
        assertApproxEqRel(fee, 0.1e6, 0.03e18, "10 bps of $100 ~ 0.1 USDC");
        assertEq(IERC20Min(btcUsd.shortToken).balanceOf(feeCollector), fee, "fee paid in USDC");
        assertEq(uint8(adapter.orderOf(orderId).status), uint8(SealedOrderAdapter.Status.Filled));
    }

    function _gmxPrices(uint256 btc8) internal view returns (GmxKeeperSimulator.TokenPrice[] memory p) {
        p = new GmxKeeperSimulator.TokenPrice[](2);
        uint256 btc = btc8 * 1e14; // 8-decimal token
        uint256 usdc = GmxKeeperSimulator.usdPrice(1, 6);
        p[0] = GmxKeeperSimulator.TokenPrice(btcUsd.longToken, btc, btc);
        p[1] = GmxKeeperSimulator.TokenPrice(btcUsd.shortToken, usdc, usdc);
    }
}
