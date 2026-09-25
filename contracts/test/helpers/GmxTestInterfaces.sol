// SPDX-License-Identifier: BUSL-1.1
// Keeper- and controller-side GMX functions that only tests call. Vendored from gmx-synthetics
// @ bf30ebb4cff17b7f92f8c738f145e75b871a1576 (OracleUtils, Price, Oracle, OrderHandler, RoleStore, DataStore, Keys).
pragma solidity ^0.8.0;

library GmxOracleUtils {
    struct SetPricesParams {
        address[] tokens;
        address[] providers;
        bytes[] data;
    }
}

library GmxPrice {
    struct Props {
        uint256 min;
        uint256 max;
    }
}

interface IGmxOracle {
    function setPrices(GmxOracleUtils.SetPricesParams memory params) external;
    function setPrimaryPrice(address token, GmxPrice.Props memory price) external;
    function setTimestamps(uint256 minTimestamp, uint256 maxTimestamp) external;
    function getTokensWithPricesCount() external view returns (uint256);
}

interface IGmxOrderHandler {
    function executeOrder(bytes32 key, GmxOracleUtils.SetPricesParams calldata oracleParams) external;
}

interface IGmxRoleStoreMembers {
    function getRoleMembers(bytes32 roleKey, uint256 start, uint256 end) external view returns (address[] memory);
}

interface IGmxDataStore {
    function getUint(bytes32 key) external view returns (uint256);
    function getBytes32Count(bytes32 setKey) external view returns (uint256);
}

library GmxKeys {
    bytes32 internal constant ORDER_KEEPER = keccak256(abi.encode("ORDER_KEEPER"));
    bytes32 internal constant REQUEST_EXPIRATION_TIME = keccak256(abi.encode("REQUEST_EXPIRATION_TIME"));
    bytes32 internal constant ACCOUNT_ORDER_LIST = keccak256(abi.encode("ACCOUNT_ORDER_LIST"));
    bytes32 internal constant ACCOUNT_POSITION_LIST = keccak256(abi.encode("ACCOUNT_POSITION_LIST"));

    function accountOrderListKey(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(ACCOUNT_ORDER_LIST, account));
    }

    function accountPositionListKey(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(ACCOUNT_POSITION_LIST, account));
    }
}
