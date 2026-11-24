// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title ParallaxMath
/// @notice Constant-product AMM math plus the closed-form optimal size for a two-pool arbitrage.
/// @dev All reserves are bounded by uint112 (as in Uniswap V2), so every product below fits in uint256:
///      (2^112)^2 * 1000 < 2^235.
library ParallaxMath {
    uint256 internal constant FEE_NUM = 997; // 0.30% LP fee, same as Uniswap V2
    uint256 internal constant FEE_DEN = 1000;
    uint256 internal constant BPS = 10_000;

    /// @notice Uniswap V2 `getAmountOut`.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = amountIn * FEE_NUM;
        return (amountInWithFee * reserveOut) / (reserveIn * FEE_DEN + amountInWithFee);
    }

    /// @notice Profit-maximising input for the round trip  X --pool1--> Y --pool2--> X.
    /// @param in1  pool1 reserve of the token we put in (X)
    /// @param out1 pool1 reserve of the token we take out (Y)
    /// @param in2  pool2 reserve of Y (we put Y in)
    /// @param out2 pool2 reserve of X (we take X out)
    /// @return amountIn optimal amount of X to send into pool1 (0 when no profitable trade exists)
    /// @dev Two chained constant-product pools behave like one virtual pool with reserves (e0, e1):
    ///        e0 = in1*in2 / (in2 + g*out1),   e1 = g*out1*out2 / (in2 + g*out1),   g = 997/1000
    ///      Profit(dx) = g*e1*dx/(e0 + g*dx) - dx is concave and peaks at
    ///        dx* = (sqrt(g*e0*e1) - e0) / g
    function optimalArbInput(uint256 in1, uint256 out1, uint256 in2, uint256 out2)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (in1 == 0 || out1 == 0 || in2 == 0 || out2 == 0) return 0;
        uint256 denom = in2 * FEE_DEN + out1 * FEE_NUM;
        uint256 e0 = (in1 * in2 * FEE_DEN) / denom;
        uint256 e1 = (out1 * out2 * FEE_NUM) / denom;
        // Marginal profit at dx = 0 is positive only if g*e1 > e0.
        if (e1 * FEE_NUM <= e0 * FEE_DEN) return 0;
        uint256 root = sqrt((e0 * e1 * FEE_NUM) / FEE_DEN);
        if (root <= e0) return 0;
        amountIn = ((root - e0) * FEE_DEN) / FEE_NUM;
    }

    /// @notice Price gap between two pools in basis points of the cheaper price.
    /// @dev price = quote/base. Compared by cross-multiplication, so no precision is lost.
    function spreadBps(uint256 baseA, uint256 quoteA, uint256 baseB, uint256 quoteB) internal pure returns (uint256) {
        if (baseA == 0 || quoteA == 0 || baseB == 0 || quoteB == 0) return 0;
        uint256 pa = quoteA * baseB; // ~ priceA * baseA * baseB
        uint256 pb = quoteB * baseA; // ~ priceB * baseA * baseB
        if (pa == pb) return 0;
        return pa > pb ? ((pa - pb) * BPS) / pb : ((pb - pa) * BPS) / pa;
    }

    /// @notice Price of base in quote, 18-decimal fixed point.
    function priceE18(uint256 reserveBase, uint256 reserveQuote) internal pure returns (uint256) {
        if (reserveBase == 0) return 0;
        return (reserveQuote * 1e18) / reserveBase;
    }

    /// @notice Babylonian integer square root (floor).
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
