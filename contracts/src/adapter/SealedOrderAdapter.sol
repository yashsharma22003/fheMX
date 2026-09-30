// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IUserAccount} from "../account/IUserAccount.sol";
import {UserAccountFactory} from "../account/UserAccountFactory.sol";
import {IPriceVerifier} from "../oracle/IPriceVerifier.sol";

/// @notice Accepts sealed conditional orders for GMX V2 and (from milestone 4) fires them.
/// @dev Scope through milestone 4: limit-entry (increase) orders on markets whose index token is the
///      collateral token (WNT), so one report prices both the trigger and the collateral.
///      Encrypted fixed-point conventions:
///        size:          USD with 6 decimals (euint64)  -> GMX sizeDeltaUsd = size * 1e24
///        trigger price: USD with 8 decimals (euint64)
///        slippage:      basis points (euint32)
///      All parameters are immutable (design §6: no admin, caps set at deployment).
contract SealedOrderAdapter {
    enum OrderKind {
        LimitIncrease
    }

    enum Status {
        None,
        Open,
        Cancelled,
        Fired,
        Filled
    }

    struct Config {
        address accountImplementation;
        address wnt;
        address[] markets;
        uint64 minSizeUsd6;
        uint64 maxSizeUsd6;
        uint32 maxSlippageBps;
        uint32 maxFallbackSlippageBps;
        uint16 maxLeverage;
        uint16 increaseFeeBps;
        uint256 minExecutionFee;
        address priceVerifier;
        uint32 maxReportAge;
        uint32 minCheckInterval;
        uint32 callbackGasLimit;
    }

    struct SealedOrderInput {
        address market;
        OrderKind kind;
        uint256 collateral;
        uint256 executionFee;
        uint32 fallbackSlippageBps;
        externalEbool isLong;
        bytes isLongProof;
        externalEuint64 sizeUsd6;
        bytes sizeProof;
        externalEuint64 triggerPrice8;
        bytes triggerProof;
        externalEuint32 slippageBps;
        bytes slippageProof;
    }

    struct SealedOrder {
        address owner;
        address account;
        address market;
        OrderKind kind;
        Status status;
        uint256 collateral;
        uint32 fallbackSlippageBps;
        ebool isLong;
        euint64 sizeUsd6;
        euint64 triggerPrice8;
        euint32 slippageBps;
        /// @dev Result of the intake caps. Encrypted, so a failing order is indistinguishable from a passing one.
        ebool intakeValid;
    }

    /// @dev Latest trigger check. The revealed fields decrypt to the real values if the order fired, else zero.
    struct CheckState {
        uint64 lastCheckAt;
        uint64 lastReportTimestamp;
        uint256 checkPrice8;
        euint64 revealedSize;
        ebool revealedIsLong;
        euint32 revealedSlippage;
    }

    struct Fill {
        uint256 sizeDeltaUsd;
        bool isLong;
        uint256 acceptablePrice;
        uint256 protocolFee;
        bytes32 gmxKey;
    }

    uint8 public constant EXECUTION_ATTEMPTS = 2; // first try + one re-arm (design D4)
    uint256 private constant BPS = 10_000;
    /// @dev size (USD, 6 decimals) -> GMX sizeDeltaUsd (30 decimals)
    uint256 private constant SIZE_TO_GMX = 1e24;
    /// @dev price8 (USD per whole WNT, 8 decimals) -> GMX price per wei (30 - 18 = 12 decimals)
    uint256 private constant PRICE8_TO_GMX = 1e4;
    /// @dev wei * price8 / 1e20 = USD with 6 decimals
    uint256 private constant WEI_PRICE8_TO_USD6 = 1e20;

    UserAccountFactory public immutable factory;
    address public immutable wnt;
    uint64 public immutable minSizeUsd6;
    uint64 public immutable maxSizeUsd6;
    uint32 public immutable maxSlippageBps;
    uint32 public immutable maxFallbackSlippageBps;
    uint16 public immutable maxLeverage;
    uint16 public immutable increaseFeeBps;
    uint256 public immutable minExecutionFee;
    IPriceVerifier public immutable priceVerifier;
    uint32 public immutable maxReportAge;
    uint32 public immutable minCheckInterval;
    uint32 public immutable callbackGasLimit;

    mapping(address market => bool) public isSupportedMarket;
    mapping(bytes32 orderId => SealedOrder) private _orders;
    mapping(bytes32 orderId => CheckState) private _checks;
    mapping(bytes32 orderId => Fill) private _fills;
    uint256 public orderCount;

    event OrderSealed(
        bytes32 indexed orderId,
        address indexed owner,
        address indexed account,
        address market,
        OrderKind kind,
        uint256 collateral,
        uint256 executionFee,
        uint256 protocolFeeReserve
    );
    event OrderCancelled(bytes32 indexed orderId);
    event OrderChecked(bytes32 indexed orderId, uint256 price8, uint256 reportTimestamp);
    event OrderFired(
        bytes32 indexed orderId, bytes32 indexed gmxKey, uint256 sizeDeltaUsd, bool isLong, uint256 acceptablePrice, uint256 protocolFee
    );
    event OrderFilled(bytes32 indexed orderId, uint256 protocolFee);

    error UnsupportedMarket(address market);
    error ZeroCollateral();
    error ExecutionFeeTooLow(uint256 fee, uint256 minimum);
    error FallbackSlippageTooHigh(uint32 bps, uint32 maximum);
    error NotOrderOwner(bytes32 orderId);
    error OrderNotOpen(bytes32 orderId);
    error InvalidConfig();
    error WrongMarket(bytes32 orderId, address market);
    error ReportTooOld(uint256 reportTimestamp, uint256 maxAge);
    error ReportFromFuture(uint256 reportTimestamp);
    error ReportNotNewer(bytes32 orderId, uint256 reportTimestamp, uint256 lastReportTimestamp);
    error CheckTooSoon(bytes32 orderId, uint256 nextCheckAt);
    error NotChecked(bytes32 orderId);
    error NotFired(bytes32 orderId);
    error ExceedsIndependentCaps(bytes32 orderId);
    error NotFilled(bytes32 orderId);

    constructor(Config memory cfg) {
        if (cfg.minSizeUsd6 == 0 || cfg.minSizeUsd6 > cfg.maxSizeUsd6 || cfg.maxLeverage == 0) revert InvalidConfig();
        if (cfg.maxSlippageBps > BPS || cfg.maxFallbackSlippageBps > BPS || cfg.increaseFeeBps > BPS) {
            revert InvalidConfig();
        }
        factory = new UserAccountFactory(cfg.accountImplementation, address(this));
        wnt = cfg.wnt;
        minSizeUsd6 = cfg.minSizeUsd6;
        maxSizeUsd6 = cfg.maxSizeUsd6;
        maxSlippageBps = cfg.maxSlippageBps;
        maxFallbackSlippageBps = cfg.maxFallbackSlippageBps;
        maxLeverage = cfg.maxLeverage;
        increaseFeeBps = cfg.increaseFeeBps;
        minExecutionFee = cfg.minExecutionFee;
        priceVerifier = IPriceVerifier(cfg.priceVerifier);
        maxReportAge = cfg.maxReportAge;
        minCheckInterval = cfg.minCheckInterval;
        callbackGasLimit = cfg.callbackGasLimit;
        for (uint256 i; i < cfg.markets.length; i++) {
            isSupportedMarket[cfg.markets[i]] = true;
        }
    }

    // ─── intake ───────────────────────────────────────────────────────────────

    /// @notice Submit a sealed order. Encrypted inputs must be created for this contract by msg.sender.
    ///         Collateral and fees must already sit in msg.sender's account (its address is
    ///         `factory.accountOf(msg.sender)`, fundable before it exists); the account is created on first use.   
    function submitOrder(SealedOrderInput calldata input) external returns (bytes32 orderId) {
        if (!isSupportedMarket[input.market]) revert UnsupportedMarket(input.market);
        if (input.collateral == 0) revert ZeroCollateral();
        if (input.executionFee < minExecutionFee) revert ExecutionFeeTooLow(input.executionFee, minExecutionFee);
        if (input.fallbackSlippageBps > maxFallbackSlippageBps) {
            revert FallbackSlippageTooHigh(input.fallbackSlippageBps, maxFallbackSlippageBps);
        }

        address account = factory.accountOf(msg.sender);
        if (account.code.length == 0) factory.createAccount(msg.sender);

        orderId = bytes32(++orderCount);
        SealedOrder storage o = _orders[orderId];  
        o.owner = msg.sender;
        o.account = account;
        o.market = input.market;
        o.kind = input.kind;
        o.status = Status.Open;
        o.collateral = input.collateral;
        o.fallbackSlippageBps = input.fallbackSlippageBps;

        // Proofs are bound to msg.sender and this contract, so another user's inputs can't be replayed here.
        o.isLong = FHE.asEbool(input.isLong, input.isLongProof);
        o.sizeUsd6 = FHE.asEuint64(input.sizeUsd6, input.sizeProof);
        o.triggerPrice8 = FHE.asEuint64(input.triggerPrice8, input.triggerProof);
        o.slippageBps = FHE.asEuint32(input.slippageBps, input.slippageProof);
        o.intakeValid = _intakeCaps(o.sizeUsd6, o.triggerPrice8, o.slippageBps);

        _grant(o.isLong, msg.sender);
        _grant(o.sizeUsd6, msg.sender);
        _grant(o.triggerPrice8, msg.sender);
        _grant(o.slippageBps, msg.sender);
        _grant(o.intakeValid, msg.sender);

        uint256 protocolFeeReserve = maxProtocolFee(input.collateral);
        IUserAccount(account).lock(
            orderId, wnt, input.collateral, input.executionFee, EXECUTION_ATTEMPTS, protocolFeeReserve
        );

        emit OrderSealed(
            orderId, msg.sender, account, input.market, input.kind, input.collateral, input.executionFee, protocolFeeReserve
        );
    }

    /// @notice Cancel a sealed order before it fires. Reveals only that an order existed.
    /// @dev Also closes a fired order that GMX cancelled; the automatic re-arm (design D4) is milestone 7.
    function cancelOrder(bytes32 orderId) external {
        SealedOrder storage o = _orders[orderId];
        if (o.owner != msg.sender) revert NotOrderOwner(orderId);
        if (o.status != Status.Open && !(o.status == Status.Fired && _gmxCancelled(o.account, orderId))) {
            revert OrderNotOpen(orderId);
        }
        o.status = Status.Cancelled;
        IUserAccount(o.account).release(orderId);
        emit OrderCancelled(orderId);
    }

    // ─── trigger check (design §4 step 4) ─────────────────────────────────────

    /// @notice Evaluate orders in `market` against one verified price report. Permissionless (design D3).
    /// @dev For each order: fired = intakeValid AND price crossed the trigger AND size within max leverage of
    ///      the collateral at this price. Size, side and slippage are then made publicly decryptable as
    ///      select(fired, value, 0): a non-fired check decrypts to zeros and reveals only "not yet".
    ///      The trigger price is never decrypted.
    function checkBatch(address market, bytes32[] calldata orderIds, bytes calldata report) external {
        (uint256 price8, uint256 reportTimestamp) = priceVerifier.verify(market, report);
        if (reportTimestamp > block.timestamp) revert ReportFromFuture(reportTimestamp);
        if (block.timestamp - reportTimestamp > maxReportAge) revert ReportTooOld(reportTimestamp, maxReportAge);

        euint64 ePrice = FHE.asEuint64(price8);
        for (uint256 i; i < orderIds.length; i++) {
            _check(orderIds[i], market, price8, reportTimestamp, ePrice);
        }
    }

    function _check(bytes32 orderId, address market, uint256 price8, uint256 reportTimestamp, euint64 ePrice) private {
        SealedOrder storage o = _orders[orderId];
        if (o.status != Status.Open) revert OrderNotOpen(orderId);
        if (o.market != market) revert WrongMarket(orderId, market);

        CheckState storage c = _checks[orderId];
        if (reportTimestamp <= c.lastReportTimestamp) {
            revert ReportNotNewer(orderId, reportTimestamp, c.lastReportTimestamp);
        }
        if (c.lastCheckAt != 0 && block.timestamp < c.lastCheckAt + minCheckInterval) {
            revert CheckTooSoon(orderId, c.lastCheckAt + minCheckInterval);
        }

        // Long limit entry fires at or below the trigger, short at or above.
        ebool crossed = FHE.select(o.isLong, FHE.lte(ePrice, o.triggerPrice8), FHE.gte(ePrice, o.triggerPrice8));
        ebool leverageOk = FHE.lte(o.sizeUsd6, FHE.asEuint64(_maxSizeUsd6(o.collateral, price8)));
        ebool fired = FHE.and(FHE.and(o.intakeValid, crossed), leverageOk);

        c.revealedSize = FHE.select(fired, o.sizeUsd6, FHE.asEuint64(0));
        c.revealedIsLong = FHE.select(fired, o.isLong, FHE.asEbool(false));
        c.revealedSlippage = FHE.select(fired, o.slippageBps, FHE.asEuint32(0));
        FHE.allowThis(c.revealedSize);
        FHE.allowThis(c.revealedIsLong);
        FHE.allowThis(c.revealedSlippage);
        FHE.allowPublic(c.revealedSize);
        FHE.allowPublic(c.revealedIsLong);
        FHE.allowPublic(c.revealedSlippage);

        c.lastCheckAt = uint64(block.timestamp);
        c.lastReportTimestamp = uint64(reportTimestamp);
        c.checkPrice8 = price8;
        emit OrderChecked(orderId, price8, reportTimestamp);
    }

    // ─── execute (design §4 step 5) ───────────────────────────────────────────

    /// @notice Publish the latest check's decryptions and, if the order fired, place it on GMX. Permissionless.
    /// @dev The signatures come from CoFHE's decryption service (`decryptForTx`); publishing verifies them.
    ///      All values are re-checked against the public, independent caps before any funds move.
    function execute(
        bytes32 orderId,
        uint64 size,
        bytes calldata sizeSignature,
        bool isLong,
        bytes calldata isLongSignature,
        uint32 slippage,
        bytes calldata slippageSignature
    ) external returns (bytes32 gmxKey) {
        if (_orders[orderId].status != Status.Open) revert OrderNotOpen(orderId);
        CheckState storage c = _checks[orderId];
        if (c.lastCheckAt == 0) revert NotChecked(orderId);

        FHE.publishDecryptResult(c.revealedSize, size, sizeSignature);
        FHE.publishDecryptResult(c.revealedIsLong, isLong, isLongSignature);
        FHE.publishDecryptResult(c.revealedSlippage, slippage, slippageSignature);
        if (size == 0) revert NotFired(orderId);

        gmxKey = _fire(orderId, size, isLong, slippage, c.checkPrice8);
    }

    function _fire(bytes32 orderId, uint64 size, bool isLong, uint32 slippage, uint256 price8)
        private
        returns (bytes32 gmxKey)
    {
        SealedOrder storage o = _orders[orderId];
        if (size > maxSizeUsd6 || size > _maxSizeUsd6(o.collateral, price8) || slippage > maxSlippageBps) {
            revert ExceedsIndependentCaps(orderId);
        }

        Fill storage f = _fills[orderId];
        f.sizeDeltaUsd = uint256(size) * SIZE_TO_GMX;
        f.isLong = isLong;
        f.acceptablePrice = _acceptablePrice(price8, slippage, isLong);
        f.protocolFee = uint256(size) * increaseFeeBps / BPS * WEI_PRICE8_TO_USD6 / price8;
        o.status = Status.Fired;

        gmxKey = IUserAccount(o.account).submit(
            orderId,
            IUserAccount.OrderRequest({
                market: o.market,
                isLong: isLong,
                isIncrease: true,
                sizeDeltaUsd: f.sizeDeltaUsd,
                collateralDelta: o.collateral,
                acceptablePrice: f.acceptablePrice,
                callbackGasLimit: callbackGasLimit
            })
        );
        f.gmxKey = gmxKey;
        emit OrderFired(orderId, gmxKey, f.sizeDeltaUsd, isLong, f.acceptablePrice, f.protocolFee);
    }

    // ─── settle (design §4 step 7, fee-model.md) ──────────────────────────────

    /// @notice After GMX reports the fill: pay the protocol fee and free the rest of the lock. Permissionless.
    function settle(bytes32 orderId) external {
        SealedOrder storage o = _orders[orderId];
        if (o.status != Status.Fired) revert NotFired(orderId);
        (IUserAccount.GmxOutcome outcome,) = IUserAccount(o.account).outcomeOf(orderId);
        if (outcome != IUserAccount.GmxOutcome.Executed) revert NotFilled(orderId);

        o.status = Status.Filled;
        uint256 fee = _fills[orderId].protocolFee;
        IUserAccount(o.account).payProtocolFee(orderId, fee);
        IUserAccount(o.account).release(orderId);
        emit OrderFilled(orderId, fee);
    }

    // ─── views ────────────────────────────────────────────────────────────────

    function checkOf(bytes32 orderId) external view returns (CheckState memory) {
        return _checks[orderId];
    }

    function fillOf(bytes32 orderId) external view returns (Fill memory) {
        return _fills[orderId];
    }

    function orderOf(bytes32 orderId) external view returns (SealedOrder memory) {
        return _orders[orderId];
    }

    function accountOf(address owner) external view returns (address) {
        return factory.accountOf(owner);
    }

    /// @notice Protocol-fee reserve for an order: the fee on the largest position this collateral allows.
    /// @dev Sized from public values only, so the reserve reveals nothing about the sealed size (fee-model.md).
    function maxProtocolFee(uint256 collateral) public view returns (uint256) {
        return collateral * maxLeverage * increaseFeeBps / BPS;
    }

    // ─── internal ─────────────────────────────────────────────────────────────

    /// @dev Largest size (USD, 6 decimals) the collateral supports at `price8`, capped to uint64.
    function _maxSizeUsd6(uint256 collateral, uint256 price8) private view returns (uint64) {
        uint256 maxSize = collateral * price8 / WEI_PRICE8_TO_USD6 * maxLeverage;
        return maxSize > type(uint64).max ? type(uint64).max : uint64(maxSize);
    }

    /// @dev GMX acceptable price per wei (30 - 18 decimals). Long increase: highest price accepted; short: lowest.
    function _acceptablePrice(uint256 price8, uint32 slippage, bool isLong) private pure returns (uint256) {
        uint256 p = price8 * PRICE8_TO_GMX;
        return isLong ? p * (BPS + slippage) / BPS : p * (BPS - slippage) / BPS;
    }

    function _gmxCancelled(address account, bytes32 orderId) private view returns (bool) {
        (IUserAccount.GmxOutcome outcome,) = IUserAccount(account).outcomeOf(orderId);
        return outcome == IUserAccount.GmxOutcome.Cancelled || outcome == IUserAccount.GmxOutcome.Frozen;
    }

    /// @dev Price-independent caps only. The leverage cap needs a price and is applied in each trigger check.
    function _intakeCaps(euint64 size, euint64 trigger, euint32 slippage) private returns (ebool valid) {
        valid = FHE.and(FHE.gte(size, FHE.asEuint64(minSizeUsd6)), FHE.lte(size, FHE.asEuint64(maxSizeUsd6)));
        valid = FHE.and(valid, FHE.lte(slippage, FHE.asEuint32(maxSlippageBps)));
        valid = FHE.and(valid, FHE.gt(trigger, FHE.asEuint64(0)));
    }

    function _grant(ebool v, address user) private {
        FHE.allowThis(v);
        FHE.allow(v, user);
    }

    function _grant(euint64 v, address user) private {
        FHE.allowThis(v);
        FHE.allow(v, user);
    }

    function _grant(euint32 v, address user) private {
        FHE.allowThis(v);
        FHE.allow(v, user);
    }
}
