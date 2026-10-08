// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Optional plain CREATE2 helper. The launch factory can deploy the hook directly instead.
contract HookDeployer {
    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) public pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function mine(address deployer, IPoolManager manager, address token, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 codeHash =
            keccak256(abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, token)));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = predict(deployer, salt, codeHash);
            if (HookFlags.matches(predicted, HookFlags.SIMDTEST)) return (salt, predicted);
        }
        revert("No salt in range");
    }

    function deploy(IPoolManager manager, address token, bytes32 salt) external returns (SIMDTESTHook) {
        return new SIMDTESTHook{salt: salt}(manager, token);
    }
}
