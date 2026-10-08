// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SpecifiedAmount} from "./SpecifiedAmount.sol";

/// @dev Adapted from launch #909; provenance and license: docs/PROVENANCE.md.
/// @notice Immutable, address-neutral IMD fee hook for exactly one SIMDTEST/IMD launch pool.
/// @dev Fees are floor(gross IMD * feeNow / 10_000). See README for gross/net definitions.
contract SIMDTESTHook is IUnlockCallback {
    uint256 public constant STEADY_FEE = 300;
    uint256 public constant OPENING_FEE = 4000;
    uint256 public constant OPENING_SECONDS = 3600;
    uint24 public constant LP_FEE = 12500;
    int24 public constant TICK_SPACING = 60;
    address public constant treasury = address(bytes20(hex"3dd5f73dd1a4e62630fad3909673f130ad429985"));

    IPoolManager public immutable poolManager;
    Currency public constant imd =
        Currency.wrap(address(bytes20(hex"d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7")));
    address public immutable token;
    uint256 public openedAt;
    uint256 public collected;
    bool public initialized;
    bool private sweeping;

    error OnlyPoolManager();
    error InvalidConfiguration();
    error InvalidPool();
    error AlreadyInitialized();
    error UnexpectedUnlock();

    event Opened(uint256 timestamp);
    event FeeAccrued(uint256 amount);
    event Swept(uint256 amount);

    constructor(IPoolManager manager_, address token_) {
        address imd_ = Currency.unwrap(imd);
        if (address(manager_) == address(0) || imd_ == address(0) || token_ == address(0) || imd_ == token_) {
            revert InvalidConfiguration();
        }
        poolManager = manager_;
        token = token_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (initialized) revert AlreadyInitialized();
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        address pair = Currency.unwrap(imd);
        if (
            !((a == pair && b == token) || (a == token && b == pair)) || key.fee != LP_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert InvalidPool();
        initialized = true;
        openedAt = block.timestamp;
        emit Opened(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    function feeNow() public view returns (uint256) {
        if (!initialized || block.timestamp <= openedAt) return OPENING_FEE;
        uint256 elapsed = block.timestamp - openedAt;
        if (elapsed >= OPENING_SECONDS) return STEADY_FEE;
        return STEADY_FEE + (OPENING_FEE - STEADY_FEE) * (OPENING_SECONDS - elapsed) / OPENING_SECONDS;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        bool imd0 = key.currency0 == imd;
        if ((exactIn == params.zeroForOne) != imd0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        uint256 rate = feeNow();
        uint256 requested;
        unchecked {
            requested = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        }
        // A successful v4 settlement fits signed 128-bit currency deltas. Capping only the
        // read-only quote also permits arbitrarily large requests that stop at a price limit.
        uint256 budget =
            requested > uint256(uint128(type(int128).max)) ? uint256(uint128(type(int128).max)) : requested;
        uint256 reserve = exactIn ? budget * rate / 10_000 : budget * rate / (10_000 - rate);
        SwapParams memory quote = params;
        quote.amountSpecified = exactIn ? -int256(budget - reserve) : int256(budget + reserve);
        uint256 fill = SpecifiedAmount.filled(poolManager, key, quote);
        uint256 fee;
        if (exactIn) {
            fee = requested == budget && fill == budget - reserve ? reserve : fill * rate / (10_000 - rate);
        } else {
            fee = fill * rate / 10_000;
        }
        _accrue(fee);
        // No LP-fee override. Positive delta charges only IMD, never the other currency.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        bool imd0 = key.currency0 == imd;
        if (((params.amountSpecified < 0) == params.zeroForOne) == imd0) {
            return (IHooks.afterSwap.selector, 0);
        }
        int256 amount = imd0 ? int256(delta.amount0()) : int256(delta.amount1());
        uint256 rate = feeNow();
        // Negative IMD delta is a buy's pool input; positive is a sell's gross pool output.
        uint256 fee = amount < 0 ? uint256(-amount) * rate / (10_000 - rate) : uint256(amount) * rate / 10_000;
        _accrue(fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    function _accrue(uint256 fee) private {
        if (fee == 0) return;
        collected += fee;
        poolManager.mint(address(this), imd.toId(), fee);
        emit FeeAccrued(fee);
    }

    /// @notice Includes fee claims and any IMD transferred directly to this contract.
    function pending() external view returns (uint256) {
        return poolManager.balanceOf(address(this), imd.toId()) + imd.balanceOfSelf();
    }

    /// @notice Permissionless. Calls made during an unlock or a sweep do nothing; retry after settlement.
    function sweep() external returns (uint256 amount) {
        if (sweeping || TransientStateLibrary.isUnlocked(poolManager)) return 0;
        sweeping = true;
        amount = abi.decode(poolManager.unlock(""), (uint256));
        uint256 loose = imd.balanceOfSelf();
        if (loose != 0) imd.transfer(treasury, loose);
        amount += loose;
        sweeping = false;
        emit Swept(amount);
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        if (!sweeping) revert UnexpectedUnlock();
        uint256 amount = poolManager.balanceOf(address(this), imd.toId());
        if (amount != 0) {
            poolManager.burn(address(this), imd.toId(), amount);
            poolManager.take(imd, treasury, amount);
        }
        return abi.encode(amount);
    }
}
