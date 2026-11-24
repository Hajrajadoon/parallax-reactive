// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Constant-product pool used on each origin chain. It emits the exact Uniswap V2
///         `Sync(uint112,uint112)` event, so the reactive contract works unchanged with real V2 pairs.
interface IParallaxPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function quoteExactIn(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut);
    function addLiquidity(uint256 amount0, uint256 amount1) external;
}
