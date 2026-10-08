// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";

contract SIMDTESTTest is Test {
    SIMDTEST token;

    function setUp() public {
        token = new SIMDTEST();
    }

    function testLaunchSupplyAndMetadata() public view {
        assertEq(token.name(), "SIMDTEST");
        assertEq(token.symbol(), "SIMDTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzTransfersConserveSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        address recipient = makeAddr("recipient");
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        vm.prank(recipient);
        token.transfer(recipient, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function testAllowanceAndFailureAreAtomic() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.approve(spender, 100);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 100);
        assertEq(token.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.balanceOf(recipient), 100);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(recipient);
        vm.expectRevert();
        token.transfer(address(this), 102);
    }

    function testNoPrivilegedEntrypoints() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "owner()",
            "pause()",
            "setFee(uint256)",
            "upgradeTo(address)",
            "initialize(address)",
            "transferOwnership(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), 1));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
