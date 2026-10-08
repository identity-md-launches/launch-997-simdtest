// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";

/// @dev Test-only settlement router. Production routers must also enforce deadlines and slippage.
contract TestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return
            abi.decode(
                manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(params))), (BalanceDelta)
            );
    }

    function liquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(params))), (BalanceDelta)
        );
    }

    function sweepInsideUnlock(PoolKey memory key) external returns (uint256) {
        return abi.decode(manager.unlock(abi.encode(uint8(2), msg.sender, key, bytes(""))), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Only manager");
        (uint8 op, address payer, PoolKey memory key, bytes memory payload) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        if (op == 2) return abi.encode(SIMDTESTHook(address(key.hooks)).sweep());
        BalanceDelta delta;
        if (op == 0) delta = manager.swap(key, abi.decode(payload, (SwapParams)), "");
        else (delta,) = manager.modifyLiquidity(key, abi.decode(payload, (ModifyLiquidityParams)), "");
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
