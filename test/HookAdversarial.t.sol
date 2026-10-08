// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookDataRouter, ClaimDonor, DonateRouter, Sweeper} from "./helpers/Actors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookDeployer} from "../script/HookDeployer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @notice Adversarial unit and fuzz coverage on top of Hook.t.sol: exact fee arithmetic per mode and
/// rate, events, constructor guards, the never-revert property, sender/hookData independence, paths
/// without hook callbacks, and unexpected claim balances. Runs with IMD as currency1 here and as
/// currency0 in HookAdversarialIMDFirstTest.
contract HookAdversarialTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 constant D = 10_000;

    event Opened(uint256 timestamp);
    event FeeAccrued(uint256 amount);
    event Swept(uint256 amount);

    function imdIsCurrency0() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public virtual {
        setupLocal(imdIsCurrency0(), true);
    }

    // ----------------------------------------------------------------------------------------
    // Fee schedule: exact closed form, not only monotonicity
    // ----------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 2000
    function testFuzzFeeNowMatchesClosedForm(uint64 elapsed) public {
        vm.warp(hook.openedAt() + elapsed);
        uint256 expected = elapsed >= 3600 ? 300 : 300 + (3700 * (3600 - uint256(elapsed))) / 3600;
        assertEq(hook.feeNow(), expected);
    }

    function testFeeNowRoundsDownAtEveryStep() public {
        // 3700/3600 bps per second is not an integer; every second must round toward the trader.
        uint256 start = hook.openedAt();
        uint256 previous = 4000;
        for (uint256 t = 1; t <= 3600; t += 7) {
            vm.warp(start + t);
            uint256 now_ = hook.feeNow();
            uint256 exact = 300 * 3600 + 3700 * (3600 - t);
            assertLe(now_ * 3600, exact, "rounded up");
            assertLt(exact - now_ * 3600, 3600, "rounded down by more than one bp");
            assertLe(now_, previous);
            previous = now_;
        }
    }

    function testOneSecondBoundaryChangesTheCharge() public {
        uint256 start = hook.openedAt();
        uint256 snap = vm.snapshotState();
        vm.warp(start + 3599);
        checkSwap(true, true, 1e21, 0);
        uint256 lateOpening = hook.collected();
        vm.revertToState(snap);
        vm.warp(start + 3600);
        checkSwap(true, true, 1e21, 0);
        assertEq(lateOpening, 1e21 * 301 / D);
        assertEq(hook.collected(), 1e21 * 300 / D);
    }

    // ----------------------------------------------------------------------------------------
    // Exact fee arithmetic for every mode, matching the README table
    // ----------------------------------------------------------------------------------------

    function expectedFee(bool buy, bool exactIn, uint256 amount, int256 pd, uint256 rate, uint256 fee)
        internal
        pure
        returns (uint256)
    {
        if (buy && exactIn) return amount * rate / D; // specified gross IMD input
        if (!buy && !exactIn) return amount * rate / (D - rate); // specified net IMD output
        if (!buy) return (uint256(pd) + fee) * rate / D; // gross pool output P = net + fee
        return (uint256(-pd) - fee) * rate / (D - rate); // gross = P + fee, fee on P
    }

    function assertExactFee(bool buy, bool exactIn, uint256 amount) internal {
        uint256 rate = hook.feeNow();
        uint256 before = hook.collected();
        BalanceDelta d = checkSwap(buy, exactIn, amount, 0);
        uint256 fee = hook.collected() - before;
        assertEq(fee, expectedFee(buy, exactIn, amount, pairDelta(d), rate, fee));
        if (buy == exactIn) assertEq(pairDelta(d), exactIn ? -int256(amount) : int256(amount));
        else assertEq(tokenDelta(d), exactIn ? -int256(amount) : int256(amount));
    }

    function testExactFeesAtOpening() public {
        assertEq(hook.feeNow(), 4000);
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            assertExactFee(mode < 2, mode % 2 == 0, 123_456_789_012_345_678_901);
            vm.revertToState(snap);
        }
    }

    function testExactFeesHalfway() public {
        vm.warp(hook.openedAt() + 1800);
        assertEq(hook.feeNow(), 2150);
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            assertExactFee(mode < 2, mode % 2 == 0, 7e21);
            vm.revertToState(snap);
        }
    }

    function testExactFeesSteadyState() public {
        vm.warp(hook.openedAt() + 86_400);
        assertEq(hook.feeNow(), 300);
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            assertExactFee(mode < 2, mode % 2 == 0, 999_999_999_999_999_999);
            vm.revertToState(snap);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzExactFeesOnFullFills(bool buy, bool exactIn, uint72 raw, uint16 elapsed) public {
        uint256 amount = bound(raw, 1, 1e22);
        vm.warp(hook.openedAt() + elapsed);
        assertExactFee(buy, exactIn, amount);
    }

    function testGrossFortyPercentIsTwoThirdsOfNet() public {
        // A seller asking for 300 IMD net at the opening pays a 200 IMD fee: 40% of the 500 gross.
        uint256 before = hook.collected();
        BalanceDelta d = checkSwap(false, false, 300 ether, 0);
        assertEq(pairDelta(d), int256(300 ether));
        assertEq(hook.collected() - before, 200 ether);
    }

    function testCollectedIsTheSumOfPerSwapFeesAcrossTheSchedule() public {
        uint256 start = hook.openedAt();
        uint256 sum;
        uint16[6] memory times = [0, 1, 599, 1800, 3599, 3600];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(start + times[i]);
            uint256 before = hook.collected();
            checkSwap(i % 2 == 0, i % 3 == 0, 5e20, 0);
            sum += hook.collected() - before;
        }
        assertEq(hook.collected(), sum);
        assertEq(hook.pending(), sum);
        assertEq(hook.sweep(), sum);
        assertEq(hook.collected(), sum, "sweep must not reduce collected");
    }

    // ----------------------------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------------------------

    function testEventsOpenedAccruedSwept() public {
        HookDeployer deployer = new HookDeployer();
        (bytes32 salt,) = deployer.mine(address(deployer), manager, address(token), 0, 200_000);
        SIMDTESTHook fresh = deployer.deploy(manager, address(token), salt);
        PoolKey memory freshKey = key;
        freshKey.hooks = IHooks(address(fresh));
        vm.warp(123_456);
        vm.expectEmit(true, true, true, true, address(fresh));
        emit Opened(123_456);
        manager.initialize(freshKey, Q96);

        uint256 fee = 1e21 * hook.feeNow() / D;
        vm.expectEmit(true, true, true, true, address(hook));
        emit FeeAccrued(fee);
        router.swap(key, swapParams(true, true, 1e21, 0));

        vm.expectEmit(true, true, true, true, address(hook));
        emit Swept(fee);
        assertEq(hook.sweep(), fee);
    }

    // ----------------------------------------------------------------------------------------
    // Construction and initialization guards
    // ----------------------------------------------------------------------------------------

    function testConstructorRejectsMissingOrCollidingAddresses() public {
        vm.expectRevert(SIMDTESTHook.InvalidConfiguration.selector);
        new SIMDTESTHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(SIMDTESTHook.InvalidConfiguration.selector);
        new SIMDTESTHook(manager, address(0));
        vm.expectRevert(SIMDTESTHook.InvalidConfiguration.selector);
        new SIMDTESTHook(manager, IMD);
    }

    function testConstructorRejectsAnAddressWithoutThePermissionBits() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertFalse(HookFlags.matches(predicted, HookFlags.SIMDTEST), "fixture address accidentally valid");
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SIMDTESTHook(manager, address(token));
    }

    function testFreshHookReportsOpeningRateAndNothingPending() public {
        HookDeployer deployer = new HookDeployer();
        (bytes32 salt,) = deployer.mine(address(deployer), manager, address(token), 0, 200_000);
        SIMDTESTHook fresh = deployer.deploy(manager, address(token), salt);
        assertFalse(fresh.initialized());
        assertEq(fresh.openedAt(), 0);
        assertEq(fresh.feeNow(), 4000);
        assertEq(fresh.pending(), 0);
        assertEq(fresh.collected(), 0);
        vm.warp(block.timestamp + 10 days);
        assertEq(fresh.feeNow(), 4000, "clock must not run before the pool opens");
        assertEq(fresh.sweep(), 0);
    }

    function testHookCannotBeSharedWithASecondPool() public {
        MockERC20 a = new MockERC20("A", "A", 0);
        MockERC20 b = new MockERC20("B", "B", 0);
        (address c0, address c1) =
            address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory other = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(address(hook)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(SIMDTESTHook.AlreadyInitialized.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(other, Q96);

        // The launch pool itself cannot be re-opened either, so the clock can never restart.
        vm.warp(hook.openedAt() + 5000);
        vm.expectRevert();
        manager.initialize(key, Q96 * 2);
        assertEq(hook.feeNow(), 300);
    }

    function testFreshHookRejectsForeignPoolsWithClearReasons() public {
        HookDeployer deployer = new HookDeployer();
        (bytes32 salt,) = deployer.mine(address(deployer), manager, address(token), 0, 200_000);
        SIMDTESTHook fresh = deployer.deploy(manager, address(token), salt);
        PoolKey memory bad = key;
        bad.hooks = IHooks(address(fresh));
        bad.fee = 500;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(SIMDTESTHook.InvalidPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(bad, Q96);
        assertFalse(fresh.initialized(), "a rejected key must not start the clock");

        // A pool that lists another hook cannot borrow this one's callbacks either.
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), key, Q96);
        assertFalse(fresh.initialized());
    }

    // ----------------------------------------------------------------------------------------
    // The hook never reverts a swap: any failure is the manager's or the token's, never the hook's
    // ----------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1500
    function testFuzzHookNeverCausesASwapRevert(
        bool buy,
        bool exactIn,
        uint256 amount,
        uint160 rawLimit,
        bool sensibleLimit,
        uint32 elapsed
    ) public {
        vm.warp(hook.openedAt() + elapsed);
        amount = bound(amount, 1, uint256(1) << 255);
        SwapParams memory params = swapParams(buy, exactIn, amount, 0);
        if (sensibleLimit) {
            (, int24 tick,,) = manager.getSlot0(key.toId());
            int24 distance = int24(uint24(bound(rawLimit, 1, 2000)));
            params.sqrtPriceLimitX96 =
                TickMath.getSqrtPriceAtTick(params.zeroForOne ? tick - distance : tick + distance + 1);
        } else {
            params.sqrtPriceLimitX96 = rawLimit;
        }
        uint256 collectedBefore = hook.collected();
        try router.swap(key, params) returns (BalanceDelta d) {
            uint256 fee = hook.collected() - collectedBefore;
            int256 pd = pairDelta(d);
            uint256 gross = buy ? uint256(-pd) : uint256(pd) + fee;
            assertLe(fee, gross * hook.feeNow() / D + 1);
            assertEq(hook.pending(), hook.collected());
        } catch (bytes memory reason) {
            assertNotHookFailure(reason);
            assertEq(hook.collected(), collectedBefore);
        }
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function assertNotHookFailure(bytes memory reason) internal view {
        bytes4 selector;
        if (reason.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
        }
        assertTrue(selector != Hooks.InvalidHookResponse.selector, "hook returned malformed data");
        assertTrue(selector != Hooks.HookDeltaExceedsSwapAmount.selector, "hook fee exceeded the swap");
        assertTrue(selector != Hooks.HookCallFailed.selector, "hook call failed");
        if (selector == CustomRevert.WrappedError.selector) {
            bytes memory payload = new bytes(reason.length - 4);
            for (uint256 i; i < payload.length; ++i) {
                payload[i] = reason[i + 4];
            }
            (address target,,,) = abi.decode(payload, (address, bytes4, bytes, bytes));
            assertTrue(target != address(hook), "the hook reverted inside a swap");
        }
    }

    // ----------------------------------------------------------------------------------------
    // Caller identity and hook data must not matter
    // ----------------------------------------------------------------------------------------

    function testFeeIsIndependentOfSenderAndHookData() public {
        HookDataRouter other = new HookDataRouter(manager);
        IERC20Minimal(IMD).approve(address(other), type(uint256).max);
        token.approve(address(other), type(uint256).max);
        uint256 snap = vm.snapshotState();
        router.swap(key, swapParams(false, true, 3e21, 0));
        uint256 plain = hook.collected();
        vm.revertToState(snap);
        bytes memory junk = abi.encode(address(this), TREASURY, uint256(0), "treasury=me", hex"ffffffff");
        other.swap(key, swapParams(false, true, 3e21, 0), junk);
        assertEq(hook.collected(), plain);
        assertEq(hook.pending(), plain);
        vm.revertToState(snap);
        vm.prank(TREASURY);
        vm.expectRevert(); // the treasury has no tokens; being the treasury buys no exemption
        other.swap(key, swapParams(false, true, 3e21, 0), "");
        assertEq(hook.collected(), 0);
    }

    // ----------------------------------------------------------------------------------------
    // Paths without hook callbacks
    // ----------------------------------------------------------------------------------------

    function testLiquidityAndDonationsAreNeverCharged() public {
        uint256 imdBefore = IERC20Minimal(IMD).balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        router.liquidity(key, ModifyLiquidityParams(-1200, 1200, 5e24, bytes32(uint256(7))));
        uint256 imdIn = imdBefore - IERC20Minimal(IMD).balanceOf(address(this));
        uint256 tokenIn = tokenBefore - token.balanceOf(address(this));
        assertGt(imdIn, 0);
        assertGt(tokenIn, 0);
        router.liquidity(key, ModifyLiquidityParams(-1200, 1200, -5e24, bytes32(uint256(7))));
        // Round trip returns everything but at most one wei of rounding per currency, nothing to the hook.
        assertApproxEqAbs(IERC20Minimal(IMD).balanceOf(address(this)), imdBefore, 1);
        assertApproxEqAbs(token.balanceOf(address(this)), tokenBefore, 1);
        assertEq(hook.collected(), 0);
        assertEq(hook.pending(), 0);

        DonateRouter donor = new DonateRouter(manager);
        IERC20Minimal(IMD).approve(address(donor), type(uint256).max);
        token.approve(address(donor), type(uint256).max);
        donor.donate(key, 1e21, 1e21);
        assertEq(hook.collected(), 0);
        assertEq(hook.pending(), 0);
        assertEq(IERC20Minimal(IMD).balanceOf(address(hook)), 0);
    }

    function testLpFeesStayWithLiquidityProvidersNotTheHook() public {
        // Withdraw the seed position after trading; the LP share must grow by exactly the LP fee
        // of what reached the pool, and the hook's share must be exactly its own rate.
        uint256 rate = hook.feeNow();
        uint256 amount = 1e22;
        uint256 seedIMD = IERC20Minimal(IMD).balanceOf(address(manager));
        BalanceDelta d = checkSwap(true, true, amount, 0);
        uint256 hookFee = hook.collected();
        assertEq(hookFee, amount * rate / D);
        uint256 toPool = amount - hookFee;
        uint256 imdBefore = IERC20Minimal(IMD).balanceOf(address(this));
        router.liquidity(key, ModifyLiquidityParams(-600, 600, -1e25, 0));
        uint256 imdOut = IERC20Minimal(IMD).balanceOf(address(this)) - imdBefore;
        // The LP leaves with its seed plus everything that reached the pool (LP fee included); the
        // manager keeps exactly the hook's claims plus rounding dust, which the hook never touches.
        assertApproxEqAbs(imdOut, seedIMD + toPool, 4);
        assertApproxEqAbs(IERC20Minimal(IMD).balanceOf(address(manager)), hookFee, 4);
        assertEq(hook.pending(), hookFee);
        assertTrue(tokenDelta(d) > 0);
    }

    // ----------------------------------------------------------------------------------------
    // Unexpected balances
    // ----------------------------------------------------------------------------------------

    function testUnexpectedClaimsAreForwardedToTreasuryWithoutRevert() public {
        checkSwap(true, true, 1e21, 0);
        uint256 fees = hook.collected();
        ClaimDonor donor = new ClaimDonor(manager, Currency.wrap(IMD));
        MockERC20(IMD).transfer(address(donor), 5e20);
        donor.donateClaims(address(hook), 5e20);
        assertEq(hook.pending(), fees + 5e20);
        assertEq(hook.collected(), fees, "claims pushed from outside are not swap fees");
        uint256 before = IERC20Minimal(IMD).balanceOf(TREASURY);
        assertEq(hook.sweep(), fees + 5e20);
        assertEq(IERC20Minimal(IMD).balanceOf(TREASURY) - before, fees + 5e20);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(IMD).toId()), 0);
    }

    function testHookNeverHoldsLaunchTokenClaims() public {
        for (uint256 mode; mode < 4; ++mode) {
            checkSwap(mode < 2, mode % 2 == 0, 2e21, 0);
        }
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(token)).toId()), 0);
        assertGt(manager.balanceOf(address(hook), Currency.wrap(IMD).toId()), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function testSweepByContractCallerPaysOnlyTreasury() public {
        checkSwap(false, true, 1e21, 0);
        uint256 owed = hook.pending();
        Sweeper sweeper = new Sweeper();
        uint256 before = IERC20Minimal(IMD).balanceOf(TREASURY);
        assertEq(sweeper.run(hook), owed);
        assertEq(IERC20Minimal(IMD).balanceOf(TREASURY) - before, owed);
        assertEq(IERC20Minimal(IMD).balanceOf(address(sweeper)), 0);
        assertEq(hook.pending(), 0);
    }

    function testManagerIMDAlwaysBacksTheClaims() public {
        for (uint256 i; i < 6; ++i) {
            vm.warp(hook.openedAt() + i * 700);
            checkSwap(i % 2 == 0, i % 3 != 0, 4e21, 0);
            assertLe(
                manager.balanceOf(address(hook), Currency.wrap(IMD).toId()),
                IERC20Minimal(IMD).balanceOf(address(manager))
            );
        }
    }

    // ----------------------------------------------------------------------------------------
    // Partial fills under an adversarial tick layout
    // ----------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 256
    function testFuzzPartialFillsAcrossManyInitializedTicks(
        bool buy,
        bool exactIn,
        uint8 ticks,
        uint16 elapsed
    ) public {
        // Dense, uneven ticks make the read-only quote walk several bitmap entries and gaps.
        for (int24 i = 1; i <= 12; ++i) {
            router.liquidity(
                key,
                ModifyLiquidityParams(
                    -60 * i * 3, 60 * i * 2, int256(1e22) * int256(i), bytes32(uint256(uint24(i)))
                )
            );
        }
        router.liquidity(key, ModifyLiquidityParams(-600, 600, -1e25, 0));
        vm.warp(hook.openedAt() + elapsed);
        bool down = buy == (Currency.unwrap(key.currency0) == IMD);
        int24 distance = int24(uint24(bound(ticks, 1, 2500)));
        uint160 limit = TickMath.getSqrtPriceAtTick(down ? -distance : distance);
        BalanceDelta d = checkSwap(buy, exactIn, 1e27, limit);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
        int256 specified = buy == exactIn ? pairDelta(d) : tokenDelta(d);
        assertLt(uint256(specified < 0 ? -specified : specified), 1e27, "partial fill expected");
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookAdversarialIMDFirstTest is HookAdversarialTest {
    function imdIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}
