// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ParallaxMath } from "./ParallaxMath.sol";

/// @title ParallaxReactive
/// @notice The brain of Parallax, deployed on Reactive Network (Lasna testnet).
///
///         One asset, two chains, two prices. Parallax keeps a live mirror of a pool on Unichain Sepolia
///         ("venue A") and a pool on Base Sepolia ("venue B") by reacting to every `Sync` they emit.
///         The moment the gap between them is wide enough to pay for both swap fees, it:
///           1. computes the profit-maximising trade size in closed form,
///           2. fires two callbacks in the same reactive transaction - BUY on the cheap chain,
///              SELL on the expensive chain - each with its own slippage floor and deadline,
///           3. locks itself until both legs report back (LegExecuted / LegSkipped events from the executors),
///           4. books realised PnL, unlocks, and immediately re-checks the spread (chained arbs).
///
///         With Omni's ~1 s blocks + instant finality the whole loop closes in seconds - the gap is gone
///         before a polling bot would have seen it.
contract ParallaxReactive is AbstractReactive {
    // ------------------------------------------------------------------ constants

    /// @dev Uniswap V2 Sync(uint112,uint112) = 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1
    uint256 public constant SYNC_TOPIC_0 = uint256(keccak256("Sync(uint112,uint112)"));
    uint256 public constant LEG_EXECUTED_TOPIC_0 = uint256(keccak256("LegExecuted(uint256,bool,uint256,uint256)"));
    uint256 public constant LEG_SKIPPED_TOPIC_0 = uint256(keccak256("LegSkipped(uint256,uint8)"));

    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000; // 10%
    /// @notice Circuit breaker: this many partially-filled arbs in a row pauses the engine.
    uint8 public constant MAX_CONSECUTIVE_PARTIAL_FILLS = 2;

    uint8 public constant VENUE_A = 0;
    uint8 public constant VENUE_B = 1;

    // ------------------------------------------------------------------ types

    struct Venue {
        uint256 chainId;
        address pool;
        address executor;
        bool baseIsToken0;
        uint256 reserveBase;
        uint256 reserveQuote;
        uint256 updatedAt; // Reactive block.timestamp of the last mirrored Sync
        uint256 updates;
    }

    struct Arb {
        uint8 cheapVenue; // venue where we BUY base
        uint8 legsMask; // bit0 = venue A reported, bit1 = venue B reported
        uint8 legsFailed;
        bool settled;
        uint256 quoteIn; // quote spent on the cheap venue
        uint256 baseAmount; // base bought on the cheap venue == base sold on the rich venue
        uint256 expectedQuoteOut;
        uint256 openedAt;
        int256 realizedQuote; // + quote received - quote spent
        int256 baseDrift; // + base received - base sold (inventory drift, ~0 when both legs fill)
    }

    // ------------------------------------------------------------------ state

    address public owner;
    bool public paused;

    Venue public venueA;
    Venue public venueB;

    /// @notice Minimum expected profit (quote units, 18 decimals) before an arb is fired.
    uint256 public minProfitQuote;
    /// @notice Cap on the quote spent per arb (risk limit; also bounded by executor inventory).
    uint256 public maxTradeQuote;
    /// @notice Slippage tolerance applied to each leg's expected output.
    uint256 public slippageBps;
    /// @notice Seconds a leg stays valid on the destination chain (timestamp deadline).
    uint256 public legTtl;
    /// @notice Seconds after which an un-settled arb no longer blocks new ones.
    uint256 public lockTimeout;

    mapping(uint256 => Arb) public arbs;
    uint256 public nextArbId = 1;
    uint256 public activeArbId;
    uint256 public lockedAt;

    uint256 public arbsOpened;
    uint256 public arbsSettled;
    uint256 public arbsFullyFilled;
    int256 public cumulativePnlQuote;
    uint8 public consecutivePartialFills;

    // ------------------------------------------------------------------ events

    event PriceObserved(
        uint8 indexed venue,
        uint256 reserveBase,
        uint256 reserveQuote,
        uint256 priceE18,
        uint256 spreadBps,
        uint256 originTxHash
    );
    event ArbOpened(
        uint256 indexed arbId,
        uint8 cheapVenue,
        uint8 triggerVenue,
        uint256 quoteIn,
        uint256 baseAmount,
        uint256 expectedQuoteOut,
        uint256 spreadBps,
        uint256 originTxHash
    );
    event LegConfirmed(
        uint256 indexed arbId, uint8 indexed venue, bool buyBase, uint256 amountIn, uint256 amountOut, uint256 legTxHash
    );
    event LegFailed(uint256 indexed arbId, uint8 indexed venue, uint8 reason, uint256 legTxHash);
    event ArbSettled(
        uint256 indexed arbId, int256 realizedQuote, int256 baseDrift, bool fullyFilled, uint256 secondsToSettle
    );
    event ArbExpired(uint256 indexed arbId);
    event ExecutorsConfigured(address executorA, address executorB);
    event ParamsUpdated(
        uint256 minProfitQuote, uint256 maxTradeQuote, uint256 slippageBps, uint256 legTtl, uint256 lockTimeout
    );
    event PausedSet(bool paused);
    event CircuitBreakerTripped(uint256 indexed arbId, uint8 consecutivePartialFills);

    // ------------------------------------------------------------------ errors

    error NotOwner();
    error InvalidParams();
    error AlreadyConfigured();
    error NativeTransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ------------------------------------------------------------------ constructor

    /// @dev Flat arguments (no structs) so `forge create --constructor-args` works out of the box.
    constructor(
        uint256 chainIdA_,
        address poolA_,
        bool baseIsToken0A_,
        uint256 chainIdB_,
        address poolB_,
        bool baseIsToken0B_,
        uint256 minProfitQuote_,
        uint256 maxTradeQuote_,
        uint256 slippageBps_,
        uint256 legTtl_,
        uint256 lockTimeout_
    ) payable {
        if (poolA_ == address(0) || poolB_ == address(0)) revert InvalidParams();
        if (chainIdA_ == chainIdB_ && poolA_ == poolB_) revert InvalidParams();
        owner = msg.sender;

        venueA.chainId = chainIdA_;
        venueA.pool = poolA_;
        venueA.baseIsToken0 = baseIsToken0A_;
        venueB.chainId = chainIdB_;
        venueB.pool = poolB_;
        venueB.baseIsToken0 = baseIsToken0B_;

        _setParams(minProfitQuote_, maxTradeQuote_, slippageBps_, legTtl_, lockTimeout_);

        // Mirror both markets: every reserve change on either chain lands in react().
        SYSTEM.subscribe(chainIdA_, poolA_, SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainIdB_, poolB_, SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    // ------------------------------------------------------------------ reactive entrypoint

    function react(LogRecord calldata log_) external onlySystem {
        uint256 topic0 = log_.topic0;

        if (topic0 == SYNC_TOPIC_0) {
            if (log_.chainId == venueA.chainId && log_.contractAddress == venueA.pool) {
                _onSync(VENUE_A, log_.data, log_.txHash);
            } else if (log_.chainId == venueB.chainId && log_.contractAddress == venueB.pool) {
                _onSync(VENUE_B, log_.data, log_.txHash);
            }
            return;
        }

        if (topic0 == LEG_EXECUTED_TOPIC_0 || topic0 == LEG_SKIPPED_TOPIC_0) {
            uint8 venue;
            if (log_.chainId == venueA.chainId && log_.contractAddress == venueA.executor && venueA.executor != address(0)) {
                venue = VENUE_A;
            } else if (
                log_.chainId == venueB.chainId && log_.contractAddress == venueB.executor && venueB.executor != address(0)
            ) {
                venue = VENUE_B;
            } else {
                return;
            }
            _onLeg(venue, topic0 == LEG_EXECUTED_TOPIC_0, log_.topic1, log_.data, log_.txHash);
        }
    }

    // ------------------------------------------------------------------ views

    /// @notice Current gap between the two mirrored prices, in basis points.
    function currentSpreadBps() public view returns (uint256) {
        return ParallaxMath.spreadBps(venueA.reserveBase, venueA.reserveQuote, venueB.reserveBase, venueB.reserveQuote);
    }

    /// @notice What Parallax would do right now: (cheapVenue, quoteIn, baseAmount, expectedQuoteOut, expectedProfit).
    ///         quoteIn == 0 means "no profitable trade".
    function previewArb()
        public
        view
        returns (uint8 cheapVenue, uint256 quoteIn, uint256 baseAmount, uint256 expectedQuoteOut, uint256 expectedProfit)
    {
        Venue storage a = venueA;
        Venue storage b = venueB;
        if (a.reserveBase == 0 || a.reserveQuote == 0 || b.reserveBase == 0 || b.reserveQuote == 0) {
            return (0, 0, 0, 0, 0);
        }

        // price = quote / base; A is cheaper  <=>  qA * bB < qB * bA
        uint256 pa = a.reserveQuote * b.reserveBase;
        uint256 pb = b.reserveQuote * a.reserveBase;
        if (pa == pb) return (0, 0, 0, 0, 0);

        Venue storage cheap = a;
        Venue storage rich = b;
        cheapVenue = VENUE_A;
        if (pb < pa) {
            cheap = b;
            rich = a;
            cheapVenue = VENUE_B;
        }

        // Round trip in quote: quote --cheap--> base --rich--> quote
        quoteIn = ParallaxMath.optimalArbInput(cheap.reserveQuote, cheap.reserveBase, rich.reserveBase, rich.reserveQuote);
        if (quoteIn == 0) return (cheapVenue, 0, 0, 0, 0);
        if (quoteIn > maxTradeQuote) quoteIn = maxTradeQuote;

        baseAmount = ParallaxMath.getAmountOut(quoteIn, cheap.reserveQuote, cheap.reserveBase);
        expectedQuoteOut = ParallaxMath.getAmountOut(baseAmount, rich.reserveBase, rich.reserveQuote);
        if (expectedQuoteOut <= quoteIn) return (cheapVenue, 0, 0, 0, 0);
        expectedProfit = expectedQuoteOut - quoteIn;
    }

    /// @notice True while an arb is in flight and has not timed out.
    function isLocked() public view returns (bool) {
        return activeArbId != 0 && block.timestamp < lockedAt + lockTimeout;
    }

    // ------------------------------------------------------------------ owner

    /// @notice Wire in the destination executors (they need this contract's address first, so this is step 2).
    ///         Also subscribes to their LegExecuted / LegSkipped events to close the feedback loop.
    function configureExecutors(address executorA_, address executorB_) external onlyOwner {
        if (venueA.executor != address(0) || venueB.executor != address(0)) revert AlreadyConfigured();
        if (executorA_ == address(0) || executorB_ == address(0)) revert InvalidParams();
        venueA.executor = executorA_;
        venueB.executor = executorB_;

        SYSTEM.subscribe(venueA.chainId, executorA_, LEG_EXECUTED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(venueA.chainId, executorA_, LEG_SKIPPED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(venueB.chainId, executorB_, LEG_EXECUTED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(venueB.chainId, executorB_, LEG_SKIPPED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);

        emit ExecutorsConfigured(executorA_, executorB_);
    }

    function setParams(
        uint256 minProfitQuote_,
        uint256 maxTradeQuote_,
        uint256 slippageBps_,
        uint256 legTtl_,
        uint256 lockTimeout_
    ) external onlyOwner {
        _setParams(minProfitQuote_, maxTradeQuote_, slippageBps_, legTtl_, lockTimeout_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        if (!paused_) consecutivePartialFills = 0;
        emit PausedSet(paused_);
    }

    /// @notice Manually release a stuck lock (normally it expires on its own after `lockTimeout`).
    function resetLock() external onlyOwner {
        if (activeArbId != 0) emit ArbExpired(activeArbId);
        activeArbId = 0;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidParams();
        owner = newOwner;
    }

    function withdrawNative(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
    }

    /// @notice Pay off any debt owed to the system contract for reactive execution.
    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------------ internals

    function _setParams(
        uint256 minProfitQuote_,
        uint256 maxTradeQuote_,
        uint256 slippageBps_,
        uint256 legTtl_,
        uint256 lockTimeout_
    ) private {
        if (maxTradeQuote_ == 0 || slippageBps_ > MAX_SLIPPAGE_BPS || legTtl_ == 0 || lockTimeout_ < legTtl_) {
            revert InvalidParams();
        }
        minProfitQuote = minProfitQuote_;
        maxTradeQuote = maxTradeQuote_;
        slippageBps = slippageBps_;
        legTtl = legTtl_;
        lockTimeout = lockTimeout_;
        emit ParamsUpdated(minProfitQuote_, maxTradeQuote_, slippageBps_, legTtl_, lockTimeout_);
    }

    function _venue(uint8 venue) private view returns (Venue storage) {
        return venue == VENUE_A ? venueA : venueB;
    }

    function _onSync(uint8 venue, bytes calldata data, uint256 txHash) private {
        (uint256 reserve0, uint256 reserve1) = abi.decode(data, (uint256, uint256));
        Venue storage v = _venue(venue);
        if (v.baseIsToken0) {
            v.reserveBase = reserve0;
            v.reserveQuote = reserve1;
        } else {
            v.reserveBase = reserve1;
            v.reserveQuote = reserve0;
        }
        v.updatedAt = block.timestamp;
        v.updates += 1;

        uint256 spread = currentSpreadBps();
        emit PriceObserved(
            venue, v.reserveBase, v.reserveQuote, ParallaxMath.priceE18(v.reserveBase, v.reserveQuote), spread, txHash
        );

        _evaluate(venue, spread, txHash);
    }

    function _evaluate(uint8 triggerVenue, uint256 spread, uint256 originTxHash) private {
        if (paused) return;
        if (venueA.executor == address(0) || venueB.executor == address(0)) return;

        if (activeArbId != 0) {
            if (block.timestamp < lockedAt + lockTimeout) return; // a trade is in flight
            emit ArbExpired(activeArbId);
            activeArbId = 0;
        }

        (uint8 cheapVenue, uint256 quoteIn, uint256 baseAmount, uint256 expectedQuoteOut, uint256 expectedProfit) =
            previewArb();
        if (quoteIn == 0 || expectedProfit < minProfitQuote) return;

        uint256 arbId = nextArbId++;
        Arb storage arb = arbs[arbId];
        arb.cheapVenue = cheapVenue;
        arb.quoteIn = quoteIn;
        arb.baseAmount = baseAmount;
        arb.expectedQuoteOut = expectedQuoteOut;
        arb.openedAt = block.timestamp;

        activeArbId = arbId;
        lockedAt = block.timestamp;
        arbsOpened += 1;

        uint256 deadline = block.timestamp + legTtl;
        uint256 keep = ParallaxMath.BPS - slippageBps;
        uint8 richVenue = cheapVenue == VENUE_A ? VENUE_B : VENUE_A;

        // Leg 1 - cheap chain: spend quote, buy base.
        _requestLeg(cheapVenue, arbId, true, quoteIn, (baseAmount * keep) / ParallaxMath.BPS, deadline);
        // Leg 2 - rich chain: sell the same amount of base (from inventory) for quote. Fired in the same tx.
        _requestLeg(richVenue, arbId, false, baseAmount, (expectedQuoteOut * keep) / ParallaxMath.BPS, deadline);

        emit ArbOpened(arbId, cheapVenue, triggerVenue, quoteIn, baseAmount, expectedQuoteOut, spread, originTxHash);
    }

    function _requestLeg(uint8 venue, uint256 arbId, bool buyBase, uint256 amountIn, uint256 minOut, uint256 deadline)
        private
    {
        Venue storage v = _venue(venue);
        bytes memory payload = abi.encodeWithSignature(
            "executeLeg(address,uint256,bool,uint256,uint256,uint256)",
            address(0), // overwritten by Reactive Network with this contract's address
            arbId,
            buyBase,
            amountIn,
            minOut,
            deadline
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: v.chainId,
                recipient: v.executor,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }

    function _onLeg(uint8 venue, bool executed, uint256 arbId, bytes calldata data, uint256 legTxHash) private {
        Arb storage arb = arbs[arbId];
        if (arb.openedAt == 0 || arb.settled) return;

        uint8 bit = uint8(1) << venue;
        if ((arb.legsMask & bit) != 0) return; // duplicate report
        arb.legsMask |= bit;

        if (executed) {
            (bool buyBase, uint256 amountIn, uint256 amountOut) = abi.decode(data, (bool, uint256, uint256));
            if (buyBase) {
                arb.realizedQuote -= int256(amountIn);
                arb.baseDrift += int256(amountOut);
            } else {
                arb.realizedQuote += int256(amountOut);
                arb.baseDrift -= int256(amountIn);
            }
            emit LegConfirmed(arbId, venue, buyBase, amountIn, amountOut, legTxHash);
        } else {
            uint8 reason = abi.decode(data, (uint8));
            arb.legsFailed += 1;
            emit LegFailed(arbId, venue, reason, legTxHash);
        }

        if (arb.legsMask == 3) {
            _settle(arbId, arb);
            // Re-check immediately: if a capped trade left a gap, the next arb fires in this same transaction.
            _evaluate(venue, currentSpreadBps(), legTxHash);
        }
    }

    function _settle(uint256 arbId, Arb storage arb) private {
        arb.settled = true;
        arbsSettled += 1;
        bool fullyFilled = arb.legsFailed == 0;
        if (activeArbId == arbId) activeArbId = 0;
        emit ArbSettled(arbId, arb.realizedQuote, arb.baseDrift, fullyFilled, block.timestamp - arb.openedAt);

        if (fullyFilled) {
            arbsFullyFilled += 1;
            cumulativePnlQuote += arb.realizedQuote;
            consecutivePartialFills = 0;
        } else {
            // One leg filled, the other didn't -> we now carry directional inventory risk.
            // Allow one retry (the gap is usually still there), then stop and wait for a human.
            consecutivePartialFills += 1;
            if (consecutivePartialFills >= MAX_CONSECUTIVE_PARTIAL_FILLS) {
                paused = true;
                emit CircuitBreakerTripped(arbId, consecutivePartialFills);
                emit PausedSet(true);
            }
        }
    }
}
