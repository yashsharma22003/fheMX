// SPDX-License-Identifier: BUSL-1.1
// Vendored from gmx-synthetics @ bf30ebb4cff17b7f92f8c738f145e75b871a1576
// (Reader.getExecutionPrice, ReaderPricingUtils.ExecutionPriceResult, MarketUtils.MarketPrices, Price.Props).
pragma solidity ^0.8.0;

library GmxPricing {
    struct Price {
        uint256 min;
        uint256 max;
    }

    struct MarketPrices {
        Price indexTokenPrice;
        Price longTokenPrice;
        Price shortTokenPrice;
    }

    struct ExecutionPriceResult {
        int256 priceImpactUsd;
        uint256 executionPrice;
        bool balanceWasImproved;
        int256 proportionalPendingImpactUsd;
        int256 totalImpactUsd;
        uint256 priceImpactDiffUsd;
    }
}

interface IGmxReader {
    /// @dev Runs the same execution-price calculation GMX validates `acceptablePrice` against.
    ///      sizeDeltaUsd > 0 for an increase, < 0 for a decrease.
    function getExecutionPrice(
        address dataStore,
        address marketKey,
        GmxPricing.MarketPrices memory prices,
        uint256 positionSizeInUsd,
        uint256 positionSizeInTokens,
        int256 sizeDeltaUsd,
        int256 pendingImpactAmount,
        bool isLong
    ) external view returns (GmxPricing.ExecutionPriceResult memory);
}
