// SPDX-License-Identifier: BUSL-1.1
// Vendored from gmx-synthetics @ bf30ebb4cff17b7f92f8c738f145e75b871a1576 (IExchangeRouter, BaseRouter, PayableMulticall).
pragma solidity ^0.8.0;

import {GmxBaseOrderUtils} from "./GmxTypes.sol";

interface IGmxExchangeRouter {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);

    function sendWnt(address receiver, uint256 amount) external payable;

    function sendTokens(address token, address receiver, uint256 amount) external payable;

    function createOrder(GmxBaseOrderUtils.CreateOrderParams calldata params) external payable returns (bytes32);

    function updateOrder(
        bytes32 key,
        uint256 sizeDeltaUsd,
        uint256 acceptablePrice,
        uint256 triggerPrice,
        uint256 minOutputAmount,
        uint256 validFromTime,
        bool autoCancel
    ) external payable;

    function cancelOrder(bytes32 key) external payable;
}
