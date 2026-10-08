// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {ClaimDonor, DonateRouter} from "./helpers/Actors.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @dev Random, bounded actions against the live pool: every swap mode with and without price
/// limits, liquidity in and out, donations to the pool, loose IMD and ERC-6909 claims pushed onto the
/// hook, time, and sweeps. Reverts are caught and classified so a hook-caused revert is a finding
/// while a manager rejection of a nonsensical request is not.
contract ExtendedHandler is Test {
    using StateLibrary for IPoolManager;

    struct Position {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        bytes32 salt;
    }

    IPoolManager public immutable manager;
    TestRouter public immutable router;
    DonateRouter public immutable donateRouter;
    ClaimDonor public immutable donor;
    SIMDTESTHook public immutable hook;
    address public immutable imd;
    PoolKey internal key;
    Position[] internal positions;

    uint256 public paid;
    uint256 public looseDonated;
    uint256 public claimDonated;
    uint256 public hookReverts;
    uint256 public managerReverts;
    uint256 public swaps;
    uint256 public skipped;

    constructor(IPoolManager m, TestRouter r, SIMDTESTHook h, PoolKey memory k, address imd_) {
        manager = m;
        router = r;
        hook = h;
        key = k;
        imd = imd_;
        donateRouter = new DonateRouter(m);
        donor = new ClaimDonor(m, Currency.wrap(imd_));
        IERC20Minimal(Currency.unwrap(k.currency0)).approve(address(r), type(uint256).max);
        IERC20Minimal(Currency.unwrap(k.currency1)).approve(address(r), type(uint256).max);
        IERC20Minimal(Currency.unwrap(k.currency0)).approve(address(donateRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(k.currency1)).approve(address(donateRouter), type(uint256).max);
    }

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function swap(bool buy, bool exactIn, uint96 raw, uint16 ticks, bool useLimit) external {
        uint256 amount = bound(raw, 1, 1e21);
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == imd);
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (useLimit) {
            int24 distance = int24(uint24(bound(ticks, 1, 3000)));
            int24 target = zeroForOne ? tick - distance : tick + distance + 1;
            if (target < TickMath.MIN_TICK + 1) target = TickMath.MIN_TICK + 1;
            if (target > TickMath.MAX_TICK - 1) target = TickMath.MAX_TICK - 1;
            limit = TickMath.getSqrtPriceAtTick(target);
        }
        if (zeroForOne ? limit >= price : limit <= price) {
            ++skipped;
            return;
        }
        SwapParams memory params = SwapParams(zeroForOne, exactIn ? -int256(amount) : int256(amount), limit);
        try router.swap(key, params) {
            ++swaps;
        } catch (bytes memory reason) {
            classify(reason);
        }
    }

    function addLiquidity(int16 lowerRaw, uint8 widthRaw, uint96 raw) external {
        int24 lower = int24(bound(int256(lowerRaw), -100, 99)) * 60;
        int24 upper = lower + int24(int256(bound(widthRaw, 1, 50))) * 60;
        uint128 liquidity = uint128(bound(raw, 1e12, 1e24));
        bytes32 salt = bytes32(positions.length + 100);
        try router.liquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), salt)) {
            positions.push(Position(lower, upper, liquidity, salt));
        } catch (bytes memory reason) {
            classify(reason);
        }
    }

    function removeLiquidity(uint8 idx, uint8 pct) external {
        if (positions.length == 0) {
            ++skipped;
            return;
        }
        Position storage p = positions[idx % positions.length];
        if (p.liquidity == 0) {
            ++skipped;
            return;
        }
        uint128 part = uint128(uint256(p.liquidity) * bound(pct, 1, 100) / 100);
        if (part == 0) part = p.liquidity;
        try router.liquidity(key, ModifyLiquidityParams(p.lower, p.upper, -int256(uint256(part)), p.salt)) {
            p.liquidity -= part;
        } catch (bytes memory reason) {
            classify(reason);
        }
    }

    function donate(uint96 a, uint96 b) external {
        if (manager.getLiquidity(key.toId()) == 0) {
            ++skipped;
            return;
        }
        try donateRouter.donate(key, bound(a, 0, 1e20), bound(b, 0, 1e20)) {}
        catch (bytes memory reason) {
            classify(reason);
        }
    }

    function donateLoose(uint64 raw) external {
        uint256 amount = bound(raw, 1, 1e20);
        MockERC20(imd).transfer(address(hook), amount);
        looseDonated += amount;
    }

    function donateClaims(uint64 raw) external {
        uint256 amount = bound(raw, 1, 1e20);
        MockERC20(imd).transfer(address(donor), amount);
        donor.donateClaims(address(hook), amount);
        claimDonated += amount;
    }

    function sweep() external {
        paid += hook.sweep();
    }

    function advance(uint16 dt) external {
        vm.warp(block.timestamp + dt);
    }

    function classify(bytes memory reason) internal {
        bytes4 selector;
        if (reason.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
        }
        if (
            selector == Hooks.InvalidHookResponse.selector
                || selector == Hooks.HookDeltaExceedsSwapAmount.selector
                || selector == Hooks.HookCallFailed.selector
        ) {
            ++hookReverts;
            return;
        }
        if (selector == CustomRevert.WrappedError.selector) {
            bytes memory payload = new bytes(reason.length - 4);
            for (uint256 i; i < payload.length; ++i) {
                payload[i] = reason[i + 4];
            }
            (address target,,,) = abi.decode(payload, (address, bytes4, bytes, bytes));
            if (target == address(hook)) {
                ++hookReverts;
                return;
            }
        }
        ++managerReverts;
    }
}

