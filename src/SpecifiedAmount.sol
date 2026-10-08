// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @notice Read-only specified-side fill calculation using v4's exact integer swap math.
/// @dev Needed because afterSwap cannot refund a specified-currency beforeSwap delta.
/// No token calls, state changes, external quoter, or caller-controlled hook data.
library SpecifiedAmount {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    function filled(IPoolManager manager, PoolKey calldata key, SwapParams memory params)
        internal
        view
        returns (uint256)
    {
        PoolId id = key.toId();
        (uint160 price, int24 tick, uint24 protocol, uint24 lp) = manager.getSlot0(id);
        // Invalid limits are left to the manager's native validation; do not walk the wrong direction.
        if (params.zeroForOne ? params.sqrtPriceLimitX96 >= price : params.sqrtPriceLimitX96 <= price) {
            return 0;
        }
        if (
            params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE
                || params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE
        ) return 0;
        uint16 directional = params.zeroForOne ? protocol.getZeroForOneFee() : protocol.getOneForZeroFee();
        uint24 fee = directional.calculateSwapFee(lp);
        uint128 liquidity = manager.getLiquidity(id);
        int256 remaining = params.amountSpecified;
        bool exactIn = remaining < 0;
        while (remaining != 0 && price != params.sqrtPriceLimitX96) {
            (int24 next, bool initialized) = nextTick(manager, id, tick, key.tickSpacing, params.zeroForOne);
            if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            uint160 boundary = TickMath.getSqrtPriceAtTick(next);
            uint160 target =
                SwapMath.getSqrtPriceTarget(params.zeroForOne, boundary, params.sqrtPriceLimitX96);
            uint256 input;
            uint256 output;
            uint256 lpAmount;
            (price, input, output, lpAmount) =
                SwapMath.computeSwapStep(price, target, liquidity, remaining, fee);
            // Same bounds as v4 SwapMath: a step never consumes more than the remaining specification.
            unchecked {
                remaining = exactIn ? remaining + int256(input + lpAmount) : remaining - int256(output);
            }
            if (price == boundary) {
                if (initialized) {
                    (, int128 net) = manager.getTickLiquidity(id, next);
                    liquidity = LiquidityMath.addDelta(liquidity, params.zeroForOne ? -net : net);
                }
                tick = params.zeroForOne ? next - 1 : next;
            } else if (remaining != 0 && price != params.sqrtPriceLimitX96) {
                tick = TickMath.getTickAtSqrtPrice(price);
            }
        }
        unchecked {
            return exactIn
                ? uint256(remaining - params.amountSpecified)
                : uint256(params.amountSpecified - remaining);
        }
    }

    function nextTick(IPoolManager manager, PoolId id, int24 tick, int24 spacing, bool left)
        private
        view
        returns (int24 next, bool initialized)
    {
        int24 compressed = TickBitmap.compress(tick, spacing);
        if (!left) ++compressed;
        (int16 word, uint8 bit) = TickBitmap.position(compressed);
        uint256 bitmap = manager.getTickBitmap(id, word);
        uint256 masked =
            left ? bitmap & (type(uint256).max >> (255 - bit)) : bitmap & (type(uint256).max << bit);
        initialized = masked != 0;
        int24 offset;
        if (left) {
            offset =
                initialized ? int24(uint24(bit - BitMath.mostSignificantBit(masked))) : int24(uint24(bit));
            next = (compressed - offset) * spacing;
        } else {
            offset = initialized
                ? int24(uint24(BitMath.leastSignificantBit(masked) - bit))
                : int24(uint24(255 - bit));
            next = (compressed + offset) * spacing;
        }
    }
}
