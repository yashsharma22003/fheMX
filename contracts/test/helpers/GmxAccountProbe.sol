// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IGmxExchangeRouter} from "../../src/interfaces/gmx/IGmxExchangeRouter.sol";
import {IGmxOrderCallbackReceiver} from "../../src/interfaces/gmx/IGmxOrderCallbackReceiver.sol";
import {IGmxGasFeeCallbackReceiver} from "../../src/interfaces/gmx/IGmxGasFeeCallbackReceiver.sol";
import {GmxOrder, GmxBaseOrderUtils, GmxEventUtils} from "../../src/interfaces/gmx/GmxTypes.sol";

/// @notice Test-only stand-in for a GMX account: creates orders through the ExchangeRouter and records
///         every callback GMX makes. Not the user clone; it has no access control.
contract GmxAccountProbe is IGmxOrderCallbackReceiver, IGmxGasFeeCallbackReceiver {
    enum CallbackKind {
        None,
        Execution,
        Cancellation,
        Frozen,
        FeeRefund
    }

    struct Callback {
        CallbackKind kind;
        bytes32 key;
        address sender;
        uint256 value;
    }

    IGmxExchangeRouter public immutable exchangeRouter;
    address public immutable orderVault;
    address public immutable wnt;

    Callback[] private _callbacks;

    constructor(address exchangeRouter_, address orderVault_, address wnt_) {
        exchangeRouter = IGmxExchangeRouter(exchangeRouter_);
        orderVault = orderVault_;
        wnt = wnt_;
    }

    receive() external payable {}

    /// @notice Market-increase order with native-token collateral. msg.value = collateral + executionFee.
    function createMarketIncrease(
        address market,
        bool isLong,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 callbackGasLimit
    ) external payable returns (bytes32 key) {
        GmxBaseOrderUtils.CreateOrderParams memory params;
        params.addresses.receiver = address(this);
        params.addresses.cancellationReceiver = address(this);
        params.addresses.callbackContract = address(this);
        params.addresses.market = market;
        params.addresses.initialCollateralToken = wnt;
        params.numbers.sizeDeltaUsd = sizeDeltaUsd;
        params.numbers.acceptablePrice = acceptablePrice;
        params.numbers.executionFee = executionFee;
        params.numbers.callbackGasLimit = callbackGasLimit;
        params.orderType = GmxOrder.OrderType.MarketIncrease;
        params.decreasePositionSwapType = GmxOrder.DecreasePositionSwapType.NoSwap;
        params.isLong = isLong;
        params.shouldUnwrapNativeToken = true;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IGmxExchangeRouter.sendWnt, (orderVault, msg.value));
        calls[1] = abi.encodeCall(IGmxExchangeRouter.createOrder, (params));
        bytes[] memory results = exchangeRouter.multicall{value: msg.value}(calls);
        key = abi.decode(results[1], (bytes32));
    }

    function cancelOrder(bytes32 key) external {
        exchangeRouter.cancelOrder(key);
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callbackAt(uint256 i) external view returns (Callback memory) {
        return _callbacks[i];
    }

    function lastCallbackOfKind(CallbackKind kind) external view returns (Callback memory found) {
        for (uint256 i = _callbacks.length; i > 0; i--) {
            if (_callbacks[i - 1].kind == kind) return _callbacks[i - 1];
        }
    }

    function afterOrderExecution(bytes32 key, GmxEventUtils.EventLogData memory, GmxEventUtils.EventLogData memory)
        external
    {
        _callbacks.push(Callback(CallbackKind.Execution, key, msg.sender, 0));
    }

    function afterOrderCancellation(bytes32 key, GmxEventUtils.EventLogData memory, GmxEventUtils.EventLogData memory)
        external
    {
        _callbacks.push(Callback(CallbackKind.Cancellation, key, msg.sender, 0));
    }

    function afterOrderFrozen(bytes32 key, GmxEventUtils.EventLogData memory, GmxEventUtils.EventLogData memory)
        external
    {
        _callbacks.push(Callback(CallbackKind.Frozen, key, msg.sender, 0));
    }

    function refundExecutionFee(bytes32 key, GmxEventUtils.EventLogData memory) external payable {
        _callbacks.push(Callback(CallbackKind.FeeRefund, key, msg.sender, msg.value));
    }
}
