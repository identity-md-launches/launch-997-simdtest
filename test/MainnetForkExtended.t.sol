// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Mainnet-fork rehearsal beyond the four basic modes: the real IMD token's transfer
/// semantics, the real treasury contract as recipient, partial fills, a token-only seed on the live
/// manager, the schedule over an hour of trading, and the live manager's own rejections.
/// @dev Select a fork with forge test --fork-url <RPC> --fork-block-number <block>. Skipped offline.
contract MainnetForkExtendedTest is HookFixture {
    using StateLibrary for IPoolManager;

    address constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 1, "Ethereum mainnet required");
        assertGt(MAINNET_MANAGER.code.length, 0, "PoolManager absent at fork block");
        assertGt(IMD.code.length, 0, "IMD absent at fork block");
        manager = IPoolManager(MAINNET_MANAGER);
        token = new SIMDTEST();
        deal(IMD, address(this), 1e27);
        setupHook(true);
    }

    function testForkRealIMDIsAPlainTokenForTheHooksAccounting() public {
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        address probe = makeAddr("probe");
        uint256 before = IERC20Metadata(IMD).balanceOf(address(this));
        assertTrue(IERC20Metadata(IMD).transfer(probe, 1e21), "transfer returned false");
        assertEq(IERC20Metadata(IMD).balanceOf(probe), 1e21, "fee on transfer would break claims");
        assertEq(before - IERC20Metadata(IMD).balanceOf(address(this)), 1e21);
        vm.prank(probe);
        assertTrue(IERC20Metadata(IMD).transfer(address(hook), 1e21));
        assertEq(hook.pending(), 1e21, "loose IMD must count as pending");
        uint256 treasuryBefore = IERC20Metadata(IMD).balanceOf(TREASURY);
        assertEq(hook.sweep(), 1e21);
        assertEq(IERC20Metadata(IMD).balanceOf(TREASURY) - treasuryBefore, 1e21);
    }

    function testForkTreasuryContractReceivesSweptClaims() public {
        assertGt(TREASURY.code.length, 0, "treasury is a contract on mainnet; ERC-20 receipt needs no hook");
        checkSwap(true, true, 500 ether, 0);
        checkSwap(false, false, 100 ether, 0);
        uint256 due = hook.pending();
        assertEq(due, hook.collected());
        uint256 before = IERC20Metadata(IMD).balanceOf(TREASURY);
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        assertEq(hook.sweep(), due);
        assertEq(IERC20Metadata(IMD).balanceOf(TREASURY) - before, due);
        assertEq(IERC20Metadata(IMD).balanceOf(anyone), 0);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(IMD).toId()), 0);
        assertEq(hook.sweep(), 0);
    }

    function testForkPartialFillsAllModes() public {
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snap = vm.snapshotState();
            bool buy = mode < 2;
            bool down = buy == (Currency.unwrap(key.currency0) == IMD);
            uint160 limit = TickMath.getSqrtPriceAtTick(down ? int24(-120) : int24(120));
            BalanceDelta d = checkSwap(buy, mode % 2 == 0, 1e26, limit);
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, limit);
            int256 specified = buy == (mode % 2 == 0) ? pairDelta(d) : tokenDelta(d);
            assertLt(uint256(specified < 0 ? -specified : specified), 1e26);
            assertGt(hook.collected(), 0);
            vm.revertToState(snap);
        }
    }

    function testForkTokenOnlySeedOnLiveManager() public {
        token = new SIMDTEST();
        setupHook(false);
        bool imd0 = IMD < address(token);
        if (imd0) router.liquidity(key, ModifyLiquidityParams(-600, -60, 1e25, 0));
        else router.liquidity(key, ModifyLiquidityParams(60, 600, 1e25, 0));
        uint256 managerIMD = IERC20Metadata(IMD).balanceOf(address(manager));
        BalanceDelta d = checkSwap(true, true, 1e22, 0);
        assertEq(pairDelta(d), -int256(1e22));
        assertEq(hook.collected(), 1e22 * 4000 / 10_000);
        assertEq(IERC20Metadata(IMD).balanceOf(address(manager)), managerIMD + 1e22);
        uint256 before = IERC20Metadata(IMD).balanceOf(TREASURY);
        assertEq(hook.sweep(), 1e22 * 4000 / 10_000);
        assertEq(IERC20Metadata(IMD).balanceOf(TREASURY) - before, 1e22 * 4000 / 10_000);
    }

    function testForkHourOfTradingThenSweep() public {
        uint256 start = hook.openedAt();
        uint256 sum;
        uint256 lastRate = 4000;
        for (uint256 i; i < 8; ++i) {
            vm.warp(start + i * 515); // the last iteration lands past the hour
            uint256 rate = hook.feeNow();
            assertLe(rate, lastRate);
            lastRate = rate;
            uint256 before = hook.collected();
            checkSwap(i % 2 == 0, (i / 2) % 2 == 0, 50 ether + i * 1 ether, 0);
            sum += hook.collected() - before;
        }
        assertEq(hook.feeNow(), 300);
        assertEq(hook.collected(), sum);
        assertEq(hook.pending(), sum);
        uint256 treasuryBefore = IERC20Metadata(IMD).balanceOf(TREASURY);
        assertEq(hook.sweep(), sum);
        assertEq(IERC20Metadata(IMD).balanceOf(TREASURY) - treasuryBefore, sum);
        assertEq(hook.pending(), 0);
        assertEq(hook.collected(), sum);
    }

    function testForkLiveManagerRejectsForeignTermsAndWrongFlags() public {
        assertEq(HookFlags.flagsOf(address(hook)), 0x20cc);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), 12500));
        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.expectRevert();
        manager.initialize(bad, Q96);
        bad = key;
        bad.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(bad, Q96);
        vm.expectRevert();
        manager.initialize(key, Q96);
        assertEq(hook.openedAt(), block.timestamp);
    }

    function testForkInvalidRequestsAreManagerRejectionsNotHookOnes() public {
        vm.expectRevert();
        router.swap(key, swapParams(true, true, 0, 0));
        vm.expectRevert();
        router.swap(key, swapParams(false, true, 1 ether, TickMath.MAX_SQRT_PRICE));
        assertEq(hook.collected(), 0);
        checkSwap(true, false, 1 ether, 0);
        assertGt(hook.collected(), 0);
    }
}
