// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IERC20Minimal } from "./interfaces/IERC20Minimal.sol";
import { IParallaxPair } from "./interfaces/IParallaxPair.sol";

/// @title ParallaxExecutor
/// @notice Destination-side callback contract, one per chain. Holds trading inventory (base + quote) and
///         executes one leg of a cross-chain arbitrage when the Parallax reactive contract tells it to.
/// @dev Safety rails, all enforced on the destination chain at execution time:
///      - only the Reactive callback proxy may call, and only on behalf of OUR reactive contract;
///      - each arbId executes at most once (replay protection);
///      - deadline + cooldown use block.timestamp, never block numbers (Base Sepolia = 200 ms blocks);
///      - live re-quote against the pool; if the price moved beyond minOut the leg is skipped, not forced.
///      A leg that cannot run emits `LegSkipped` instead of reverting: a reverted callback is still billed and
///      tells the reactive contract nothing, while a skip event is observed by it and releases the lock.
contract ParallaxExecutor is AbstractCallback {
    enum SkipReason {
        None,
        Paused,
        Expired,
        Cooldown,
        InsufficientInventory,
        PriceMoved,
        SwapFailed,
        Duplicate
    }

    IParallaxPair public immutable pool;
    IERC20Minimal public immutable baseToken;
    IERC20Minimal public immutable quoteToken;

    address public owner;
    bool public paused;
    /// @notice Minimum seconds between two executed legs (timestamp based).
    uint256 public cooldown;
    uint256 public lastExecutedAt;
    uint256 public legsExecuted;
    uint256 public legsSkipped;

    mapping(uint256 => bool) public handled;

    /// @dev topic0 = keccak256("LegExecuted(uint256,bool,uint256,uint256)") - watched by ParallaxReactive
    event LegExecuted(uint256 indexed arbId, bool buyBase, uint256 amountIn, uint256 amountOut);
    /// @dev topic0 = keccak256("LegSkipped(uint256,uint8)") - watched by ParallaxReactive
    event LegSkipped(uint256 indexed arbId, uint8 reason);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PausedSet(bool paused);
    event CooldownSet(uint256 cooldown);

    error NotOwner();
    error InvalidAddress();
    error NativeTransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param callbackProxy_ Reactive callback proxy on this chain (Base Sepolia 0x476F44b1..., Unichain Sepolia 0x775c9B99...)
    /// @param reactive_      ParallaxReactive contract address on Reactive Lasna - the only authorised sender
    /// @param pool_          ParallaxPair (or any pool implementing IParallaxPair) on this chain
    /// @param baseToken_     asset being arbitraged (e.g. pWETH)
    /// @param quoteToken_    pricing asset (e.g. pUSD)
    /// @param cooldown_      seconds between executions
    constructor(
        IPayable callbackProxy_,
        address reactive_,
        address pool_,
        address baseToken_,
        address quoteToken_,
        uint256 cooldown_
    ) payable AbstractCallback(callbackProxy_, reactive_) {
        if (pool_ == address(0) || baseToken_ == address(0) || quoteToken_ == address(0)) revert InvalidAddress();
        pool = IParallaxPair(pool_);
        baseToken = IERC20Minimal(baseToken_);
        quoteToken = IERC20Minimal(quoteToken_);
        cooldown = cooldown_;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        IERC20Minimal(baseToken_).approve(pool_, type(uint256).max);
        IERC20Minimal(quoteToken_).approve(pool_, type(uint256).max);
    }

    /// @notice Called by the Reactive callback proxy. The first argument is overwritten by the network with the
    ///         address of the reactive contract that requested the callback.
    /// @param buyBase  true  = spend quote, receive base (cheap venue)
    ///                 false = spend base, receive quote (expensive venue)
    function executeLeg(
        address reactive_,
        uint256 arbId,
        bool buyBase,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        if (handled[arbId]) {
            _skip(arbId, SkipReason.Duplicate);
            return;
        }
        handled[arbId] = true;

        if (paused) {
            _skip(arbId, SkipReason.Paused);
            return;
        }
        if (block.timestamp > deadline) {
            _skip(arbId, SkipReason.Expired);
            return;
        }
        if (lastExecutedAt != 0 && block.timestamp < lastExecutedAt + cooldown) {
            _skip(arbId, SkipReason.Cooldown);
            return;
        }

        IERC20Minimal tokenIn = buyBase ? quoteToken : baseToken;
        if (tokenIn.balanceOf(address(this)) < amountIn) {
            _skip(arbId, SkipReason.InsufficientInventory);
            return;
        }

        // Re-quote on the live pool: the reactive contract priced this leg from mirrored reserves.
        if (pool.quoteExactIn(address(tokenIn), amountIn) < minAmountOut) {
            _skip(arbId, SkipReason.PriceMoved);
            return;
        }

        try pool.swapExactIn(address(tokenIn), amountIn, minAmountOut, address(this)) returns (uint256 amountOut) {
            lastExecutedAt = block.timestamp;
            legsExecuted += 1;
            emit LegExecuted(arbId, buyBase, amountIn, amountOut);
        } catch {
            _skip(arbId, SkipReason.SwapFailed);
        }
    }

    // ------------------------------------------------------------------ views

    function inventory() external view returns (uint256 base, uint256 quote, uint256 nativeBalance) {
        return (baseToken.balanceOf(address(this)), quoteToken.balanceOf(address(this)), address(this).balance);
    }

    // ------------------------------------------------------------------ owner

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setCooldown(uint256 cooldown_) external onlyOwner {
        cooldown = cooldown_;
        emit CooldownSet(cooldown_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        IERC20Minimal(token).transfer(to, amount);
    }

    function withdrawNative(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
    }

    /// @notice Settle any outstanding callback debt with the proxy (needed if the balance ever ran dry).
    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------------ internals

    function _skip(uint256 arbId, SkipReason reason) private {
        legsSkipped += 1;
        emit LegSkipped(arbId, uint8(reason));
    }
}
