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

        // Anvil's first key stands in for dry runs; a live broadcast must set PRIVATE_KEY (with or without 0x).
        uint256 key = _privateKey();
        address deployer = vm.addr(key);
        address feeCollector = vm.envOr("FEE_COLLECTOR", deployer);

        vm.startBroadcast(key);
        d.accountImplementation = address(new UserAccount(_gmx(json), feeCollector));
        d.priceVerifier = _deployVerifier(json);
        SealedOrderAdapter adapter = new SealedOrderAdapter(_config(json, d, _markets(json)));
        vm.stopBroadcast();

        d.adapter = address(adapter);
        d.factory = address(adapter.factory());
        _record(d, deployer, feeCollector);
    }

    function _privateKey() private view returns (uint256) {
        string memory raw = vm.envOr("PRIVATE_KEY", string(""));
        if (bytes(raw).length == 0) return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        bytes memory b = bytes(raw);
        bool prefixed = b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X");
        return vm.parseUint(prefixed ? raw : string.concat("0x", raw));
    }

    /// @dev One feed per token from `adapter.priceFeeds`, each with its own max age.
    function _deployVerifier(string memory json) private returns (address) {
        uint256 n = _count(json, ".adapter.priceFeeds");
        address[] memory tokens = new address[](n);
        address[] memory feeds = new address[](n);
        uint32[] memory maxAges = new uint32[](n);
        for (uint256 i; i < n; i++) {
            string memory base = string.concat(".adapter.priceFeeds[", vm.toString(i), "]");
            tokens[i] = vm.parseJsonAddress(
                json, string.concat(".tokens.", vm.parseJsonString(json, string.concat(base, ".token")), ".address")
            );
            feeds[i] = vm.parseJsonAddress(
                json, string.concat(".chainlinkFeeds.", vm.parseJsonString(json, string.concat(base, ".feed")))
            );
            maxAges[i] = uint32(vm.parseJsonUint(json, string.concat(base, ".maxAgeSeconds")));
        }
        return address(new ChainlinkFeedPriceVerifier(tokens, feeds, maxAges, address(0), 0));
    }

    function _markets(string memory json) private pure returns (SealedOrderAdapter.MarketConfig[] memory markets) {
        string[] memory names = vm.parseJsonStringArray(json, ".adapter.markets");
        markets = new SealedOrderAdapter.MarketConfig[](names.length);
        for (uint256 i; i < names.length; i++) {
            string memory base = string.concat(".markets.", names[i]);
            markets[i] = SealedOrderAdapter.MarketConfig({
                market: vm.parseJsonAddress(json, string.concat(base, ".marketToken")),
                indexToken: vm.parseJsonAddress(json, string.concat(base, ".indexToken")),
                longToken: vm.parseJsonAddress(json, string.concat(base, ".longToken")),
                shortToken: vm.parseJsonAddress(json, string.concat(base, ".shortToken"))
            });
        }
    }

    /// @dev Length of a JSON array of objects (forge has no direct length cheatcode for them).
    function _count(string memory json, string memory path) private view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(path, "[", vm.toString(n), "]"))) n++;
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

    function _config(string memory json, Deployed memory d, SealedOrderAdapter.MarketConfig[] memory markets)
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
