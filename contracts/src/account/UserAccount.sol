// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IUserAccount} from "./IUserAccount.sol";
import {IGmxExchangeRouter} from "../interfaces/gmx/IGmxExchangeRouter.sol";
import {IGmxOrderCallbackReceiver} from "../interfaces/gmx/IGmxOrderCallbackReceiver.sol";
import {IGmxGasFeeCallbackReceiver} from "../interfaces/gmx/IGmxGasFeeCallbackReceiver.sol";
import {IGmxRoleStore, GmxRole} from "../interfaces/gmx/IGmxRoleStore.sol";
import {GmxOrder, GmxBaseOrderUtils, GmxEventUtils} from "../interfaces/gmx/GmxTypes.sol";

interface IGmxDataStoreUint {
    function getUint(bytes32 key) external view returns (uint256);
}

/// @notice Per-user GMX account, deployed as an EIP-1167 clone by UserAccountFactory.
/// @dev Milestone 2 scope: native-ETH collateral (GMX's WNT), increase orders only.
///      GMX addresses and the fee collector are implementation immutables, shared by every clone.
contract UserAccount is IUserAccount, IGmxOrderCallbackReceiver, IGmxGasFeeCallbackReceiver, ReentrancyGuardTransient {
    bytes32 private constant SIZE_IN_USD = keccak256(abi.encode("SIZE_IN_USD"));

    IGmxExchangeRouter public immutable exchangeRouter;
    address public immutable orderVault;
    address public immutable dataStore;
    IGmxRoleStore public immutable roleStore;
    address public immutable wnt;
    address public immutable feeCollector;

    address public owner;
    address public adapter;

    mapping(bytes32 orderId => Lock) private _locks;
    mapping(bytes32 orderId => GmxOutcome) private _outcomes;
    mapping(bytes32 orderId => bytes32 gmxKey) private _gmxKeyOf;
    mapping(bytes32 gmxKey => bytes32 orderId) private _orderOf;
    mapping(bytes32 orderId => uint256) private _inFlightCollateral;
    uint256 private _totalLocked;

    modifier onlyAdapter() {
        if (msg.sender != adapter) revert NotAdapter();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev GMX calls back from its handlers, which hold CONTROLLER. Unknown order keys are ignored.
    modifier onlyGmxController() {
        if (!roleStore.hasRole(msg.sender, GmxRole.CONTROLLER)) revert NotGmxController(msg.sender);
        _;
    }

    constructor(
        address exchangeRouter_,
        address orderVault_,
        address dataStore_,
        address roleStore_,
        address wnt_,
        address feeCollector_
    ) {
        exchangeRouter = IGmxExchangeRouter(exchangeRouter_);
        orderVault = orderVault_;
        dataStore = dataStore_;
        roleStore = IGmxRoleStore(roleStore_);
        wnt = wnt_;
        feeCollector = feeCollector_;
        owner = address(0xdead); // the implementation itself can never be initialized
    }

    receive() external payable {}

    // ─── initialization ───────────────────────────────────────────────────────

    function initialize(address owner_, address adapter_) external {
        if (owner != address(0)) revert AlreadyInitialized();
        owner = owner_;
        adapter = adapter_;
        emit Initialized(owner_, adapter_);
    }

    // ─── adapter ──────────────────────────────────────────────────────────────

    function lock(
        bytes32 orderId,
        address collateralToken,
        uint256 collateral,
        uint256 feePerAttempt,
        uint8 attempts,
        uint256 protocolFeeReserve
    ) external onlyAdapter {
        if (collateralToken != wnt) revert UnsupportedToken(collateralToken);
        if (_locks[orderId].token != address(0) || _outcomes[orderId] != GmxOutcome.None) revert LockExists(orderId);

        uint256 total = collateral + feePerAttempt * attempts + protocolFeeReserve;
        uint256 available = freeBalance(collateralToken);
        if (total > available) revert InsufficientFreeBalance(total, available);

        _locks[orderId] = Lock(collateralToken, collateral, feePerAttempt, attempts, protocolFeeReserve);
        _totalLocked += total;
        emit Locked(orderId, collateralToken, collateral, feePerAttempt * attempts, protocolFeeReserve);
    }

    function release(bytes32 orderId) external onlyAdapter {
        Lock memory l = _locks[orderId];
        if (l.token == address(0)) revert NoLock(orderId);
        if (_outcomes[orderId] == GmxOutcome.Pending) revert OrderInFlight(orderId);

        uint256 remaining = _reserved(l);
        delete _locks[orderId];
        _totalLocked -= remaining;
        emit Released(orderId, remaining);
    }

    function submit(bytes32 orderId, OrderRequest calldata request)
        external
        onlyAdapter
        nonReentrant
        returns (bytes32 gmxKey)
    {
        Lock storage l = _locks[orderId];
        if (l.token == address(0)) revert NoLock(orderId);
        if (_outcomes[orderId] == GmxOutcome.Pending) revert OrderInFlight(orderId);
        if (l.attemptsLeft == 0) revert NoAttemptsLeft(orderId);
        if (!request.isIncrease) revert DecreaseNotSupported();
        if (request.collateralDelta > l.collateral) revert CollateralExceedsLock(request.collateralDelta, l.collateral);

        uint256 executionFee = l.feePerAttempt;
        l.collateral -= request.collateralDelta;
        l.attemptsLeft -= 1;
        uint256 sent = request.collateralDelta + executionFee;
        _totalLocked -= sent;
        _inFlightCollateral[orderId] = request.collateralDelta;

        GmxBaseOrderUtils.CreateOrderParams memory params;
        params.addresses.receiver = address(this);
        params.addresses.cancellationReceiver = address(this);
        params.addresses.callbackContract = address(this);
        params.addresses.market = request.market;
        params.addresses.initialCollateralToken = wnt;
        params.numbers.sizeDeltaUsd = request.sizeDeltaUsd;
        params.numbers.acceptablePrice = request.acceptablePrice;
        params.numbers.executionFee = executionFee;
        params.numbers.callbackGasLimit = request.callbackGasLimit;
        params.orderType = GmxOrder.OrderType.MarketIncrease;
        params.decreasePositionSwapType = GmxOrder.DecreasePositionSwapType.NoSwap;
        params.isLong = request.isLong;
        params.shouldUnwrapNativeToken = true;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IGmxExchangeRouter.sendWnt, (orderVault, sent));
        calls[1] = abi.encodeCall(IGmxExchangeRouter.createOrder, (params));
        bytes[] memory results = exchangeRouter.multicall{value: sent}(calls);
        gmxKey = abi.decode(results[1], (bytes32));

        _gmxKeyOf[orderId] = gmxKey;
        _orderOf[gmxKey] = orderId;
        _outcomes[orderId] = GmxOutcome.Pending;
        emit Submitted(orderId, gmxKey, request.collateralDelta, executionFee);
    }

    function payProtocolFee(bytes32 orderId, uint256 amount) external onlyAdapter nonReentrant {
        GmxOutcome outcome = _outcomes[orderId];
        if (outcome != GmxOutcome.Executed) revert FeeNotPayable(orderId, outcome);
        Lock storage l = _locks[orderId];
        if (amount > l.protocolFeeReserve) revert FeeExceedsReserve(amount, l.protocolFeeReserve);

        // The whole reserve leaves the lock: `amount` to the collector, the rest to the free balance.
        // A second call finds a zero reserve, so the fee is charged at most once.
        _totalLocked -= l.protocolFeeReserve;
        l.protocolFeeReserve = 0;

        (bool ok,) = feeCollector.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ProtocolFeePaid(orderId, feeCollector, amount);
    }

    // ─── owner ────────────────────────────────────────────────────────────────

    function withdraw(uint256 amount, address to) external onlyOwner nonReentrant {
        uint256 available = freeBalance(wnt);
        if (amount > available) revert InsufficientFreeBalance(amount, available);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── GMX callbacks: record state only (design D4) ─────────────────────────

    function afterOrderExecution(bytes32 key, GmxEventUtils.EventLogData memory, GmxEventUtils.EventLogData memory)
        external
        onlyGmxController
    {
        bytes32 orderId = _orderOf[key];
        if (orderId == bytes32(0)) return;
        delete _inFlightCollateral[orderId];
        _record(orderId, key, GmxOutcome.Executed);
    }

    function afterOrderCancellation(bytes32 key, GmxEventUtils.EventLogData memory, GmxEventUtils.EventLogData memory)
        external
        onlyGmxController
    {
        bytes32 orderId = _orderOf[key];
        if (orderId == bytes32(0)) return;
        // GMX has returned the collateral to this account; keep it under the order's lock for a re-arm.
        uint256 returned = _inFlightCollateral[orderId];
        delete _inFlightCollateral[orderId];
        if (_locks[orderId].token != address(0)) {
            _locks[orderId].collateral += returned;
            _totalLocked += returned;
        }
        _record(orderId, key, GmxOutcome.Cancelled);
    }

    function afterOrderFrozen(bytes32 key, GmxEventUtils.EventLogData memory, GmxEventUtils.EventLogData memory)
        external
        onlyGmxController
    {
        bytes32 orderId = _orderOf[key];
        if (orderId == bytes32(0)) return;
        _record(orderId, key, GmxOutcome.Frozen);
    }

    /// @dev Refunded execution fee lands in the free balance.
    function refundExecutionFee(bytes32, GmxEventUtils.EventLogData memory) external payable {}

    // ─── views ────────────────────────────────────────────────────────────────

    function freeBalance(address token) public view returns (uint256) {
        if (token != wnt) return 0;
        uint256 balance = address(this).balance;
        return balance > _totalLocked ? balance - _totalLocked : 0;
    }

    function lockOf(bytes32 orderId) external view returns (Lock memory) {
        return _locks[orderId];
    }

    function outcomeOf(bytes32 orderId) external view returns (GmxOutcome outcome, bytes32 gmxKey) {
        return (_outcomes[orderId], _gmxKeyOf[orderId]);
    }

    function positionSizeUsd(address market, address collateralToken, bool isLong) external view returns (uint256) {
        bytes32 positionKey = keccak256(abi.encode(address(this), market, collateralToken, isLong));
        return IGmxDataStoreUint(dataStore).getUint(keccak256(abi.encode(positionKey, SIZE_IN_USD)));
    }

    // ─── internal ─────────────────────────────────────────────────────────────

    function _reserved(Lock memory l) private pure returns (uint256) {
        return l.collateral + l.feePerAttempt * l.attemptsLeft + l.protocolFeeReserve;
    }

    function _record(bytes32 orderId, bytes32 gmxKey, GmxOutcome outcome) private {
        _outcomes[orderId] = outcome;
        emit GmxOutcomeRecorded(orderId, gmxKey, outcome);
    }
}
