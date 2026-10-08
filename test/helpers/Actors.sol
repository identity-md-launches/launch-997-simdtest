// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";

/// @dev Test-only actors around the pool: a router that forwards caller-chosen hook data, a donor
/// that pushes ERC-6909 IMD claims onto any receiver, a pool donor and a contract sweeper.
contract HookDataRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, params, hookData)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Only manager");
        (address payer, PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(data, (address, PoolKey, SwapParams, bytes));
        BalanceDelta delta = manager.swap(key, params, hookData);
        settle(key.currency0, payer, delta.amount0());
        settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function settle(Currency currency, address payer, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            require(
                IERC20Minimal(Currency.unwrap(currency))
                    .transferFrom(payer, address(manager), uint256(-int256(delta)))
            );
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint128(delta));
        }
    }
}

contract ClaimDonor is IUnlockCallback {
    IPoolManager public immutable manager;
    Currency public immutable imd;

    constructor(IPoolManager manager_, Currency imd_) {
        manager = manager_;
        imd = imd_;
    }

    /// @dev Pays `amount` of its own IMD into the manager and mints the claim to `to`.
    function donateClaims(address to, uint256 amount) external {
        manager.unlock(abi.encode(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Only manager");
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        manager.sync(imd);
        require(IERC20Minimal(Currency.unwrap(imd)).transfer(address(manager), amount));
        manager.settle();
        manager.mint(to, imd.toId(), amount);
        return "";
    }
}

contract DonateRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        manager.unlock(abi.encode(msg.sender, key, amount0, amount1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Only manager");
        (address payer, PoolKey memory key, uint256 amount0, uint256 amount1) =
            abi.decode(data, (address, PoolKey, uint256, uint256));
        manager.donate(key, amount0, amount1, "");
        pay(key.currency0, payer, amount0);
        pay(key.currency1, payer, amount1);
        return "";
    }

    function pay(Currency currency, address payer, uint256 amount) private {
        if (amount == 0) return;
        manager.sync(currency);
        require(IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount));
        manager.settle();
    }
}

contract Sweeper {
    function run(SIMDTESTHook hook) external returns (uint256) {
        return hook.sweep();
    }
}
