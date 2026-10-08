// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookDeployer} from "../script/HookDeployer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract HookTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        setupLocal(false, true);
    }

    function testImmutableConfigurationAndPermissions() public view {
        assertEq(hook.treasury(), TREASURY);
        assertEq(Currency.unwrap(hook.imd()), IMD);
        assertEq(hook.token(), address(token));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.OPENING_FEE(), 4000);
        assertEq(hook.STEADY_FEE(), 300);
        assertEq(hook.OPENING_SECONDS(), 3600);
        assertEq(hook.LP_FEE(), 12500);
        assertEq(hook.TICK_SPACING(), 60);
        assertEq(HookFlags.flagsOf(address(hook)), 0x20cc);
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta
                && p.afterSwapReturnDelta
        );
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
    }

    function testFeeScheduleBoundaries() public {
        uint256 start = hook.openedAt();
        assertEq(hook.feeNow(), 4000);
        vm.warp(start + 1);
        assertEq(hook.feeNow(), 3998);
        vm.warp(start + 1800);
        assertEq(hook.feeNow(), 2150);
        vm.warp(start + 3599);
        assertEq(hook.feeNow(), 301);
        vm.warp(start + 3600);
        assertEq(hook.feeNow(), 300);
        vm.warp(start + 3601);
        assertEq(hook.feeNow(), 300);
        vm.warp(type(uint64).max);
        assertEq(hook.feeNow(), 300);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzScheduleMonotonic(uint32 elapsed, uint32 later) public {
        uint256 t = hook.openedAt() + elapsed;
        vm.warp(t);
        uint256 first = hook.feeNow();
        assertGe(first, 300);
        assertLe(first, 4000);
        if (elapsed < 3600) {
            uint256 continuousNumerator = 4000 * 3600 - uint256(elapsed) * 3700;
            assertLe(first * 3600, continuousNumerator);
            assertLt(continuousNumerator - first * 3600, 3600);
        } else {
            assertEq(first, 300);
        }
        vm.warp(t + later);
        assertLe(hook.feeNow(), first);
    }

    function testUnauthorizedCallbacks() public {
        SwapParams memory params = swapParams(true, true, 1 ether, 0);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function testInvalidInitializationAndNoReset() public {
        HookDeployer deployer = new HookDeployer();
        (bytes32 salt,) = deployer.mine(address(deployer), manager, address(token), 0, 200_000);
        SIMDTESTHook fresh = deployer.deploy(manager, address(token), salt);
        assertEq(fresh.feeNow(), 4000);
        PoolKey memory bad = key;
        bad.hooks = IHooks(address(fresh));
        bad.fee = 3000;
        vm.expectRevert();
        manager.initialize(bad, Q96);
        bad.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(bad, Q96);
        bad.fee = 12500;
        bad.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(bad, Q96);
        bad.tickSpacing = 60;
        bad.currency0 = Currency.wrap(address(1));
        vm.expectRevert();
        manager.initialize(bad, Q96);
        bad.currency0 = key.currency0;
        vm.warp(1000);
        manager.initialize(bad, Q96);
        assertEq(fresh.openedAt(), 1000);
        vm.warp(2000);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.AlreadyInitialized.selector);
        fresh.beforeInitialize(address(this), bad, Q96);
        assertEq(fresh.openedAt(), 1000);
    }

    function testAllSwapModesOpeningAndSteady() public {
        for (uint256 t; t < 2; ++t) {
            for (uint256 mode; mode < 4; ++mode) {
                bool buy = mode < 2;
                bool exactIn = mode % 2 == 0;
                BalanceDelta d = checkSwap(buy, exactIn, 100 ether, 0);
                int256 specified = buy == exactIn ? pairDelta(d) : tokenDelta(d);
                assertEq(specified, exactIn ? -int256(100 ether) : int256(100 ether));
                assertTrue(
                    buy ? tokenDelta(d) > 0 && pairDelta(d) < 0 : tokenDelta(d) < 0 && pairDelta(d) > 0
                );
            }
            vm.warp(hook.openedAt() + 3600);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFeeOnRealSwaps(bool buy, bool exactIn, uint96 raw, uint16 elapsed) public {
        uint256 amount = bound(raw, 100, 10000 ether);
        vm.warp(hook.openedAt() + elapsed);
        checkSwap(buy, exactIn, amount, 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzPartialFills(bool buy, bool exactIn, uint8 ticks, uint16 elapsed) public {
        vm.warp(hook.openedAt() + elapsed);
        bool down = buy == (Currency.unwrap(key.currency0) == IMD);
        int24 distance = int24(uint24(bound(ticks, 1, 120)));
        uint160 limit = TickMath.getSqrtPriceAtTick(down ? -distance : distance);
        BalanceDelta d = checkSwap(buy, exactIn, 1e26, limit);
        assertGt(hook.collected(), 0);
        int256 specified = buy == exactIn ? pairDelta(d) : tokenDelta(d);
        assertLt(uint256(specified < 0 ? -specified : specified), 1e26);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
    }

    function testTickCrossingsAndLiquidityGaps() public {
        router.liquidity(key, ModifyLiquidityParams(-600, 600, -1e25, 0));
        router.liquidity(key, ModifyLiquidityParams(-120, 120, 1e24, bytes32(uint256(1))));
        router.liquidity(key, ModifyLiquidityParams(-360, -240, 2e24, bytes32(uint256(2))));
        router.liquidity(key, ModifyLiquidityParams(240, 360, 3e24, bytes32(uint256(3))));
        checkSwap(false, false, 1e26, TickMath.getSqrtPriceAtTick(-400));
        checkSwap(true, true, 1e26, TickMath.getSqrtPriceAtTick(400));
    }

    function testSweepPermissionlessAndConservesAllFees() public {
        checkSwap(true, true, 100 ether, 0);
        checkSwap(false, true, 100 ether, 0);
        uint256 accrued = hook.collected();
        uint256 donation = 17 ether;
        MockERC20(IMD).transfer(address(hook), donation);
        assertEq(hook.pending(), accrued + donation);
        uint256 before = MockERC20(IMD).balanceOf(TREASURY);
        address caller = makeAddr("sweeper");
        vm.prank(caller);
        assertEq(hook.sweep(), accrued + donation);
        assertEq(MockERC20(IMD).balanceOf(TREASURY) - before, accrued + donation);
        assertEq(MockERC20(IMD).balanceOf(caller), 0);
        assertEq(hook.pending(), 0);
        assertEq(hook.collected(), accrued);
        assertEq(hook.sweep(), 0);
    }

    function testRevertingSweepPreservesClaimsAndDoesNotBlockSwaps() public {
        checkSwap(true, true, 100 ether, 0);
        uint256 claims = hook.pending();
        MockERC20(IMD).blockRecipient(TREASURY);
        vm.expectRevert();
        hook.sweep();
        assertEq(hook.pending(), claims);
        checkSwap(false, false, 100 ether, 0);
        assertGt(hook.pending(), claims);
        MockERC20(IMD).blockRecipient(address(0));
        uint256 owed = hook.pending();
        assertEq(hook.sweep(), owed);
    }

    function testReentryAndUnlockedSweepAreHarmless() public {
        checkSwap(true, true, 100 ether, 0);
        uint256 owed = hook.pending();
        assertEq(router.sweepInsideUnlock(key), 0);
        assertEq(hook.pending(), owed);
        MockERC20(IMD).reenterOnTransfer(address(hook));
        assertEq(hook.sweep(), owed);
        assertEq(MockERC20(IMD).reentryResult(), 0);
        assertEq(hook.pending(), 0);
    }

    function testRevertingSettlementRollsBackFeesAndPrice() public {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        token.approve(address(router), 0);
        vm.expectRevert();
        router.swap(key, swapParams(false, true, 1 ether, 0));
        assertEq(hook.collected(), 0);
        assertEq(hook.pending(), 0);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, price);
    }

    function testInvalidSwapInputsAreManagerFailures() public {
        vm.expectRevert();
        router.swap(key, swapParams(true, true, 0, 0));
        vm.expectRevert();
        router.swap(key, swapParams(true, true, 1 ether, Q96));
        assertEq(hook.collected(), 0);
    }

    function testTinySwapsDoNotConsumeEntireInputAsFee() public {
        for (uint256 mode; mode < 4; ++mode) {
            checkSwap(mode < 2, mode % 2 == 0, 1, 0);
        }
        assertLe(hook.collected(), 4);
    }

    function testProtocolFeesDoNotDesynchronizePartialFillQuote() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(1000 | (500 << 12)));
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snapshot = vm.snapshotState();
            bool buy = mode < 2;
            bool down = buy == (Currency.unwrap(key.currency0) == IMD);
            checkSwap(buy, mode % 2 == 0, 1e26, TickMath.getSqrtPriceAtTick(down ? int24(-100) : int24(100)));
            vm.revertToState(snapshot);
        }
    }

    function testHugeRequestedInputOnlyChargesTheSmallFilledAmount() public {
        checkSwap(true, true, uint256(1) << 255, TickMath.getSqrtPriceAtTick(1));
        assertLt(hook.collected(), 1e24);
    }

    function testZeroTimestampInitializationDoesNotResetClock() public {
        HookDeployer deployer = new HookDeployer();
        (bytes32 salt,) = deployer.mine(address(deployer), manager, address(token), 0, 200_000);
        SIMDTESTHook fresh = deployer.deploy(manager, address(token), salt);
        PoolKey memory freshKey = key;
        freshKey.hooks = IHooks(address(fresh));
        vm.warp(0);
        manager.initialize(freshKey, Q96);
        assertEq(fresh.openedAt(), 0);
        assertTrue(fresh.initialized());
        vm.warp(3600);
        assertEq(fresh.feeNow(), 300);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.AlreadyInitialized.selector);
        fresh.beforeInitialize(address(this), freshKey, Q96);
    }

    function testWrongPermissionBitsRefuseDeployment() public {
        HookDeployer deployer = new HookDeployer();
        bytes32 codeHash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token))));
        bytes32 salt;
        while (HookFlags.matches(deployer.predict(address(deployer), salt, codeHash), HookFlags.SIMDTEST)) {
            salt = bytes32(uint256(salt) + 1);
        }
        vm.expectRevert();
        deployer.deploy(manager, address(token), salt);
    }

    function testNoAdminPathsAndRuntimeLimits() public {
        string[6] memory sigs = [
            "owner()",
            "setTreasury(address)",
            "setFee(uint256)",
            "pause()",
            "upgradeTo(address)",
            "transferOwnership(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], address(this)));
            assertFalse(ok, sigs[i]);
        }
        assertLe(type(SIMDTESTHook).creationCode.length + 64, 49152);
        assertLe(address(hook).code.length, 24576);
        bytes memory code = address(hook).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}

contract OppositeOrderingTest is HookFixture {
    function setUp() public {
        setupLocal(true, true);
    }

    function testBothDirectionsAndExactnessWithIMDCurrency0() public {
        for (uint256 mode; mode < 4; ++mode) {
            checkSwap(mode < 2, mode % 2 == 0, 100 ether, 0);
        }
        assertGt(hook.sweep(), 0);
    }
}

contract FreshManagerTest is HookFixture {
    function setUp() public {
        setupLocal(false, false);
    }

    function testTokenOnlySeedNeedsNoPrefundedIMD() public {
        router.liquidity(key, ModifyLiquidityParams(60, 600, 1e25, 0));
        assertEq(MockERC20(IMD).balanceOf(address(manager)), 0);
        checkSwap(true, true, 1e22, 0);
        assertGt(hook.pending(), 0);
        assertGt(hook.sweep(), 0);
    }

    function testEmptyPoolChargesNothingInAllModes() public {
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            BalanceDelta d = checkSwap(mode < 2, mode % 2 == 0, 1e22, 0);
            assertEq(BalanceDelta.unwrap(d), 0);
            assertEq(hook.pending(), 0);
            vm.revertToState(snap);
        }
    }
}
