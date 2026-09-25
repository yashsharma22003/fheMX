// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IUserAccount} from "../account/IUserAccount.sol";
import {UserAccountFactory} from "../account/UserAccountFactory.sol";

/// @notice Accepts sealed conditional orders for GMX V2 and (from milestone 4) fires them.
/// @dev Milestone 3 scope: sealed intake, price-independent cap checks on ciphertext, owner cancel.
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
        Cancelled
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

    uint8 public constant EXECUTION_ATTEMPTS = 2; // first try + one re-arm (design D4)
    uint256 private constant BPS = 10_000;

    UserAccountFactory public immutable factory;
    address public immutable wnt;
    uint64 public immutable minSizeUsd6;
    uint64 public immutable maxSizeUsd6;
    uint32 public immutable maxSlippageBps;
    uint32 public immutable maxFallbackSlippageBps;
    uint16 public immutable maxLeverage;
    uint16 public immutable increaseFeeBps;
    uint256 public immutable minExecutionFee;

    mapping(address market => bool) public isSupportedMarket;
    mapping(bytes32 orderId => SealedOrder) private _orders;
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

    error UnsupportedMarket(address market);
    error ZeroCollateral();
    error ExecutionFeeTooLow(uint256 fee, uint256 minimum);
    error FallbackSlippageTooHigh(uint32 bps, uint32 maximum);
    error NotOrderOwner(bytes32 orderId);
    error OrderNotOpen(bytes32 orderId);
    error InvalidConfig();

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
    function cancelOrder(bytes32 orderId) external {
        SealedOrder storage o = _orders[orderId];
        if (o.owner != msg.sender) revert NotOrderOwner(orderId);
        if (o.status != Status.Open) revert OrderNotOpen(orderId);
        o.status = Status.Cancelled;
        IUserAccount(o.account).release(orderId);
        emit OrderCancelled(orderId);
    }

    // ─── views ────────────────────────────────────────────────────────────────

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
