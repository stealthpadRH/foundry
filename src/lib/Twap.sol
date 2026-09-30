// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {FullMath} from "./FullMath.sol";
import {TickMath} from "./TickMath.sol";

/// The pool's own time-weighted price, the guard on every swap a round makes.
library Twap {
    uint32 internal constant WINDOW = 30 minutes;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 2 ** 96;

    /// Quote raw units per 1e18 base raw units, from a sqrt price, for the base side of a pool.
    function ratioWad(uint160 sqrtPriceX96, bool baseIsToken0) internal pure returns (uint256) {
        if (baseIsToken0) return FullMath.mulDiv(FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96), WAD, Q96);
        return FullMath.mulDiv(FullMath.mulDiv(WAD, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }

    /// Time-weighted mean tick over the last WINDOW seconds, with Uniswap's rounding toward -inf.
    function meanTick(address pool) internal view returns (int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = WINDOW;
        ago[1] = 0;
        (int56[] memory cum,) = IUniswapV3Pool(pool).observe(ago);
        int56 delta = cum[1] - cum[0];
        tick = int24(delta / int56(uint56(WINDOW)));
        if (delta < 0 && (delta % int56(uint56(WINDOW)) != 0)) tick--;
    }

    /// Quote raw units per 1e18 base raw units at the WINDOW mean.
    function price(address pool, bool baseIsToken0) internal view returns (uint256) {
        return ratioWad(TickMath.getSqrtRatioAtTick(meanTick(pool)), baseIsToken0);
    }
}
