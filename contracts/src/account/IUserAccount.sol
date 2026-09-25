// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice A user's GMX account: holds their funds, is the GMX `account`, `receiver`,
///         `cancellationReceiver` and `callbackContract` for every order placed through the adapter.
/// @dev The adapter is fixed at initialization. This interface is what the adapter codes against;
///      owner-facing functions (deposit, withdraw, manual GMX actions) live on the implementation.
interface IUserAccount {
    enum GmxOutcome {
        None,
        Pending,
        Executed,
        Cancelled,
        Frozen
    }

    /// @dev What the adapter asks for. The account builds GMX's CreateOrderParams itself and always
    ///      routes funds and callbacks back to itself.
    struct OrderRequest {
        address market;
        bool isLong;
        bool isIncrease;
        uint256 sizeDeltaUsd;
        uint256 collateralDelta;
        uint256 acceptablePrice;
        uint256 callbackGasLimit;
    }

    struct Lock {
        address token;
        uint256 collateral;
        uint256 feePerAttempt;
        uint8 attemptsLeft;
        uint256 protocolFeeReserve;
    }

    event Initialized(address indexed owner, address indexed adapter);
    event Locked(bytes32 indexed orderId, address token, uint256 collateral, uint256 executionFees, uint256 protocolFeeReserve);
    event Released(bytes32 indexed orderId, uint256 returnedToFreeBalance);
    event Submitted(bytes32 indexed orderId, bytes32 indexed gmxKey, uint256 collateralDelta, uint256 executionFee);
    event GmxOutcomeRecorded(bytes32 indexed orderId, bytes32 indexed gmxKey, GmxOutcome outcome);
    event ProtocolFeePaid(bytes32 indexed orderId, address indexed collector, uint256 amount);

    error AlreadyInitialized();
    error NotAdapter();
    error NotOwner();
    error NotGmxController(address caller);
    error UnsupportedToken(address token);
    error InsufficientFreeBalance(uint256 required, uint256 available);
    error LockExists(bytes32 orderId);
    error NoLock(bytes32 orderId);
    error NoAttemptsLeft(bytes32 orderId);
    error CollateralExceedsLock(uint256 requested, uint256 locked);
    error OrderInFlight(bytes32 orderId);
    error DecreaseNotSupported();
    error FeeNotPayable(bytes32 orderId, GmxOutcome outcome);
    error FeeExceedsReserve(uint256 requested, uint256 reserved);
    error TransferFailed();

    function initialize(address owner, address adapter) external;
    function owner() external view returns (address);
    function adapter() external view returns (address);

    /// @notice Reserve collateral, `attempts` execution fees and a protocol-fee reserve for one sealed order.
    function lock(
        bytes32 orderId,
        address collateralToken,
        uint256 collateral,
        uint256 feePerAttempt,
        uint8 attempts,
        uint256 protocolFeeReserve
    ) external;

    /// @notice Return an order's remaining reserve to the free balance.
    function release(bytes32 orderId) external;

    /// @notice Spend one execution fee and `request.collateralDelta` from the lock and create the GMX order.
    function submit(bytes32 orderId, OrderRequest calldata request) external returns (bytes32 gmxKey);

    /// @notice Pay the protocol fee from the order's reserve. Only after GMX reports the order executed.
    function payProtocolFee(bytes32 orderId, uint256 amount) external;

    function freeBalance(address token) external view returns (uint256);
    function lockOf(bytes32 orderId) external view returns (Lock memory);
    function outcomeOf(bytes32 orderId) external view returns (GmxOutcome outcome, bytes32 gmxKey);
    function positionSizeUsd(address market, address collateralToken, bool isLong) external view returns (uint256);
}