abstract contract ExtendedInvariantBase is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    ExtendedHandler handler;
    uint256 totalIMD;
    uint256 treasuryBefore;
    uint256 start;
    uint256 lastFee;
    uint256 lastCollected;

    function imdIsCurrency0() internal pure virtual returns (bool);

    function setUp() public {
        setupLocal(imdIsCurrency0(), true);
        handler = new ExtendedHandler(manager, router, hook, key, IMD);
        token.transfer(address(handler), 5e26);
        MockERC20(IMD).mint(address(handler), 1e30);
        treasuryBefore = IERC20Minimal(IMD).balanceOf(TREASURY);
        totalIMD = imdHeldByParticipants();
        start = hook.openedAt();
        lastFee = hook.feeNow();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.swap.selector;
        selectors[2] = handler.swap.selector;
        selectors[3] = handler.addLiquidity.selector;
        selectors[4] = handler.removeLiquidity.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.donateLoose.selector;
        selectors[7] = handler.donateClaims.selector;
        selectors[8] = handler.sweep.selector;
        bytes4[] memory all = new bytes4[](10);
        for (uint256 i; i < 9; ++i) {
            all[i] = selectors[i];
        }
        all[9] = handler.advance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), all));
    }

    function imdHeldByParticipants() internal view returns (uint256) {
        return IERC20Minimal(IMD).balanceOf(address(this)) + IERC20Minimal(IMD).balanceOf(address(handler))
            + IERC20Minimal(IMD).balanceOf(address(manager)) + IERC20Minimal(IMD).balanceOf(TREASURY)
            + IERC20Minimal(IMD).balanceOf(address(hook))
            + IERC20Minimal(IMD).balanceOf(address(handler.donor()))
            + IERC20Minimal(IMD).balanceOf(address(router))
            + IERC20Minimal(IMD).balanceOf(address(handler.donateRouter()));
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 48
    function invariantFeesAreBackedAndReachOnlyTreasury() public view {
        assertEq(
            hook.pending() + handler.paid(),
            hook.collected() + handler.looseDonated() + handler.claimDonated(),
            "pending + paid != collected + donations"
        );
        assertEq(IERC20Minimal(IMD).balanceOf(TREASURY) - treasuryBefore, handler.paid(), "treasury != paid");
        assertLe(
            manager.balanceOf(address(hook), Currency.wrap(IMD).toId()),
            IERC20Minimal(IMD).balanceOf(address(manager)),
            "claims exceed manager IMD"
        );
        assertEq(imdHeldByParticipants(), totalIMD, "IMD leaked");
        assertEq(token.balanceOf(address(hook)), 0, "hook holds launch token");
        assertEq(
            manager.balanceOf(address(hook), Currency.wrap(address(token)).toId()),
            0,
            "hook holds token claims"
        );
        assertEq(token.totalSupply(), 1e27);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 48
    function invariantScheduleClockAndPoolTermsAreFixed() public {
        uint256 fee = hook.feeNow();
        assertGe(fee, 300);
        assertLe(fee, 4000);
        assertLe(fee, lastFee, "fee rose");
        lastFee = fee;
        uint256 collected = hook.collected();
        assertGe(collected, lastCollected, "collected fell");
        lastCollected = collected;
        assertEq(hook.openedAt(), start);
        assertTrue(hook.initialized());
        (,,, uint24 lp) = manager.getSlot0(key.toId());
        assertEq(lp, 12500);
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 48
    function invariantHookNeverRevertsAndManagerSettles() public view {
        assertEq(handler.hookReverts(), 0, "a hook callback reverted a swap or liquidity action");
        assertEq(handler.managerReverts(), 0, "the manager rejected a bounded handler action");
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
contract ExtendedInvariantIMDSecondTest is ExtendedInvariantBase {
    function imdIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
contract ExtendedInvariantIMDFirstTest is ExtendedInvariantBase {
    function imdIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}
