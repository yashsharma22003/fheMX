// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IUserAccount} from "./IUserAccount.sol";
import {IGmxExchangeRouter} from "../interfaces/gmx/IGmxExchangeRouter.sol";
import {IGmxOrderCallbackReceiver} from "../interfaces/gmx/IGmxOrderCallbackReceiver.sol";
import {IGmxGasFeeCallbackReceiver} from "../interfaces/gmx/IGmxGasFeeCallbackReceiver.sol";
import {IGmxRoleStore, GmxRole} from "../interfaces/gmx/IGmxRoleStore.sol";
import {GmxOrder, GmxBaseOrderUtils, GmxEventUtils} from "../interfaces/gmx/GmxTypes.sol";

interface IGmxDataStoreView {
    function getUint(bytes32 key) external view returns (uint256);
    function containsBytes32(bytes32 setKey, bytes32 value) external view returns (bool);
}

/// @notice Per-user GMX account, deployed as an EIP-1167 clone by UserAccountFactory.
/// @dev GMX addresses and the fee collector are implementation immutables, shared by every clone.
contract UserAccount is IUserAccount, IGmxOrderCallbackReceiver, IGmxGasFeeCallbackReceiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct GmxContracts {
        address exchangeRouter;
        address router;
        address orderVault;
        address dataStore;
        address roleStore;
        address wnt;
    }

    struct ClosePositionRequest {
        address market;
        address collateralToken;
        bool isLong;
        uint256 sizeDeltaUsd;
        uint256 collateralDeltaAmount;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 callbackGasLimit;
    }

    /// @dev What an in-flight adapter order needs for reconcile.
    struct InFlight {
        address market;
        address token;
        bool isLong;
        bool isIncrease;
        uint256 sizeBefore;
        uint256 sizeDelta;
        uint256 collateralDelta;
    }

    bytes32 private constant SIZE_IN_USD = keccak256(abi.encode("SIZE_IN_USD"));
    bytes32 private constant ORDER_LIST = keccak256(abi.encode("ORDER_LIST"));

    IGmxExchangeRouter public immutable exchangeRouter;
    address public immutable router;
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
    mapping(bytes32 orderId => InFlight) private _inFlight;
    mapping(address token => uint256) private _locked;
    mapping(bytes32 orderId => bool) public cancelledByOwner;
    uint256 public pendingCount;
    bytes32 public manualCloseKey;

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

    constructor(GmxContracts memory gmx, address feeCollector_) {
        exchangeRouter = IGmxExchangeRouter(gmx.exchangeRouter);
        router = gmx.router;
        orderVault = gmx.orderVault;
        dataStore = gmx.dataStore;
        roleStore = IGmxRoleStore(gmx.roleStore);
        wnt = gmx.wnt;
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
        uint256 protocolFeeReserve,
        uint256 checkBudget
    ) external onlyAdapter {
        if (_locks[orderId].token != address(0) || _outcomes[orderId] != GmxOutcome.None) revert LockExists(orderId);

        uint256 fees = feePerAttempt * attempts + checkBudget;
        uint256 inToken = collateral + protocolFeeReserve;
        if (collateralToken == wnt) {
            _reserve(wnt, inToken + fees);
        } else {
            _reserve(collateralToken, inToken);
            _reserve(wnt, fees);
        }

        _locks[orderId] = Lock(collateralToken, collateral, feePerAttempt, attempts, protocolFeeReserve, checkBudget);
        emit Locked(orderId, collateralToken, collateral, fees, protocolFeeReserve);
    }

    function release(bytes32 orderId) external onlyAdapter {
        Lock memory l = _locks[orderId];
        if (l.token == address(0)) revert NoLock(orderId);
        if (_outcomes[orderId] == GmxOutcome.Pending) revert OrderInFlight(orderId);

        uint256 inToken = l.collateral + l.protocolFeeReserve;
        uint256 fees = l.feePerAttempt * l.attemptsLeft + l.checkBudget;
        delete _locks[orderId];
        _locked[l.token] -= inToken;
        _locked[wnt] -= fees;
        emit Released(orderId, inToken, fees);
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
        if (request.isIncrease) {
            if (request.collateralToken != l.token) revert CollateralTokenMismatch(request.collateralToken, l.token);
            if (request.collateralDelta > l.collateral) {
                revert CollateralExceedsLock(request.collateralDelta, l.collateral);
            }
        } else if (request.collateralDelta != 0) {
            revert DecreaseMovesNoCollateral();
        }
        _requireNoManualClose();

        uint256 executionFee = l.feePerAttempt;
        l.collateral -= request.collateralDelta;
        l.attemptsLeft -= 1;
        _locked[l.token] -= request.collateralDelta;
        _locked[wnt] -= executionFee;

        _inFlight[orderId] = InFlight({
            market: request.market,
            token: request.collateralToken,
            isLong: request.isLong,
            isIncrease: request.isIncrease,
            sizeBefore: positionSizeUsd(request.market, request.collateralToken, request.isLong),
            sizeDelta: request.sizeDeltaUsd,
            collateralDelta: request.collateralDelta
        });

        GmxBaseOrderUtils.CreateOrderParams memory params =
            _baseParams(request.market, request.collateralToken, request.isLong);
        params.numbers.sizeDeltaUsd = request.sizeDeltaUsd;
        params.numbers.acceptablePrice = request.acceptablePrice;
        params.numbers.executionFee = executionFee;
        params.numbers.callbackGasLimit = request.callbackGasLimit;
        params.orderType = request.isIncrease ? GmxOrder.OrderType.MarketIncrease : GmxOrder.OrderType.MarketDecrease;

        gmxKey = _createOrder(params, request.collateralToken, request.collateralDelta, executionFee);

        _gmxKeyOf[orderId] = gmxKey;
        _orderOf[gmxKey] = orderId;
        _outcomes[orderId] = GmxOutcome.Pending;
        pendingCount += 1;
        emit Submitted(orderId, gmxKey, request.collateralDelta, executionFee);
    }

    function payProtocolFee(bytes32 orderId, uint256 amount) external onlyAdapter nonReentrant {
        GmxOutcome outcome = _outcomes[orderId];
        if (outcome != GmxOutcome.Executed) revert FeeNotPayable(orderId, outcome);
        Lock storage l = _locks[orderId];
        if (amount > l.protocolFeeReserve) revert FeeExceedsReserve(amount, l.protocolFeeReserve);

        // The whole reserve leaves the lock: `amount` to the collector, the rest to the free balance.
        // A second call finds a zero reserve, so the fee is charged at most once.
        _locked[l.token] -= l.protocolFeeReserve;
        l.protocolFeeReserve = 0;
        _send(l.token, feeCollector, amount);
        emit ProtocolFeePaid(orderId, feeCollector, amount);
    }

    function payCheckFee(bytes32 orderId, address checker, uint256 reward, uint256 spread)
        external
        onlyAdapter
        nonReentrant
    {
        Lock storage l = _locks[orderId];
        if (l.token == address(0)) revert NoLock(orderId);
        uint256 total = reward + spread;
        if (total > l.checkBudget) revert InsufficientCheckBudget(orderId, total, l.checkBudget);
        l.checkBudget -= total;
        _locked[wnt] -= total;
        _send(wnt, checker, reward);
        _send(wnt, feeCollector, spread);
        emit CheckFeePaid(orderId, checker, reward, spread);
    }

    function addCheckBudget(bytes32 orderId, uint256 amount) external onlyAdapter {
        Lock storage l = _locks[orderId];
        if (l.token == address(0)) revert NoLock(orderId);
        _reserve(wnt, amount);
        l.checkBudget += amount;
        emit CheckBudgetAdded(orderId, amount);
    }

    // ─── reconcile (known issue 9) ────────────────────────────────────────────

    /// @dev Increase: executed if the position grew by at least the order size since submission; otherwise
    ///      cancelled, but only if the collateral is actually back in this account.
    ///      Decrease: executed if the position shrank by at least the order size; cancelled if unchanged.
    ///      Only adapter orders change the position while they are in flight: manual closes are blocked.
    function reconcile(bytes32 orderId) external returns (GmxOutcome outcome) {
        if (_outcomes[orderId] != GmxOutcome.Pending) revert NotInFlight(orderId);
        bytes32 gmxKey = _gmxKeyOf[orderId];
        if (IGmxDataStoreView(dataStore).containsBytes32(ORDER_LIST, gmxKey)) revert OrderStillAtGmx(gmxKey);

        InFlight memory f = _inFlight[orderId];
        uint256 sizeNow = positionSizeUsd(f.market, f.token, f.isLong);
        bool executed;
        bool cancelled;
        if (f.isIncrease) {
            executed = sizeNow >= f.sizeBefore + f.sizeDelta;
            cancelled = !executed && _balanceOf(f.token) >= _locked[f.token] + f.collateralDelta;
        } else {
            executed = sizeNow + f.sizeDelta <= f.sizeBefore;
            cancelled = !executed && sizeNow == f.sizeBefore;
        }

        if (executed) {
            outcome = GmxOutcome.Executed;
            _onExecuted(orderId, gmxKey);
        } else if (cancelled) {
            outcome = GmxOutcome.Cancelled;
            _onCancelled(orderId, gmxKey);
        } else {
            revert CannotReconcile(orderId);
        }
        emit Reconciled(orderId, outcome);
    }

    // ─── owner ────────────────────────────────────────────────────────────────

    /// @notice Withdraw free (unlocked) funds. `token` = WNT address for native ETH.
    function withdraw(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        uint256 available = freeBalance(token);
        if (amount > available) revert InsufficientFreeBalance(amount, available);
        _send(token, to, amount);
    }

    /// @notice Cancel an adapter order still pending at GMX (after GMX's request-expiration delay).
    ///         The outcome arrives through GMX's cancellation callback.
    function cancelGmxOrder(bytes32 orderId) external onlyOwner {
        if (_outcomes[orderId] != GmxOutcome.Pending) revert NotInFlight(orderId);
        cancelledByOwner[orderId] = true;
        exchangeRouter.cancelOrder(_gmxKeyOf[orderId]);
    }

    /// @notice Close or reduce a position with a GMX market decrease, paying the execution fee from free ETH.
    ///         Blocked while adapter orders are in flight, so reconcile can rely on position size.
    function closePosition(ClosePositionRequest calldata request) external onlyOwner nonReentrant returns (bytes32 gmxKey) {
        if (pendingCount != 0) revert AdapterOrdersInFlight(pendingCount);
        _requireNoManualClose();
        uint256 available = freeBalance(wnt);
        if (request.executionFee > available) revert InsufficientFreeBalance(request.executionFee, available);

        GmxBaseOrderUtils.CreateOrderParams memory params =
            _baseParams(request.market, request.collateralToken, request.isLong);
        params.numbers.sizeDeltaUsd = request.sizeDeltaUsd;
        params.numbers.initialCollateralDeltaAmount = request.collateralDeltaAmount;
        params.numbers.acceptablePrice = request.acceptablePrice;
        params.numbers.executionFee = request.executionFee;
        params.numbers.callbackGasLimit = request.callbackGasLimit;
        params.orderType = GmxOrder.OrderType.MarketDecrease;

        gmxKey = _createOrder(params, wnt, 0, request.executionFee);
        manualCloseKey = gmxKey;
        emit ManualCloseSubmitted(gmxKey, request.market, request.collateralToken, request.isLong, request.sizeDeltaUsd);
    }

    // ─── GMX callbacks: record state only (design D4) ─────────────────────────

    function afterOrderExecution(bytes32 key, GmxEventUtils.EventLogData memory, GmxEventUtils.EventLogData memory)
        external
        onlyGmxController
    {
        if (key == manualCloseKey) {
            manualCloseKey = bytes32(0);
            return;
        }
        bytes32 orderId = _orderOf[key];
        if (orderId == bytes32(0) || _outcomes[orderId] != GmxOutcome.Pending) return;
        _onExecuted(orderId, key);
    }

    function afterOrderCancellation(bytes32 key, GmxEventUtils.EventLogData memory, GmxEventUtils.EventLogData memory)
        external
        onlyGmxController
    {
        if (key == manualCloseKey) {
            manualCloseKey = bytes32(0);
            return;
        }
        bytes32 orderId = _orderOf[key];
        if (orderId == bytes32(0) || _outcomes[orderId] != GmxOutcome.Pending) return;
        _onCancelled(orderId, key);
    }

    function afterOrderFrozen(bytes32 key, GmxEventUtils.EventLogData memory, GmxEventUtils.EventLogData memory)
        external
        onlyGmxController
    {
        bytes32 orderId = _orderOf[key];
        if (orderId == bytes32(0) || _outcomes[orderId] != GmxOutcome.Pending) return;
        _finish(orderId);
        _record(orderId, key, GmxOutcome.Frozen);
    }

    /// @dev Refunded execution fee lands in the free ETH balance.
    function refundExecutionFee(bytes32, GmxEventUtils.EventLogData memory) external payable {}

    // ─── views ────────────────────────────────────────────────────────────────

    function freeBalance(address token) public view returns (uint256) {
        uint256 balance = _balanceOf(token);
        uint256 locked = _locked[token];
        return balance > locked ? balance - locked : 0;
    }

    function lockedBalance(address token) external view returns (uint256) {
        return _locked[token];
    }

    function lockOf(bytes32 orderId) external view returns (Lock memory) {
        return _locks[orderId];
    }

    function outcomeOf(bytes32 orderId) external view returns (GmxOutcome outcome, bytes32 gmxKey) {
        return (_outcomes[orderId], _gmxKeyOf[orderId]);
    }

    function positionSizeUsd(address market, address collateralToken, bool isLong) public view returns (uint256) {
        bytes32 positionKey = keccak256(abi.encode(address(this), market, collateralToken, isLong));
        return IGmxDataStoreView(dataStore).getUint(keccak256(abi.encode(positionKey, SIZE_IN_USD)));
    }

    // ─── internal ─────────────────────────────────────────────────────────────

    function _onExecuted(bytes32 orderId, bytes32 gmxKey) private {
        _finish(orderId);
        _record(orderId, gmxKey, GmxOutcome.Executed);
    }

    /// @dev GMX has returned the collateral to this account; keep it under the order's lock for a re-arm.
    function _onCancelled(bytes32 orderId, bytes32 gmxKey) private {
        uint256 returned = _inFlight[orderId].collateralDelta;
        _finish(orderId);
        Lock storage l = _locks[orderId];
        if (l.token != address(0)) {
            l.collateral += returned;
            _locked[l.token] += returned;
        }
        _record(orderId, gmxKey, GmxOutcome.Cancelled);
    }

    function _finish(bytes32 orderId) private {
        delete _inFlight[orderId];
        pendingCount -= 1;
    }

    function _record(bytes32 orderId, bytes32 gmxKey, GmxOutcome outcome) private {
        _outcomes[orderId] = outcome;
        emit GmxOutcomeRecorded(orderId, gmxKey, outcome);
    }

    /// @dev A manual close whose callback was lost is cleared once GMX no longer holds the order.
    function _requireNoManualClose() private {
        bytes32 key = manualCloseKey;
        if (key == bytes32(0)) return;
        if (IGmxDataStoreView(dataStore).containsBytes32(ORDER_LIST, key)) revert ManualCloseInFlight(key);
        manualCloseKey = bytes32(0);
    }

    function _reserve(address token, uint256 amount) private {
        uint256 available = freeBalance(token);
        if (amount > available) revert InsufficientFreeBalance(amount, available);
        _locked[token] += amount;
    }

    function _baseParams(address market, address collateralToken, bool isLong)
        private
        view
        returns (GmxBaseOrderUtils.CreateOrderParams memory params)
    {
        params.addresses.receiver = address(this);
        params.addresses.cancellationReceiver = address(this);
        params.addresses.callbackContract = address(this);
        params.addresses.market = market;
        params.addresses.initialCollateralToken = collateralToken;
        params.decreasePositionSwapType = GmxOrder.DecreasePositionSwapType.NoSwap;
        params.isLong = isLong;
        params.shouldUnwrapNativeToken = true;
    }

    /// @dev WNT collateral travels with the fee as native ETH; ERC20 collateral goes through GMX's Router.
    function _createOrder(
        GmxBaseOrderUtils.CreateOrderParams memory params,
        address token,
        uint256 collateral,
        uint256 executionFee
    ) private returns (bytes32 gmxKey) {
        bool erc20 = token != wnt && collateral != 0;
        bytes[] memory calls = new bytes[](erc20 ? 3 : 2);
        uint256 value = executionFee + (erc20 ? 0 : collateral);
        calls[0] = abi.encodeCall(IGmxExchangeRouter.sendWnt, (orderVault, value));
        if (erc20) {
            IERC20(token).forceApprove(router, collateral);
            calls[1] = abi.encodeCall(IGmxExchangeRouter.sendTokens, (token, orderVault, collateral));
        }
        calls[calls.length - 1] = abi.encodeCall(IGmxExchangeRouter.createOrder, (params));
        bytes[] memory results = exchangeRouter.multicall{value: value}(calls);
        gmxKey = abi.decode(results[results.length - 1], (bytes32));
    }

    function _balanceOf(address token) private view returns (uint256) {
        return token == wnt ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _send(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token == wnt) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
