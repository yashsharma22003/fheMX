// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {UnsignedEncryptedInput} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";
import {IUserAccount} from "../account/IUserAccount.sol";
import {UserAccountFactory} from "../account/UserAccountFactory.sol";
import {IPriceVerifier} from "../oracle/IPriceVerifier.sol";
import {IGmxReader, GmxPricing} from "../interfaces/gmx/IGmxReader.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IGmxDataStoreRead {
    function getUint(bytes32 key) external view returns (uint256);
    function getInt(bytes32 key) external view returns (int256);
}

/// @notice Accepts sealed conditional orders for GMX V2 and fires them when their hidden trigger is crossed.
/// @dev Order kinds: limit entry (increase), stop-loss and take-profit (decrease an existing position of the
///      user's account). Any configured market; collateral is the market's long or short token (GMX pool tokens).
///      The index price decides triggers; the collateral price bounds leverage and converts the fee; long and
///      short token prices feed GMX's execution-price estimate. All come from `priceVerifier`.
///      Acceptable prices are anchored on GMX's own execution-price estimate at the check price (Reader), so a
///      market's price impact doesn't make orders fail; the user's slippage bounds movement around that fill.
///      Encrypted fixed-point conventions:
///        size:          USD with 6 decimals (euint64)  -> GMX sizeDeltaUsd = size * 1e24
///        trigger price: USD with 8 decimals (euint64)
///        slippage:      basis points (euint32)
///      All parameters are immutable (design §6: no admin, caps set at deployment).
contract SealedOrderAdapter is ReentrancyGuardTransient {
    enum OrderKind {
        LimitIncrease,
        StopLoss,
        TakeProfit
    }

    /// @dev Why `checkBatch` passed over an order instead of checking it.
    enum SkipReason {
        NotOpen,
        WrongMarket,
        ReportNotNewer,
        TooSoon,
        NoCheckBudget
    }

    enum Status {
        None,
        Open,
        Cancelled,
        Fired,
        Filled
    }

    /// @dev A GMX market as configured at deployment. Token decimals are read once, at construction.
    struct MarketConfig {
        address market;
        address indexToken;
        address longToken;
        address shortToken;
    }

    struct MarketInfo {
        address indexToken;
        address longToken;
        address shortToken;
        uint8 indexDecimals;
        uint8 longDecimals;
        uint8 shortDecimals;
    }

    struct Config {
        address accountImplementation;
        address wnt;
        MarketConfig[] markets;
        uint64 minSizeUsd6;
        uint64 maxSizeUsd6;
        uint32 maxSlippageBps;
        uint32 maxFallbackSlippageBps;
        uint16 maxLeverage;
        uint16 increaseFeeBps;
        uint256 decreaseFeeFlat;
        uint256 minExecutionFee;
        address priceVerifier;
        uint32 maxReportAge;
        uint32 minCheckInterval;
        uint32 callbackGasLimit;
        address gmxReader;
        address gmxDataStore;
        /// @dev ETH charged to the order's check budget per order checked (design D3); 0 disables
        uint256 checkFee;
        /// @dev part of `checkFee` that goes to the fee collector (fee-model.md §6); the rest goes to the checker
        uint256 checkFeeSpread;
    }

    /// @dev `collateral` is posted collateral for a limit entry and must be 0 for stop-loss/take-profit.
    ///      `collateralToken` is WNT for a limit entry, or the collateral token of the position being reduced.
    ///      The four encrypted fields are one CoFHE batch, in this order (bool, uint64, uint64, uint32), with one
    ///      `inputProof`: what `@cofhe/sdk` `encryptInputs([...]).setConsumingContract(adapter)` returns.
    struct SealedOrderInput {
        address market;
        OrderKind kind;
        address collateralToken;
        uint256 collateral;
        uint256 executionFee;
        uint32 fallbackSlippageBps;
        /// @dev ETH locked to pay per-check fees; at least one check's fee, topped up with `topUpCheckBudget`
        uint256 checkBudget;
        externalEbool isLong;
        externalEuint64 sizeUsd6;
        externalEuint64 triggerPrice8;
        externalEuint32 slippageBps;
        bytes inputProof;
    }

    struct SealedOrder {
        address owner;
        address account;
        address market;
        OrderKind kind;
        Status status;
        address collateralToken;
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
        /// @dev collateral-token price at the check (limit entries): bounds leverage, converts the fee
        uint256 collateralPrice8;
        euint64 revealedSize;
        ebool revealedIsLong;
        euint32 revealedSlippage;
    }

    /// @dev Plaintext terms once fired. `size6` is the revealed (untrimmed) size, reused by a re-arm.
    struct Fill {
        uint256 sizeDeltaUsd;
        uint64 size6;
        bool isLong;
        uint32 slippage;
        uint256 acceptablePrice;
        uint256 protocolFee;
        bytes32 gmxKey;
        bool rearmed;
    }

    uint8 public constant EXECUTION_ATTEMPTS = 2; // first try + one re-arm (design D4)
    uint256 private constant BPS = 10_000;
    /// @dev size (USD, 6 decimals) -> GMX sizeDeltaUsd (30 decimals)
    uint256 private constant SIZE_TO_GMX = 1e24;
    bytes32 private constant SIZE_IN_USD = keccak256(abi.encode("SIZE_IN_USD"));
    bytes32 private constant SIZE_IN_TOKENS = keccak256(abi.encode("SIZE_IN_TOKENS"));
    bytes32 private constant PENDING_IMPACT_AMOUNT = keccak256(abi.encode("PENDING_IMPACT_AMOUNT"));

    UserAccountFactory public immutable factory;
    address public immutable wnt;
    uint64 public immutable minSizeUsd6;
    uint64 public immutable maxSizeUsd6;
    uint32 public immutable maxSlippageBps;
    uint32 public immutable maxFallbackSlippageBps;
    uint16 public immutable maxLeverage;
    uint16 public immutable increaseFeeBps;
    uint256 public immutable decreaseFeeFlat;
    uint256 public immutable minExecutionFee;
    IPriceVerifier public immutable priceVerifier;
    uint32 public immutable maxReportAge;
    uint32 public immutable minCheckInterval;
    uint32 public immutable callbackGasLimit;
    IGmxReader public immutable gmxReader;
    address public immutable gmxDataStore;
    uint256 public immutable checkFee;
    uint256 public immutable checkFeeSpread;

    mapping(address market => MarketInfo) private _markets;
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
    event OrderVoided(bytes32 indexed orderId);
    event OrderRearmed(bytes32 indexed orderId, bytes32 indexed gmxKey, uint256 sizeDeltaUsd, uint256 acceptablePrice);
    event OrderFilled(bytes32 indexed orderId, uint256 protocolFee);
    event CheckBudgetToppedUp(bytes32 indexed orderId, uint256 amount);
    event CheckSkipped(bytes32 indexed orderId, SkipReason reason);

    error UnsupportedMarket(address market);
    error ZeroCollateral();
    error DecreaseTakesNoCollateral();
    error UnsupportedCollateral(address token);
    error ExecutionFeeTooLow(uint256 fee, uint256 minimum);
    error FallbackSlippageTooHigh(uint32 bps, uint32 maximum);
    error NotOrderOwner(bytes32 orderId);
    error OrderNotOpen(bytes32 orderId);
    error InvalidConfig();
    error ReportTooOld(uint256 reportTimestamp, uint256 maxAge);
    error ReportFromFuture(uint256 reportTimestamp);
    error NotChecked(bytes32 orderId);
    error CheckExpired(bytes32 orderId, uint256 expiredAt);
    error NotFired(bytes32 orderId);
    error ExceedsIndependentCaps(bytes32 orderId);
    error NotFilled(bytes32 orderId);
    error NotRearmable(bytes32 orderId);
    error UnsupportedDecimals(address token, uint8 decimals);
    error CheckBudgetTooLow(uint256 budget, uint256 checkFee);

    constructor(Config memory cfg) {
        if (cfg.minSizeUsd6 == 0 || cfg.minSizeUsd6 > cfg.maxSizeUsd6 || cfg.maxLeverage == 0) revert InvalidConfig();
        if (cfg.maxSlippageBps >= BPS || cfg.maxFallbackSlippageBps >= BPS || cfg.increaseFeeBps > BPS) {
            revert InvalidConfig();
        }
        if (cfg.checkFeeSpread > cfg.checkFee) revert InvalidConfig();
        factory = new UserAccountFactory(cfg.accountImplementation, address(this));
        wnt = cfg.wnt;
        minSizeUsd6 = cfg.minSizeUsd6;
        maxSizeUsd6 = cfg.maxSizeUsd6;
        maxSlippageBps = cfg.maxSlippageBps;
        maxFallbackSlippageBps = cfg.maxFallbackSlippageBps;
        maxLeverage = cfg.maxLeverage;
        increaseFeeBps = cfg.increaseFeeBps;
        decreaseFeeFlat = cfg.decreaseFeeFlat;
        minExecutionFee = cfg.minExecutionFee;
        priceVerifier = IPriceVerifier(cfg.priceVerifier);
        maxReportAge = cfg.maxReportAge;
        minCheckInterval = cfg.minCheckInterval;
        callbackGasLimit = cfg.callbackGasLimit;
        gmxReader = IGmxReader(cfg.gmxReader);
        gmxDataStore = cfg.gmxDataStore;
        checkFee = cfg.checkFee;
        checkFeeSpread = cfg.checkFeeSpread;
        for (uint256 i; i < cfg.markets.length; i++) {
            MarketConfig memory m = cfg.markets[i];
            _markets[m.market] = MarketInfo({
                indexToken: m.indexToken,
                longToken: m.longToken,
                shortToken: m.shortToken,
                indexDecimals: _decimals(m.indexToken),
                longDecimals: _decimals(m.longToken),
                shortDecimals: _decimals(m.shortToken)
            });
        }
    }

    // ─── intake ───────────────────────────────────────────────────────────────

    /// @notice Submit a sealed order. Encrypted inputs must be created for this contract by msg.sender.
    ///         Funds must already sit in msg.sender's account (its address is `factory.accountOf(msg.sender)`,
    ///         fundable before it exists); the account is created on first use.
    function submitOrder(SealedOrderInput calldata input) external nonReentrant returns (bytes32 orderId) {
        MarketInfo memory m = _markets[input.market];
        if (m.indexToken == address(0)) revert UnsupportedMarket(input.market);
        if (input.collateralToken != m.longToken && input.collateralToken != m.shortToken) {
            revert UnsupportedCollateral(input.collateralToken);
        }
        bool increase = input.kind == OrderKind.LimitIncrease;
        if (increase) {
            if (input.collateral == 0) revert ZeroCollateral();
        } else if (input.collateral != 0) {
            revert DecreaseTakesNoCollateral();
        }
        if (input.executionFee < minExecutionFee) revert ExecutionFeeTooLow(input.executionFee, minExecutionFee);
        if (input.fallbackSlippageBps > maxFallbackSlippageBps) {
            revert FallbackSlippageTooHigh(input.fallbackSlippageBps, maxFallbackSlippageBps);
        }
        if (input.checkBudget < checkFee) revert CheckBudgetTooLow(input.checkBudget, checkFee);

        address account = factory.accountOf(msg.sender);
        if (account.code.length == 0) factory.createAccount(msg.sender);

        orderId = bytes32(++orderCount);
        SealedOrder storage o = _orders[orderId];
        o.owner = msg.sender;
        o.account = account;
        o.market = input.market;
        o.kind = input.kind;
        o.status = Status.Open;
        o.collateralToken = input.collateralToken;
        o.collateral = input.collateral;
        o.fallbackSlippageBps = input.fallbackSlippageBps;

        _verifyInputs(o, input);
        o.intakeValid = _intakeCaps(o.sizeUsd6, o.triggerPrice8, o.slippageBps);

        _grant(o.isLong, msg.sender);
        _grant(o.sizeUsd6, msg.sender);
        _grant(o.triggerPrice8, msg.sender);
        _grant(o.slippageBps, msg.sender);
        _grant(o.intakeValid, msg.sender);

        // A limit entry locks its collateral and fee reserve in the collateral token. Decrease orders lock no
        // collateral; their fee reserve is the flat decrease fee, in ETH. Execution fees are always ETH.
        uint256 protocolFeeReserve = increase ? maxProtocolFee(input.collateral) : decreaseFeeFlat;
        IUserAccount(account).lock(
            orderId,
            increase ? input.collateralToken : wnt,
            input.collateral,
            input.executionFee,
            EXECUTION_ATTEMPTS,
            protocolFeeReserve,
            input.checkBudget
        );

        emit OrderSealed(
            orderId, msg.sender, account, input.market, input.kind, input.collateral, input.executionFee, protocolFeeReserve
        );
    }

    /// @dev One proof covers all four inputs. It is bound to msg.sender and this contract, so another user's
    ///      inputs, or inputs made for another contract, can't be replayed here.
    function _verifyInputs(SealedOrder storage o, SealedOrderInput calldata input) private {
        UnsignedEncryptedInput[] memory inputs = new UnsignedEncryptedInput[](4);
        inputs[0] = UnsignedEncryptedInput(uint256(externalEbool.unwrap(input.isLong)), 0, Utils.EBOOL_TFHE);
        inputs[1] = UnsignedEncryptedInput(uint256(externalEuint64.unwrap(input.sizeUsd6)), 0, Utils.EUINT64_TFHE);
        inputs[2] = UnsignedEncryptedInput(uint256(externalEuint64.unwrap(input.triggerPrice8)), 0, Utils.EUINT64_TFHE);
        inputs[3] = UnsignedEncryptedInput(uint256(externalEuint32.unwrap(input.slippageBps)), 0, Utils.EUINT32_TFHE);
        bytes32[] memory handles = Impl.verifyBatchInputs(inputs, input.inputProof);
        o.isLong = ebool.wrap(handles[0]);
        o.sizeUsd6 = euint64.wrap(handles[1]);
        o.triggerPrice8 = euint64.wrap(handles[2]);
        o.slippageBps = euint32.wrap(handles[3]);
    }

    /// @notice Add free ETH from the owner's account to an open order's check budget.
    function topUpCheckBudget(bytes32 orderId, uint256 amount) external {
        SealedOrder storage o = _orders[orderId];
        if (o.owner != msg.sender) revert NotOrderOwner(orderId);
        if (o.status != Status.Open) revert OrderNotOpen(orderId);
        IUserAccount(o.account).addCheckBudget(orderId, amount);
        emit CheckBudgetToppedUp(orderId, amount);
    }

    /// @notice Cancel a sealed order before it fires, or close one whose GMX order was cancelled.
    ///         Before firing, reveals only that an order existed.
    function cancelOrder(bytes32 orderId) external nonReentrant {
        SealedOrder storage o = _orders[orderId];
        if (o.owner != msg.sender) revert NotOrderOwner(orderId);
        if (o.status != Status.Open && !(o.status == Status.Fired && _gmxCancelled(o.account, orderId))) {
            revert OrderNotOpen(orderId);
        }
        _close(orderId, o);
        emit OrderCancelled(orderId);
    }

    // ─── trigger check (design §4 step 4) ─────────────────────────────────────

    /// @notice Evaluate orders in `market` against one verified price report. Permissionless (design D3).
    /// @dev For each order: fired = intakeValid AND price crossed the trigger in the order kind's direction
    ///      AND (for a limit entry) size within max leverage of the collateral at this price. Size, side and
    ///      slippage are then made publicly decryptable as select(fired, value, 0): a non-fired check decrypts
    ///      to zeros and reveals only "not yet". The trigger price is never decrypted.
    /// @param report passed to the verifier for the index price (ignored by Chainlink Data Feeds)
    ///      Each order checked pays `checkFee` from its check budget: the caller gets `checkFee - checkFeeSpread`
    ///      for its gas, the fee collector gets the spread. Orders that can't be checked (not open, other market,
    ///      report not newer, too soon, no budget) are skipped with `CheckSkipped`, so one doesn't fail the batch.
    ///      A fire is sticky until it expires: while the previous check is still executable, a re-check keeps the
    ///      revealed values if that check fired, so a later non-crossing check can't erase an unexecuted fire.
    function checkBatch(address market, bytes32[] calldata orderIds, bytes calldata report) external nonReentrant {
        MarketInfo memory m = _markets[market];
        if (m.indexToken == address(0)) revert UnsupportedMarket(market);
        (uint256 price8, uint256 reportTimestamp) = priceVerifier.price(m.indexToken, report);
        if (reportTimestamp > block.timestamp) revert ReportFromFuture(reportTimestamp);
        if (block.timestamp - reportTimestamp > maxReportAge) revert ReportTooOld(reportTimestamp, maxReportAge);

        euint64 ePrice = FHE.asEuint64(price8);
        for (uint256 i; i < orderIds.length; i++) {
            _check(orderIds[i], market, m, price8, reportTimestamp, ePrice);
        }
    }

    function _check(
        bytes32 orderId,
        address market,
        MarketInfo memory m,
        uint256 price8,
        uint256 reportTimestamp,
        euint64 ePrice
    ) private {
        SealedOrder storage o = _orders[orderId];
        CheckState storage c = _checks[orderId];
        SkipReason reason;
        if (o.status != Status.Open) reason = SkipReason.NotOpen;
        else if (o.market != market) reason = SkipReason.WrongMarket;
        else if (reportTimestamp <= c.lastReportTimestamp) reason = SkipReason.ReportNotNewer;
        else if (c.lastCheckAt != 0 && block.timestamp < c.lastCheckAt + minCheckInterval) reason = SkipReason.TooSoon;
        else if (checkFee != 0 && IUserAccount(o.account).lockOf(orderId).checkBudget < checkFee) {
            reason = SkipReason.NoCheckBudget;
        } else {
            _checkOpen(orderId, o, c, m, price8, reportTimestamp, ePrice);
            return;
        }
        emit CheckSkipped(orderId, reason);
    }

    function _checkOpen(
        bytes32 orderId,
        SealedOrder storage o,
        CheckState storage c,
        MarketInfo memory m,
        uint256 price8,
        uint256 reportTimestamp,
        euint64 ePrice
    ) private {
        ebool fired = FHE.and(o.intakeValid, _crossed(o, ePrice));
        if (c.lastCheckAt != 0 && !_expired(c)) {
            // The previous check fired iff its revealed size is non-zero (sizes are at least minSizeUsd6 > 0).
            fired = FHE.or(fired, FHE.ne(c.revealedSize, FHE.asEuint64(0)));
        }
        if (o.kind == OrderKind.LimitIncrease) {
            uint256 collateralPrice8 = o.collateralToken == m.indexToken ? price8 : _price(o.collateralToken);
            uint64 maxSize = _maxSizeUsd6(o.collateral, collateralPrice8, _tokenDecimals(m, o.collateralToken));
            fired = FHE.and(fired, FHE.lte(o.sizeUsd6, FHE.asEuint64(maxSize)));
            c.collateralPrice8 = collateralPrice8;
        }

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

        if (checkFee != 0) {
            IUserAccount(o.account).payCheckFee(orderId, msg.sender, checkFee - checkFeeSpread, checkFeeSpread);
        }
    }

    /// @dev Limit entry and stop-loss fire at or below the trigger for a long, at or above for a short;
    ///      take-profit is the reverse. The kind is public, so only the side is selected on ciphertext.
    function _crossed(SealedOrder storage o, euint64 ePrice) private returns (ebool) {
        ebool below = FHE.lte(ePrice, o.triggerPrice8);
        ebool above = FHE.gte(ePrice, o.triggerPrice8);
        return o.kind == OrderKind.TakeProfit ? FHE.select(o.isLong, above, below) : FHE.select(o.isLong, below, above);
    }

    // ─── execute (design §4 step 5) ───────────────────────────────────────────

    /// @notice Publish the latest check's decryptions and, if the order fired, place it on GMX. Permissionless.
    /// @dev The signatures come from CoFHE's decryption service (`decryptForTx`); publishing verifies them.
    ///      All values are re-checked against the public, independent caps before any funds move.
    ///      Returns bytes32(0) if a stop-loss/take-profit fired but its position no longer exists (voided).
    function execute(
        bytes32 orderId,
        uint64 size,
        bytes calldata sizeSignature,
        bool isLong,
        bytes calldata isLongSignature,
        uint32 slippage,
        bytes calldata slippageSignature
    ) external nonReentrant returns (bytes32 gmxKey) {
        if (_orders[orderId].status != Status.Open) revert OrderNotOpen(orderId);
        CheckState storage c = _checks[orderId];
        if (c.lastCheckAt == 0) revert NotChecked(orderId);
        if (_expired(c)) revert CheckExpired(orderId, c.lastCheckAt + maxReportAge);

        FHE.publishDecryptResult(c.revealedSize, size, sizeSignature);
        FHE.publishDecryptResult(c.revealedIsLong, isLong, isLongSignature);
        FHE.publishDecryptResult(c.revealedSlippage, slippage, slippageSignature);
        if (size == 0) revert NotFired(orderId);

        SealedOrder storage o = _orders[orderId];
        if (size > maxSizeUsd6 || slippage > maxSlippageBps) revert ExceedsIndependentCaps(orderId);
        if (
            o.kind == OrderKind.LimitIncrease
                && size > _maxSizeUsd6(o.collateral, c.collateralPrice8, _tokenDecimals(_markets[o.market], o.collateralToken))
        ) {
            revert ExceedsIndependentCaps(orderId);
        }

        Fill storage f = _fills[orderId];
        f.size6 = size;
        f.isLong = isLong;
        f.slippage = slippage;
        o.status = Status.Fired;
        gmxKey = _submit(orderId, o, f, c.checkPrice8, slippage);
        if (gmxKey != bytes32(0)) {
            emit OrderFired(orderId, gmxKey, f.sizeDeltaUsd, isLong, f.acceptablePrice, f.protocolFee);
        }
    }

    // ─── re-arm (design D4) ───────────────────────────────────────────────────

    /// @notice Re-submit a fired order once after GMX cancelled it (e.g. slippage). Permissionless.
    /// @dev Uses the price the order fired at, with the wider of the user's public fallback slippage and their
    ///      sealed slippage, and re-runs the execute-time checks (live-position trim for decreases). Not allowed
    ///      if the owner cancelled the GMX order themselves, or once the fired check has expired.
    function rearm(bytes32 orderId) external nonReentrant returns (bytes32 gmxKey) {
        SealedOrder storage o = _orders[orderId];
        Fill storage f = _fills[orderId];
        if (o.status != Status.Fired || f.rearmed || !_gmxCancelled(o.account, orderId)) revert NotRearmable(orderId);
        if (IUserAccount(o.account).cancelledByOwner(orderId)) revert NotRearmable(orderId);
        CheckState storage c = _checks[orderId];
        if (_expired(c)) revert CheckExpired(orderId, c.lastCheckAt + maxReportAge);

        f.rearmed = true;
        uint32 slippage = o.fallbackSlippageBps > f.slippage ? o.fallbackSlippageBps : f.slippage;
        gmxKey = _submit(orderId, o, f, c.checkPrice8, slippage);
        if (gmxKey != bytes32(0)) emit OrderRearmed(orderId, gmxKey, f.sizeDeltaUsd, f.acceptablePrice);
    }

    // ─── settle (design §4 step 7, fee-model.md) ──────────────────────────────

    /// @notice After GMX reports the fill: pay the protocol fee and free the rest of the lock. Permissionless.
    function settle(bytes32 orderId) external nonReentrant {
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

    function orderOf(bytes32 orderId) external view returns (SealedOrder memory) {
        return _orders[orderId];
    }

    function checkOf(bytes32 orderId) external view returns (CheckState memory) {
        return _checks[orderId];
    }

    function fillOf(bytes32 orderId) external view returns (Fill memory) {
        return _fills[orderId];
    }

    function marketOf(address market) external view returns (MarketInfo memory) {
        return _markets[market];
    }

    function isSupportedMarket(address market) external view returns (bool) {
        return _markets[market].indexToken != address(0);
    }

    function accountOf(address owner) external view returns (address) {
        return factory.accountOf(owner);
    }

    /// @notice Protocol-fee reserve for a limit entry: the fee on the largest position this collateral allows.
    /// @dev Sized from public values only, so the reserve reveals nothing about the sealed size (fee-model.md).
    function maxProtocolFee(uint256 collateral) public view returns (uint256) {
        return collateral * maxLeverage * increaseFeeBps / BPS;
    }

    // ─── internal ─────────────────────────────────────────────────────────────

    /// @dev Builds the GMX request from plaintext terms and submits it through the account. For a decrease,
    ///      the size is trimmed to the live position (GMX rejects oversized market decreases), and if the
    ///      position is gone the order is voided and its funds released.
    function _submit(bytes32 orderId, SealedOrder storage o, Fill storage f, uint256 price8, uint32 slippage)
        private
        returns (bytes32 gmxKey)
    {
        bool increase = o.kind == OrderKind.LimitIncrease;
        uint256 sizeDeltaUsd = uint256(f.size6) * SIZE_TO_GMX;
        if (!increase) {
            uint256 position = IUserAccount(o.account).positionSizeUsd(o.market, o.collateralToken, f.isLong);
            if (position == 0) {
                _close(orderId, o);
                emit OrderVoided(orderId);
                return bytes32(0);
            }
            if (sizeDeltaUsd > position) sizeDeltaUsd = position;
        }

        f.sizeDeltaUsd = sizeDeltaUsd;
        uint256 expected = _expectedExecutionPrice(o, f.isLong, increase, sizeDeltaUsd, price8);
        f.acceptablePrice = _withSlippage(expected, slippage, f.isLong == increase);
        f.protocolFee = increase ? _increaseFee(orderId, o, f.size6) : decreaseFeeFlat;

        gmxKey = IUserAccount(o.account).submit(
            orderId,
            IUserAccount.OrderRequest({
                market: o.market,
                collateralToken: o.collateralToken,
                isLong: f.isLong,
                isIncrease: increase,
                sizeDeltaUsd: sizeDeltaUsd,
                collateralDelta: o.collateral,
                acceptablePrice: f.acceptablePrice,
                callbackGasLimit: callbackGasLimit
            })
        );
        f.gmxKey = gmxKey;
    }

    /// @dev increaseFeeBps of the size, in collateral-token units at the check's collateral price.
    function _increaseFee(bytes32 orderId, SealedOrder storage o, uint64 size6) private view returns (uint256) {
        uint256 feeUsd6 = uint256(size6) * increaseFeeBps / BPS;
        uint8 decimals = _tokenDecimals(_markets[o.market], o.collateralToken);
        return feeUsd6 * 10 ** (uint256(decimals) + 2) / _checks[orderId].collateralPrice8;
    }

    function _close(bytes32 orderId, SealedOrder storage o) private {
        o.status = Status.Cancelled;
        IUserAccount(o.account).release(orderId);
    }

    /// @dev Price-independent caps only. The leverage cap needs a price and is applied in each trigger check.
    function _intakeCaps(euint64 size, euint64 trigger, euint32 slippage) private returns (ebool valid) {
        valid = FHE.and(FHE.gte(size, FHE.asEuint64(minSizeUsd6)), FHE.lte(size, FHE.asEuint64(maxSizeUsd6)));
        valid = FHE.and(valid, FHE.lte(slippage, FHE.asEuint32(maxSlippageBps)));
        valid = FHE.and(valid, FHE.gt(trigger, FHE.asEuint64(0)));
    }

    /// @dev Largest size (USD, 6 decimals) the collateral supports at `price8`, capped to uint64.
    ///      amount / 10^decimals * price8 / 1e8 * 1e6 = amount * price8 / 10^(decimals + 2)
    function _maxSizeUsd6(uint256 collateral, uint256 price8, uint8 decimals) private view returns (uint64) {
        uint256 maxSize = collateral * price8 / 10 ** (uint256(decimals) + 2) * maxLeverage;
        return maxSize > type(uint64).max ? type(uint64).max : uint64(maxSize);
    }

    /// @dev price8 (USD per whole token) -> GMX price per smallest unit, 30 decimals: price8 * 10^(22 - decimals)
    function _toGmxPrice(uint256 price8, uint8 decimals) private pure returns (uint256) {
        return price8 * 10 ** (22 - uint256(decimals));
    }

    function _price(address token) private returns (uint256 price8) {
        (price8,) = priceVerifier.price(token, "");
    }

    function _tokenDecimals(MarketInfo memory m, address token) private pure returns (uint8) {
        if (token == m.indexToken) return m.indexDecimals;
        return token == m.longToken ? m.longDecimals : m.shortDecimals;
    }

    /// @dev WNT is handled as native ETH (18 decimals) and needn't expose `decimals()`.
    function _decimals(address token) private view returns (uint8 d) {
        d = token == wnt ? 18 : IERC20Metadata(token).decimals();
        if (d > 22) revert UnsupportedDecimals(token, d);
    }

    struct PositionState {
        uint256 sizeInUsd;
        uint256 sizeInTokens;
        int256 pendingImpactAmount;
    }

    /// @dev GMX's own estimate of the execution price (per wei, 30 - 18 decimals) for this order at `price8`,
    ///      including the market's price impact: the same calculation GMX validates `acceptablePrice` against.
    function _expectedExecutionPrice(
        SealedOrder storage o,
        bool isLong,
        bool increase,
        uint256 sizeDeltaUsd,
        uint256 price8
    ) private returns (uint256) {
        PositionState memory pos = _positionState(o.account, o.market, o.collateralToken, isLong);
        return gmxReader.getExecutionPrice(
            gmxDataStore,
            o.market,
            _marketPrices(_markets[o.market], price8),
            pos.sizeInUsd,
            pos.sizeInTokens,
            increase ? int256(sizeDeltaUsd) : -int256(sizeDeltaUsd),
            pos.pendingImpactAmount,
            isLong
        ).executionPrice;
    }

    function _positionState(address account, address market, address collateralToken, bool isLong)
        private
        view
        returns (PositionState memory pos)
    {
        bytes32 key = keccak256(abi.encode(account, market, collateralToken, isLong));
        IGmxDataStoreRead ds = IGmxDataStoreRead(gmxDataStore);
        pos.sizeInUsd = ds.getUint(keccak256(abi.encode(key, SIZE_IN_USD)));
        pos.sizeInTokens = ds.getUint(keccak256(abi.encode(key, SIZE_IN_TOKENS)));
        pos.pendingImpactAmount = ds.getInt(keccak256(abi.encode(key, PENDING_IMPACT_AMOUNT)));
    }

    /// @dev Index at the check price; long and short tokens at their verified prices (reusing the index price
    ///      when a pool token is the index token).
    function _marketPrices(MarketInfo memory m, uint256 indexPrice8) private returns (GmxPricing.MarketPrices memory) {
        uint256 index = _toGmxPrice(indexPrice8, m.indexDecimals);
        uint256 long = _toGmxPrice(m.longToken == m.indexToken ? indexPrice8 : _price(m.longToken), m.longDecimals);
        uint256 short = _toGmxPrice(m.shortToken == m.indexToken ? indexPrice8 : _price(m.shortToken), m.shortDecimals);
        return GmxPricing.MarketPrices({
            indexTokenPrice: GmxPricing.Price(index, index),
            longTokenPrice: GmxPricing.Price(long, long),
            shortTokenPrice: GmxPricing.Price(short, short)
        });
    }

    /// @dev When buying (long increase, short decrease) the acceptable price is the highest accepted;
    ///      when selling (short increase, long decrease) the lowest.
    function _withSlippage(uint256 price, uint32 slippage, bool buying) private pure returns (uint256) {
        return buying ? price * (BPS + slippage) / BPS : price * (BPS - slippage) / BPS;
    }

    function _gmxCancelled(address account, bytes32 orderId) private view returns (bool) {
        (IUserAccount.GmxOutcome outcome,) = IUserAccount(account).outcomeOf(orderId);
        return outcome == IUserAccount.GmxOutcome.Cancelled;
    }

    /// @dev A check's price stays usable for `maxReportAge` after the check; after that it is too stale to
    ///      anchor an acceptable price, and the order must fire again on a fresh check.
    function _expired(CheckState storage c) private view returns (bool) {
        return block.timestamp > c.lastCheckAt + maxReportAge;
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
