// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    address public blockedRecipient;
    address public reentryTarget;
    uint256 public reentryResult;

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blockRecipient(address to) external {
        blockedRecipient = to;
    }

    function reenterOnTransfer(address target) external {
        reentryTarget = target;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blockedRecipient, "Blocked transfer");
        if (reentryTarget != address(0)) {
            (bool ok, bytes memory result) = reentryTarget.call(abi.encodeWithSignature("sweep()"));
            require(ok, "Reentry failed");
            reentryResult = abi.decode(result, (uint256));
        }
        return super.transfer(to, amount);
    }
}
