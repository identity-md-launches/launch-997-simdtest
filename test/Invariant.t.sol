// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract SwapHandler is Test {
    TestRouter public immutable router;
    SIMDTESTHook public immutable hook;
    PoolKey internal key;
    uint256 public paid;
    uint256 public swaps;

    constructor(TestRouter r, SIMDTESTHook h, PoolKey memory k) {
        router = r;
        hook = h;
        key = k;
        IERC20Minimal(Currency.unwrap(k.currency0)).approve(address(r), type(uint256).max);
        IERC20Minimal(Currency.unwrap(k.currency1)).approve(address(r), type(uint256).max);
    }

    function trade(bool buy, bool exactIn, uint96 raw) external {
        bool zeroForOne = buy == (key.currency0 == hook.imd());
        uint256 amount = bound(raw, 100, 1e20);
        router.swap(
            key,
            SwapParams(
                zeroForOne,
                exactIn ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        ++swaps;
    }

    function sweep() external {
        paid += hook.sweep();
    }

    function advance(uint16 dt) external {
        vm.warp(block.timestamp + dt);
    }
}

contract HookInvariantTest is HookFixture {
    using TransientStateLibrary for IPoolManager;
    SwapHandler handler;
    uint256 totalPair;
    uint256 treasuryBefore;
    uint256 start;

    function setUp() public {
        setupLocal(false, true);
        handler = new SwapHandler(router, hook, key);
        token.transfer(address(handler), 1e25);
        IERC20Minimal(IMD).transfer(address(handler), 1e25);
        totalPair =
            IERC20Minimal(IMD).balanceOf(address(handler)) + IERC20Minimal(IMD).balanceOf(address(manager));
        treasuryBefore = IERC20Minimal(IMD).balanceOf(TREASURY);
        start = hook.openedAt();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.sweep.selector;
        selectors[2] = handler.advance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantFeesRemainBackedAndOnlyTreasuryReceives() public view {
        assertEq(hook.pending() + handler.paid(), hook.collected());
        assertEq(IERC20Minimal(IMD).balanceOf(TREASURY) - treasuryBefore, handler.paid());
        assertEq(
            IERC20Minimal(IMD).balanceOf(address(handler)) + IERC20Minimal(IMD).balanceOf(address(manager))
                + handler.paid(),
            totalPair
        );
        assertLe(hook.pending(), IERC20Minimal(IMD).balanceOf(address(manager)));
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(hook.openedAt(), start);
        assertEq(token.totalSupply(), 1e27);
    }
}
