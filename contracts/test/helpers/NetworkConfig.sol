// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Vm} from "forge-std/Vm.sol";

/// @notice Reads addresses from config/networks/<network>.json so tests and scripts share one source.
library NetworkConfig {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Gmx {
        address dataStore;
        address exchangeRouter;
        address orderHandler;
        address orderVault;
        address oracle;
        address reader;
        address roleStore;
        address router;
        address wnt;
    }

    struct Market {
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
    }

    function arbitrumSepolia() internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/../config/networks/arbitrum-sepolia.json"));
    }

    function gmx(string memory json) internal pure returns (Gmx memory g) {
        g.dataStore = vm.parseJsonAddress(json, ".gmx.dataStore");
        g.exchangeRouter = vm.parseJsonAddress(json, ".gmx.exchangeRouter");
        g.orderHandler = vm.parseJsonAddress(json, ".gmx.orderHandler");
        g.orderVault = vm.parseJsonAddress(json, ".gmx.orderVault");
        g.oracle = vm.parseJsonAddress(json, ".gmx.oracle");
        g.reader = vm.parseJsonAddress(json, ".gmx.reader");
        g.roleStore = vm.parseJsonAddress(json, ".gmx.roleStore");
        g.router = vm.parseJsonAddress(json, ".gmx.router");
        g.wnt = vm.parseJsonAddress(json, ".gmx.wnt");
    }

    function market(string memory json, string memory name) internal pure returns (Market memory m) {
        string memory base = string.concat(".markets.", name);
        m.marketToken = vm.parseJsonAddress(json, string.concat(base, ".marketToken"));
        m.indexToken = vm.parseJsonAddress(json, string.concat(base, ".indexToken"));
        m.longToken = vm.parseJsonAddress(json, string.concat(base, ".longToken"));
        m.shortToken = vm.parseJsonAddress(json, string.concat(base, ".shortToken"));
    }
}
