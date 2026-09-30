// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGmxExchangeRouter} from "../../src/interfaces/gmx/IGmxExchangeRouter.sol";
import {IGmxReader, GmxPricing} from "../../src/interfaces/gmx/IGmxReader.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory symbol, uint8 decimals_) ERC20(symbol, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal GMX stand-ins for unit tests (no fork). Fork tests use the real contracts.
contract MockGmxRoleStore {
    mapping(address => mapping(bytes32 => bool)) public hasRole;

    function grant(address account, bytes32 role) external {
        hasRole[account][role] = true;
    }
}

contract MockGmxExchangeRouter {
    uint256 public ordersCreated;
    uint256 public lastValue;
    uint256 public lastTokenAmount;
    bytes32 public lastCancelled;

    /// @dev Accepts the [sendWnt, (sendTokens,) createOrder] multicall the account makes; pulls tokens the way
    ///      GMX's Router does (the test deploys the account with this contract as `router`); returns a fresh key.
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        lastValue = msg.value;
        for (uint256 i; i < data.length; i++) {
            if (bytes4(data[i][:4]) == IGmxExchangeRouter.sendTokens.selector) {
                (address token,, uint256 amount) = abi.decode(data[i][4:], (address, address, uint256));
                IERC20(token).transferFrom(msg.sender, address(this), amount);
                lastTokenAmount = amount;
            }
        }
        ordersCreated++;
        results[data.length - 1] = abi.encode(keccak256(abi.encode("gmx-order", ordersCreated)));
    }

    function cancelOrder(bytes32 key) external payable {
        lastCancelled = key;
    }
}

/// @notice Returns the index price as the execution price (no price impact) unless a fill price is forced.
contract MockGmxReader is IGmxReader {
    uint256 public forcedExecutionPrice;

    function forceExecutionPrice(uint256 price) external {
        forcedExecutionPrice = price;
    }

    function getExecutionPrice(
        address,
        address,
        GmxPricing.MarketPrices memory prices,
        uint256,
        uint256,
        int256,
        int256,
        bool
    ) external view returns (GmxPricing.ExecutionPriceResult memory result) {
        result.executionPrice = forcedExecutionPrice != 0 ? forcedExecutionPrice : prices.indexTokenPrice.min;
    }
}

contract MockGmxDataStore {
    mapping(bytes32 => uint256) public getUint;
    mapping(bytes32 => int256) public getInt;
    mapping(bytes32 => mapping(bytes32 => bool)) public containsBytes32;

    function setUint(bytes32 key, uint256 value) external {
        getUint[key] = value;
    }

    function setContains(bytes32 setKey, bytes32 value, bool contained) external {
        containsBytes32[setKey][value] = contained;
    }
}

/// @notice Settable Chainlink AggregatorV3 for unit tests.
contract MockAggregator {
    uint8 public decimals;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer, uint256 updatedAt) external {
        _answer = answer;
        _startedAt = updatedAt;
        _updatedAt = updatedAt;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _startedAt, _updatedAt, 1);
    }
}
