// SPDX-License-Identifier: BUSL-1.1
// Vendored from gmx-synthetics @ bf30ebb4cff17b7f92f8c738f145e75b871a1576 (IGasFeeCallbackReceiver).
pragma solidity ^0.8.0;

import {GmxEventUtils} from "./GmxTypes.sol";

interface IGmxGasFeeCallbackReceiver {
    function refundExecutionFee(bytes32 key, GmxEventUtils.EventLogData memory eventData) external payable;
}
