// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Select a fork with forge test --fork-url <RPC> --fork-block-number <block>.
/// No environment reads; the default offline run reports an explicit skip.
contract MainnetForkTest is HookFixture {
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
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        manager = IPoolManager(MAINNET_MANAGER);
        token = new SIMDTEST();
        deal(IMD, address(this), 1e27);
        setupHook(true);
    }

    function testForkBuyExactInput() public {
        checkSwap(true, true, 100 ether, 0);
        checkSweep();
    }

    function testForkBuyExactOutput() public {
        checkSwap(true, false, 100 ether, 0);
        checkSweep();
    }

    function testForkSellExactInput() public {
        checkSwap(false, true, 100 ether, 0);
        checkSweep();
    }

    function testForkSellExactOutput() public {
        checkSwap(false, false, 100 ether, 0);
        checkSweep();
    }

    function testForkSteadyStateAllModes() public {
        vm.warp(hook.openedAt() + 3600);
        for (uint256 mode; mode < 4; ++mode) {
            checkSwap(mode < 2, mode % 2 == 0, 100 ether, 0);
        }
        checkSweep();
    }

    function checkSweep() internal {
        uint256 before = IERC20Metadata(IMD).balanceOf(TREASURY);
        uint256 due = hook.pending();
        assertGt(due, 0);
        assertEq(hook.sweep(), due);
        assertEq(IERC20Metadata(IMD).balanceOf(TREASURY) - before, due);
        assertEq(hook.pending(), 0);
    }
}
