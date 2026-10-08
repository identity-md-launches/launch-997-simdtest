// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SpecifiedAmount} from "../src/SpecifiedAmount.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev The library takes the key as calldata; an external wrapper gives the tests that.
contract QuoteProbe {
    function filled(IPoolManager manager, PoolKey calldata key, SwapParams memory params)
        external
        view
        returns (uint256)
    {
        return SpecifiedAmount.filled(manager, key, params);
    }
}

/// @notice The hook's read-only fill quote must agree with the manager to the wei: when IMD is the
/// specified currency the hook charges on this number, and afterSwap cannot correct it. Compared on a
/// hookless pool so the manager's own answer is the oracle, over random liquidity shapes, gaps,
/// protocol fees, directions, exactness, limits and amounts up to and beyond what the pool holds.
contract SpecifiedAmountTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant Q96 = 79228162514264337593543950336;
    IPoolManager manager;
    TestRouter router;
    QuoteProbe probe;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;

    function setUp() public {
        manager = new PoolManager(address(this));
        router = new TestRouter(manager);
        probe = new QuoteProbe();
        MockERC20 a = new MockERC20("A", "A", 1e32);
        MockERC20 b = new MockERC20("B", "B", 1e32);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        key = PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 12500, 60, IHooks(address(0))
        );
        manager.setProtocolFeeController(address(this));
    }

    function shape(uint256 seed, uint256 count) internal {
        for (uint256 i; i < count; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            int24 lower = int24(int256((r % 200))) * 60 - 6000;
            int24 upper = lower + int24(int256(((r >> 32) % 60) + 1)) * 60;
            uint256 liquidity = 1e15 + ((r >> 64) % 1e24);
            router.liquidity(key, ModifyLiquidityParams(lower, upper, int256(liquidity), bytes32(i + 1)));
        }
    }

    function specifiedOf(BalanceDelta d, bool zeroForOne, bool exactIn) internal pure returns (uint256) {
        int256 s = zeroForOne == exactIn ? int256(d.amount0()) : int256(d.amount1());
        return uint256(s < 0 ? -s : s);
    }

    /// forge-config: default.fuzz.runs = 1500
    function testFuzzQuoteEqualsManagerFill(
        uint256 seed,
        uint8 positions,
        bool zeroForOne,
        bool exactIn,
        uint96 rawAmount,
        uint16 limitTicks,
        bool useLimit,
        uint16 protocolZero,
        uint16 protocolOne,
        int16 startTick
    ) public {
        int24 start = int24(bound(int256(startTick), -5000, 5000));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(start));
        shape(seed, bound(positions, 0, 8));
        uint24 protocolFee = uint24(bound(protocolZero, 0, 1000) | (bound(protocolOne, 0, 1000) << 12));
        if (protocolFee != 0) manager.setProtocolFee(key, protocolFee);
        uint256 amount = bound(rawAmount, 1, 1e24);
        uint160 limit;
        if (useLimit) {
            (, int24 tick,,) = manager.getSlot0(key.toId());
            int24 distance = int24(uint24(bound(limitTicks, 1, 12_000)));
            limit = TickMath.getSqrtPriceAtTick(zeroForOne ? tick - distance : tick + distance + 1);
        } else {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        SwapParams memory params = SwapParams(zeroForOne, exactIn ? -int256(amount) : int256(amount), limit);
        uint256 quote = probe.filled(manager, key, params);
        assertLe(quote, amount);
        BalanceDelta d = router.swap(key, params);
        assertEq(specifiedOf(d, zeroForOne, exactIn), quote, "quote disagrees with the manager");
    }

    function testQuoteIsZeroWhenTheManagerWouldRejectTheLimit() public {
        manager.initialize(key, Q96);
        shape(1, 4);
        SwapParams memory p = SwapParams(true, -1e18, Q96);
        assertEq(probe.filled(manager, key, p), 0);
        p.sqrtPriceLimitX96 = Q96 + 1;
        assertEq(probe.filled(manager, key, p), 0);
        p.sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE;
        assertEq(probe.filled(manager, key, p), 0);
        p.zeroForOne = false;
        p.sqrtPriceLimitX96 = Q96;
        assertEq(probe.filled(manager, key, p), 0);
        p.sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE;
        assertEq(probe.filled(manager, key, p), 0);
        vm.expectRevert();
        router.swap(key, p);
    }

    function testQuoteIsZeroOnAnEmptyPoolAndUninitializedPool() public {
        SwapParams memory p = SwapParams(true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(probe.filled(manager, key, p), 0, "uninitialized pool");
        manager.initialize(key, Q96);
        assertEq(probe.filled(manager, key, p), 0, "empty pool exact input");
        p.amountSpecified = 1e18;
        assertEq(probe.filled(manager, key, p), 0, "empty pool exact output");
        p.zeroForOne = false;
        p.sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
        assertEq(probe.filled(manager, key, p), 0);
        BalanceDelta d = router.swap(key, p);
        assertEq(BalanceDelta.unwrap(d), 0);
    }

    function testQuoteWalksGapsAndWholeBitmapWords() public {
        manager.initialize(key, Q96);
        // Liquidity only far from the price, with an empty word between: the walk must cross it.
        router.liquidity(key, ModifyLiquidityParams(-60_000, -59_940, 1e24, bytes32(uint256(1))));
        router.liquidity(key, ModifyLiquidityParams(59_940, 60_000, 1e24, bytes32(uint256(2))));
        for (uint256 mode; mode < 4; ++mode) {
            bool zeroForOne = mode < 2;
            bool exactIn = mode % 2 == 0;
            SwapParams memory p = SwapParams(
                zeroForOne,
                exactIn ? -int256(1e21) : int256(1e21),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            );
            uint256 snap = vm.snapshotState();
            uint256 quote = probe.filled(manager, key, p);
            BalanceDelta d = router.swap(key, p);
            assertEq(specifiedOf(d, zeroForOne, exactIn), quote);
            assertGt(quote, 0);
            vm.revertToState(snap);
        }
    }

    function testQuoteOnRequestsFarBeyondInt128() public {
        manager.initialize(key, Q96);
        shape(7, 5);
        for (uint256 mode; mode < 2; ++mode) {
            bool zeroForOne = mode == 0;
            SwapParams memory p = SwapParams(
                zeroForOne,
                type(int256).min,
                TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-300) : int24(300))
            );
            uint256 snap = vm.snapshotState();
            uint256 quote = probe.filled(manager, key, p);
            BalanceDelta d = router.swap(key, p);
            assertEq(specifiedOf(d, zeroForOne, true), quote);
            vm.revertToState(snap);
        }
    }
}
