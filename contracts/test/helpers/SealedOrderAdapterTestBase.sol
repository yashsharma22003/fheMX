// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {CofheTest} from "@cofhe/foundry-plugin/CofheTest.sol";
import {CofheClient} from "@cofhe/foundry-plugin/CofheClient.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SealedOrderAdapter} from "../../src/adapter/SealedOrderAdapter.sol";
import {MockPriceVerifier} from "./MockPriceVerifier.sol";
import {BatchCofheClient} from "./BatchCofheClient.sol";

/// @notice Shared deployment and input helpers for adapter tests (unit and fork).
abstract contract SealedOrderAdapterTestBase is CofheTest {
    uint64 internal constant MIN_SIZE = 10e6; // $10
    uint64 internal constant MAX_SIZE = 1_000_000e6; // $1m
    uint32 internal constant MAX_SLIPPAGE = 500; // 5%
    uint32 internal constant MAX_FALLBACK_SLIPPAGE = 1_000; // 10%
    uint16 internal constant MAX_LEVERAGE = 10;
    uint16 internal constant FEE_BPS = 10;
    uint256 internal constant MIN_EXEC_FEE = 0.0005 ether;
    uint256 internal constant DECREASE_FEE_FLAT = 0.0001 ether;
    uint32 internal constant MAX_REPORT_AGE = 30;
    uint32 internal constant MIN_CHECK_INTERVAL = 10;
    uint32 internal constant CALLBACK_GAS_LIMIT = 500_000;

    uint256 internal constant ALICE_PKEY = 0xA11CE;
    uint256 internal constant BOB_PKEY = 0xB0B;

    SealedOrderAdapter internal adapter;
    address internal wntToken;
    MockPriceVerifier internal prices;
    BatchCofheClient internal alice;
    BatchCofheClient internal bob;

    struct Plain {
        bool isLong;
        uint64 size;
        uint64 trigger;
        uint32 slippage;
    }

    function _deployAdapter(
        address accountImplementation,
        address wnt,
        address market,
        address gmxReader,
        address gmxDataStore
    ) internal {
        _deployAdapterWithVerifier(accountImplementation, wnt, market, gmxReader, gmxDataStore, address(0), MAX_REPORT_AGE);
    }

    /// @param priceVerifier address(0) deploys the mock verifier
    function _deployAdapterWithVerifier(
        address accountImplementation,
        address wnt,
        address market,
        address gmxReader,
        address gmxDataStore,
        address priceVerifier,
        uint32 maxReportAge
    ) internal {
        _clearLiveCofheStorage();
        deployMocks();
        // The mock signers sign with cheatcodes; on a fork their addresses pre-exist, so allow them explicitly.
        vm.allowCheatcodes(address(0x6E12D8C87503D4287c294f2Fdef96ACd9DFf6bd2));
        vm.allowCheatcodes(address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        alice = new BatchCofheClient();
        alice.connect(ALICE_PKEY);
        bob = new BatchCofheClient();
        bob.connect(BOB_PKEY);
        prices = new MockPriceVerifier();
        if (priceVerifier == address(0)) priceVerifier = address(prices);
        wntToken = wnt;

        address[] memory markets = new address[](1);
        markets[0] = market;
        adapter = new SealedOrderAdapter(
            SealedOrderAdapter.Config({
                accountImplementation: accountImplementation,
                wnt: wnt,
                markets: markets,
                minSizeUsd6: MIN_SIZE,
                maxSizeUsd6: MAX_SIZE,
                maxSlippageBps: MAX_SLIPPAGE,
                maxFallbackSlippageBps: MAX_FALLBACK_SLIPPAGE,
                maxLeverage: MAX_LEVERAGE,
                increaseFeeBps: FEE_BPS,
                decreaseFeeFlat: DECREASE_FEE_FLAT,
                minExecutionFee: MIN_EXEC_FEE,
                priceVerifier: priceVerifier,
                maxReportAge: maxReportAge,
                minCheckInterval: MIN_CHECK_INTERVAL,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                gmxReader: gmxReader,
                gmxDataStore: gmxDataStore
            })
        );
    }

    /// @dev On a fork, the fixed CoFHE addresses hold the live contracts' storage (the TaskManager is a
    ///      proxy there). `deployMocks` replaces the code but not the storage, so stale values in the low
    ///      slots break mock setup (e.g. a garbage security-zone max). Mock state lives in slots 0-10.
    function _clearLiveCofheStorage() internal {
        address[5] memory fixedAddresses = [
            TASK_MANAGER_ADDRESS,
            address(0x0000000000000000000000000000000000005001), // ZK verifier
            address(0x0000000000000000000000000000000000005002), // threshold network
            address(0x6E12D8C87503D4287c294f2Fdef96ACd9DFf6bd2), // ZK verifier signer
            address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8) // decrypt result signer
        ];
        for (uint256 a; a < fixedAddresses.length; a++) {
            for (uint256 slot; slot < 16; slot++) {
                vm.store(fixedAddresses[a], bytes32(slot), bytes32(0));
            }
        }
    }

    /// Funds the user's account at its predicted address, before the account exists.
    function _fund(address user, uint256 amount) internal {
        vm.deal(adapter.accountOf(user), amount);
    }

    function _input(BatchCofheClient client, address market, uint256 collateral, uint256 executionFee, Plain memory p)
        internal
        returns (SealedOrderAdapter.SealedOrderInput memory input)
    {
        address target = address(adapter);
        input.market = market;
        input.kind = SealedOrderAdapter.OrderKind.LimitIncrease;
        input.collateralToken = wntToken;
        input.collateral = collateral;
        input.executionFee = executionFee;
        input.fallbackSlippageBps = 800;
        (input.isLong, input.sizeUsd6, input.triggerPrice8, input.slippageBps, input.inputProof) =
            client.encryptOrder(p.isLong, p.size, p.trigger, p.slippage, target);
    }

    /// Stop-loss or take-profit on the account's existing position (no collateral).
    function _decreaseInput(
        BatchCofheClient client,
        address market,
        SealedOrderAdapter.OrderKind kind,
        address positionCollateral,
        uint256 executionFee,
        Plain memory p
    ) internal returns (SealedOrderAdapter.SealedOrderInput memory input) {
        input = _input(client, market, 0, executionFee, p);
        input.kind = kind;
        input.collateralToken = positionCollateral;
    }

    function _submitAs(BatchCofheClient client, SealedOrderAdapter.SealedOrderInput memory input)
        internal
        returns (bytes32 orderId)
    {
        vm.prank(client.account());
        orderId = adapter.submitOrder(input);
    }

    function _check(address market, bytes32 orderId, uint256 price8) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = orderId;
        adapter.checkBatch(market, ids, prices.report(price8, block.timestamp));
    }

    struct Decrypted {
        uint64 size;
        bytes sizeSig;
        bool isLong;
        bytes isLongSig;
        uint32 slippage;
        bytes slippageSig;
    }

    /// Off-chain step anyone can do: decrypt the latest check's public results with signatures.
    function _decryptCheck(bytes32 orderId) internal view returns (Decrypted memory d) {
        SealedOrderAdapter.CheckState memory c = adapter.checkOf(orderId);
        uint256 v;
        (, v, d.sizeSig) = alice.decryptForTx_withoutACP(euint64.unwrap(c.revealedSize));
        d.size = uint64(v);
        (, v, d.isLongSig) = alice.decryptForTx_withoutACP(ebool.unwrap(c.revealedIsLong));
        d.isLong = v != 0;
        (, v, d.slippageSig) = alice.decryptForTx_withoutACP(euint32.unwrap(c.revealedSlippage));
        d.slippage = uint32(v);
    }

    function _execute(bytes32 orderId, Decrypted memory d) internal returns (bytes32 gmxKey) {
        gmxKey = adapter.execute(orderId, d.size, d.sizeSig, d.isLong, d.isLongSig, d.slippage, d.slippageSig);
    }
}
