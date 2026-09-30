// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {SealedOrderAdapter} from "../src/adapter/SealedOrderAdapter.sol";
import {UserAccount} from "../src/account/UserAccount.sol";
import {ChainlinkFeedPriceVerifier} from "../src/oracle/ChainlinkFeedPriceVerifier.sol";

/// @notice Deploys the account implementation, the Chainlink feed verifier and the adapter to Arbitrum Sepolia,
///         from config/networks/arbitrum-sepolia.json, and records the addresses in deployments/.
/// @dev Dry run (fork, no transactions):  forge script script/Deploy.s.sol --fork-url $ARBITRUM_SEPOLIA_RPC_URL
///      Live:  BROADCAST=true forge script script/Deploy.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast
///      Env: PRIVATE_KEY (required for a live run), FEE_COLLECTOR (defaults to the deployer).
///      The deployment's L2 block is in Foundry's broadcast receipts (on Arbitrum `block.number` is the L1 block).
contract Deploy is Script {
    struct Deployed {
        address accountImplementation;
        address priceVerifier;
        address adapter;
        address factory;
    }

    function run() external returns (Deployed memory d) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../config/networks/arbitrum-sepolia.json"));
        require(block.chainid == vm.parseJsonUint(json, ".chainId"), "wrong chain");

        // Anvil's first key stands in for dry runs; a live broadcast must set PRIVATE_KEY.
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(key);
        address feeCollector = vm.envOr("FEE_COLLECTOR", deployer);

        address market = vm.parseJsonAddress(json, ".markets.ETH_USD.marketToken");
        address[] memory markets = new address[](1);
        address[] memory feeds = new address[](1);
        markets[0] = market;
        feeds[0] = vm.parseJsonAddress(json, ".chainlinkFeeds.ETH_USD");

        vm.startBroadcast(key);
        d.accountImplementation = address(new UserAccount(_gmx(json), feeCollector));
        d.priceVerifier = address(new ChainlinkFeedPriceVerifier(markets, feeds, address(0), 0));
        SealedOrderAdapter adapter = new SealedOrderAdapter(_config(json, d, markets));
        vm.stopBroadcast();

        d.adapter = address(adapter);
        d.factory = address(adapter.factory());
        _record(d, deployer, feeCollector);
    }

    function _gmx(string memory json) private pure returns (UserAccount.GmxContracts memory) {
        return UserAccount.GmxContracts({
            exchangeRouter: vm.parseJsonAddress(json, ".gmx.exchangeRouter"),
            router: vm.parseJsonAddress(json, ".gmx.router"),
            orderVault: vm.parseJsonAddress(json, ".gmx.orderVault"),
            dataStore: vm.parseJsonAddress(json, ".gmx.dataStore"),
            roleStore: vm.parseJsonAddress(json, ".gmx.roleStore"),
            wnt: vm.parseJsonAddress(json, ".gmx.wnt")
        });
    }

    function _config(string memory json, Deployed memory d, address[] memory markets)
        private
        pure
        returns (SealedOrderAdapter.Config memory)
    {
        return SealedOrderAdapter.Config({
            accountImplementation: d.accountImplementation,
            wnt: vm.parseJsonAddress(json, ".gmx.wnt"),
            markets: markets,
            minSizeUsd6: uint64(vm.parseJsonUint(json, ".adapter.minSizeUsd6")),
            maxSizeUsd6: uint64(vm.parseJsonUint(json, ".adapter.maxSizeUsd6")),
            maxSlippageBps: uint32(vm.parseJsonUint(json, ".adapter.maxSlippageBps")),
            maxFallbackSlippageBps: uint32(vm.parseJsonUint(json, ".adapter.maxFallbackSlippageBps")),
            maxLeverage: uint16(vm.parseJsonUint(json, ".adapter.maxLeverage")),
            increaseFeeBps: uint16(vm.parseJsonUint(json, ".adapter.increaseFeeBps")),
            decreaseFeeFlat: vm.parseJsonUint(json, ".adapter.decreaseFeeFlatWei"),
            minExecutionFee: vm.parseJsonUint(json, ".adapter.minExecutionFeeWei"),
            priceVerifier: d.priceVerifier,
            maxReportAge: uint32(vm.parseJsonUint(json, ".adapter.maxReportAgeSeconds")),
            minCheckInterval: uint32(vm.parseJsonUint(json, ".adapter.minCheckIntervalSeconds")),
            callbackGasLimit: uint32(vm.parseJsonUint(json, ".adapter.callbackGasLimit")),
            gmxReader: vm.parseJsonAddress(json, ".gmx.reader"),
            gmxDataStore: vm.parseJsonAddress(json, ".gmx.dataStore")
        });
    }

    function _record(Deployed memory d, address deployer, address feeCollector) private {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "feeCollector", feeCollector);
        vm.serializeAddress(k, "accountImplementation", d.accountImplementation);
        vm.serializeAddress(k, "priceVerifier", d.priceVerifier);
        vm.serializeAddress(k, "factory", d.factory);
        string memory out = vm.serializeAddress(k, "adapter", d.adapter);

        bool live = vm.envOr("BROADCAST", false);
        string memory file = live ? "arbitrum-sepolia.json" : "arbitrum-sepolia.dry-run.json";
        vm.writeJson(out, string.concat(vm.projectRoot(), "/../deployments/", file));
        console2.log("adapter", d.adapter);
        console2.log("written", file);
    }
}
