// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20Minimal } from "../interfaces/IERC20Minimal.sol";
import { IParallaxPair } from "../interfaces/IParallaxPair.sol";
import { ParallaxMath } from "../ParallaxMath.sol";

/// @title ParallaxPair
/// @notice Small constant-product AMM (0.30% fee) deployed once per origin chain.
/// @dev Emits Uniswap V2's `Sync(uint112,uint112)` after every reserve change - that event is
///      what the reactive contract subscribes to. Liquidity is one-way (no LP token) because this
///      pool exists only to give the demo a real, independently priced market on each chain.
contract ParallaxPair is IParallaxPair {
    address public immutable override token0;
    address public immutable override token1;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    uint256 private _unlocked = 1;

    /// @dev Identical signature to Uniswap V2 -> topic0 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1
    event Sync(uint112 reserve0, uint112 reserve1);
    event Swap(
        address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to
    );
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1);

    error Locked();
    error InvalidToken();
    error ZeroAmount();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error InsufficientLiquidity();
    error Overflow();
    error TransferFailed_();

    modifier lock() {
        if (_unlocked != 1) revert Locked();
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    constructor(address token0_, address token1_) {
        if (token0_ == address(0) || token1_ == address(0) || token0_ == token1_) revert InvalidToken();
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() public view override returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    function quoteExactIn(address tokenIn, uint256 amountIn) public view override returns (uint256) {
        (uint256 rIn, uint256 rOut) = _orientedReserves(tokenIn);
        return ParallaxMath.getAmountOut(amountIn, rIn, rOut);
    }

    function addLiquidity(uint256 amount0, uint256 amount1) external override lock {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        _safeTransferFrom(token0, msg.sender, address(this), amount0);
        _safeTransferFrom(token1, msg.sender, address(this), amount1);
        _sync();
        emit LiquidityAdded(msg.sender, amount0, amount1);
    }

    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        override
        lock
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        (uint256 rIn, uint256 rOut) = _orientedReserves(tokenIn);
        if (rIn == 0 || rOut == 0) revert InsufficientLiquidity();

        amountOut = ParallaxMath.getAmountOut(amountIn, rIn, rOut);
        if (amountOut < minAmountOut || amountOut == 0) revert InsufficientOutput(amountOut, minAmountOut);

        address tokenOut = tokenIn == token0 ? token1 : token0;
        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        _safeTransfer(tokenOut, to, amountOut);
        _sync();
        emit Swap(msg.sender, tokenIn, amountIn, amountOut, to);
    }

    // ------------------------------------------------------------------ internals

    function _orientedReserves(address tokenIn) private view returns (uint256 rIn, uint256 rOut) {
        if (tokenIn == token0) return (_reserve0, _reserve1);
        if (tokenIn == token1) return (_reserve1, _reserve0);
        revert InvalidToken();
    }

    function _sync() private {
        uint256 b0 = IERC20Minimal(token0).balanceOf(address(this));
        uint256 b1 = IERC20Minimal(token1).balanceOf(address(this));
        if (b0 > type(uint112).max || b1 > type(uint112).max) revert Overflow();
        _reserve0 = uint112(b0);
        _reserve1 = uint112(b1);
        _blockTimestampLast = uint32(block.timestamp);
        emit Sync(uint112(b0), uint112(b1));
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed_();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed_();
    }
}
