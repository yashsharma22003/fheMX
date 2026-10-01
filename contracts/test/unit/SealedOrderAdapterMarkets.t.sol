// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {IUserAccount} from "../../src/account/IUserAccount.sol";
import {UserAccount} from "../../src/account/UserAccount.sol";
import {IGmxReader, GmxPricing} from "../../src/interfaces/gmx/IGmxReader.sol";
import {GmxRole} from "../../src/interfaces/gmx/IGmxRoleStore.sol";
import {
    MockGmxRoleStore, MockGmxExchangeRouter, MockGmxDataStore, MockGmxReader, MockERC20
} from "../helpers/GmxMocks.sol";
import {SealedOrderAdapterTestBase} from "../helpers/SealedOrderAdapterTestBase.sol";

/// @notice Known issue 10: several markets, collateral in any pool token, prices per token.
contract SealedOrderAdapterMarketsTest is SealedOrderAdapterTestBase {
    address private constant WNT = address(0x4E7);
    address private constant ETH_MARKET = address(0xE7E);
    address private constant BTC_MARKET = address(0xB7C);
    uint256 private constant EXEC_FEE = 0.001 ether;

    MockERC20 private usdc;
    MockERC20 private btc;
    MockGmxExchangeRouter private router;
    MockGmxDataStore private dataStore;
    MockGmxReader private reader;
    address private feeCollector = makeAddr("feeCollector");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockERC20("USDC", 6);
        btc = new MockERC20("BTC", 8);
        router = new MockGmxExchangeRouter();
        dataStore = new MockGmxDataStore();
        reader = new MockGmxReader();
        MockGmxRoleStore roleStore = new MockGmxRoleStore();
        UserAccount impl = new UserAccount(
            UserAccount.GmxContracts({
                exchangeRouter: address(router),
                router: address(router),
                orderVault: address(0x0FA),
                dataStore: address(dataStore),
                roleStore: address(roleStore),
                wnt: WNT
            }),
            feeCollector
        );
        SealedOrderAdapter.MarketConfig[] memory markets = new SealedOrderAdapter.MarketConfig[](2);
        markets[0] = SealedOrderAdapter.MarketConfig(ETH_MARKET, WNT, WNT, address(usdc));
        markets[1] = SealedOrderAdapter.MarketConfig(BTC_MARKET, address(btc), address(btc), address(usdc));
        _deployAdapterFor(address(impl), WNT, markets, address(reader), address(dataStore), address(0), MAX_REPORT_AGE);
        prices.setPrice(address(btc), 80_000e8);

        address account = adapter.accountOf(alice.account());
        vm.deal(account, 1 ether); // execution fees
        usdc.mint(account, 10_000e6);
        btc.mint(account, 1e8);
    }

    function _order(address market, address collateralToken, uint256 collateral, uint64 size, uint64 trigger)
        internal
        returns (bytes32)
    {
        SealedOrderAdapter.SealedOrderInput memory input =
            _input(alice, market, collateral, EXEC_FEE, Plain({isLong: true, size: size, trigger: trigger, slippage: 50}));
        input.collateralToken = collateralToken;
        return _submitAs(alice, input);
    }

    function _account() internal view returns (IUserAccount) {
        return IUserAccount(adapter.accountOf(alice.account()));
    }

    // ─── intake ───────────────────────────────────────────────────────────────

    function test_intake_usdcCollateralOnBtcMarket_locksUsdcAndReserveInUsdc() public {
        bytes32 id = _order(BTC_MARKET, address(usdc), 1_000e6, 5_000e6, 80_000e8);
        IUserAccount.Lock memory l = _account().lockOf(id);
        assertEq(l.token, address(usdc));
        assertEq(l.collateral, 1_000e6);
        assertEq(l.protocolFeeReserve, uint256(1_000e6) * MAX_LEVERAGE * FEE_BPS / 10_000, "reserve in USDC units");
        assertEq(_account().freeBalance(WNT), 1 ether - 2 * EXEC_FEE, "execution fees in ETH");
    }

    function test_intake_rejectsCollateralOutsideTheMarketPool() public {
        SealedOrderAdapter.SealedOrderInput memory input =
            _input(alice, BTC_MARKET, 0.1 ether, EXEC_FEE, Plain(true, 100e6, 80_000e8, 50));
        input.collateralToken = WNT; // WETH isn't in the BTC/USD pool
        vm.prank(alice.account());
        vm.expectRevert(abi.encodeWithSelector(SealedOrderAdapter.UnsupportedCollateral.selector, WNT));
        adapter.submitOrder(input);
    }

    // ─── leverage with the collateral's own price ─────────────────────────────

    function test_leverage_pricesUsdcCollateralWithUsdcFeed() public {
        bytes32 fits = _order(BTC_MARKET, address(usdc), 1_000e6, 10_000e6, 80_000e8); // $1,000 x 10 = $10,000
        bytes32 tooBig = _order(BTC_MARKET, address(usdc), 1_000e6, 10_001e6, 80_000e8);
        bytes32[] memory ids = new bytes32[](2);
        (ids[0], ids[1]) = (fits, tooBig);
        adapter.checkBatch(BTC_MARKET, ids, prices.report(80_000e8, block.timestamp));
        assertEq(_decryptCheck(fits).size, 10_000e6);
        assertEq(_decryptCheck(tooBig).size, 0);
    }

    function test_leverage_followsACollateralDepeg() public {
        prices.setPrice(address(usdc), 0.5e8); // USDC at $0.50: $1,000 of it now backs only $5,000
        bytes32 id = _order(BTC_MARKET, address(usdc), 1_000e6, 9_000e6, 80_000e8);
        _check(BTC_MARKET, id, 80_000e8);
        assertEq(_decryptCheck(id).size, 0);
    }

    function test_leverage_btcCollateralUsesTheIndexReport() public {
        bytes32 id = _order(BTC_MARKET, address(btc), 0.1e8, 80_000e6, 80_000e8); // 0.1 BTC x $80k x 10
        _check(BTC_MARKET, id, 80_000e8);
        assertEq(_decryptCheck(id).size, 80_000e6);
    }

    // ─── fee in the collateral token ──────────────────────────────────────────

    function test_fee_inUsdc() public {
        bytes32 id = _order(BTC_MARKET, address(usdc), 1_000e6, 9_000e6, 80_000e8);
        _check(BTC_MARKET, id, 80_000e8);
        _execute(id, _decryptCheck(id));
        assertEq(adapter.fillOf(id).protocolFee, 9e6, "10 bps of $9,000 = 9 USDC");
    }

    function test_fee_inBtc() public {
        bytes32 id = _order(BTC_MARKET, address(btc), 0.1e8, 80_000e6, 80_000e8);
        _check(BTC_MARKET, id, 80_000e8);
        _execute(id, _decryptCheck(id));
        assertEq(adapter.fillOf(id).protocolFee, 0.001e8, "10 bps of $80,000 = $80 = 0.001 BTC");
    }

    // ─── GMX estimate gets real pool prices ───────────────────────────────────

    function test_executionEstimate_getsIndexLongAndShortPricesInGmxUnits() public {
        prices.setPrice(address(usdc), 0.999e8);
        bytes32 id = _order(BTC_MARKET, address(usdc), 1_000e6, 5_000e6, 80_000e8);
        _check(BTC_MARKET, id, 80_000e8);
        SealedOrderAdapter.CheckState memory c = adapter.checkOf(id);
        assertEq(c.collateralPrice8, 0.999e8);

        uint256 btcGmx = 80_000e8 * 1e14; // 8-decimal token: price8 * 10^(22 - 8)
        uint256 usdcGmx = 0.999e8 * 1e16; // 6-decimal token: price8 * 10^(22 - 6)
        GmxPricing.MarketPrices memory expected = GmxPricing.MarketPrices(
            GmxPricing.Price(btcGmx, btcGmx), GmxPricing.Price(btcGmx, btcGmx), GmxPricing.Price(usdcGmx, usdcGmx)
        );
        vm.expectCall(
            address(reader),
            abi.encodePacked(IGmxReader.getExecutionPrice.selector, abi.encode(address(dataStore), BTC_MARKET, expected))
        );
        _execute(id, _decryptCheck(id));
        assertEq(adapter.fillOf(id).acceptablePrice, btcGmx * 10_050 / 10_000, "long: 0.5% above the estimate");
    }

    // ─── markets ──────────────────────────────────────────────────────────────

    function test_check_rejectsOrderFromAnotherMarket() public {
        bytes32 id = _order(ETH_MARKET, WNT, 0.1 ether, 100e6, 2_400e8);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        bytes memory report = prices.report(80_000e8, block.timestamp);
        vm.expectEmit(address(adapter));
        emit SealedOrderAdapter.CheckSkipped(id, SealedOrderAdapter.SkipReason.WrongMarket);
        adapter.checkBatch(BTC_MARKET, ids, report);
        assertEq(adapter.checkOf(id).lastCheckAt, 0);
    }

    function test_marketInfo_recordsTokenDecimals() public view {
        SealedOrderAdapter.MarketInfo memory m = adapter.marketOf(BTC_MARKET);
        assertEq(m.indexDecimals, 8);
        assertEq(m.shortDecimals, 6);
        assertEq(adapter.marketOf(ETH_MARKET).indexDecimals, 18);
    }
}
