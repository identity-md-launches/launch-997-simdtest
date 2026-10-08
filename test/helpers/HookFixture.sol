// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";
import {HookDeployer} from "../../script/HookDeployer.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TestRouter} from "./TestRouter.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    address internal constant IMD = address(bytes20(hex"d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"));
    address internal constant TREASURY = address(bytes20(hex"3dd5f73dd1a4e62630fad3909673f130ad429985"));
    uint160 internal constant Q96 = 79228162514264337593543950336;
    IPoolManager internal manager;
    SIMDTEST internal token;
    SIMDTESTHook internal hook;
    TestRouter internal router;
    PoolKey internal key;

    function setupLocal(bool imdIsZero, bool seed) internal {
        manager = new PoolManager(address(this));
        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        MockERC20(IMD).mint(address(this), 1e30);
        // Explicit test fixtures force both currency orderings; these addresses are never deployment inputs.
        address tokenAt = imdIsZero ? address(uint160(IMD) + 1) : address(uint160(IMD) - 1);
        deployCodeTo("SIMDTEST.sol:SIMDTEST", tokenAt);
        token = SIMDTEST(tokenAt);
        setupHook(seed);
    }

    function setupHook(bool seed) internal {
        HookDeployer deployer = new HookDeployer();
        (bytes32 salt, address expected) =
            deployer.mine(address(deployer), manager, address(token), 0, 200_000);
        hook = deployer.deploy(manager, address(token), salt);
        assertEq(address(hook), expected);
        router = new TestRouter(manager);
        bool imd0 = IMD < address(token);
        key = PoolKey(
            Currency.wrap(imd0 ? IMD : address(token)),
            Currency.wrap(imd0 ? address(token) : IMD),
            12500,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, Q96);
        IERC20Minimal(IMD).approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        if (seed) router.liquidity(key, ModifyLiquidityParams(-600, 600, 1e25, 0));
    }

    function swapParams(bool buy, bool exactInput, uint256 amount, uint160 limit)
        internal
        view
        returns (SwapParams memory p)
    {
        p.zeroForOne = buy == (Currency.unwrap(key.currency0) == IMD);
        // Includes int256.min requests in boundary tests; production callbacks handle the absolute value unchecked.
        unchecked {
            p.amountSpecified = exactInput ? -int256(amount) : int256(amount);
        }
        p.sqrtPriceLimitX96 =
            limit == 0 ? (p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1) : limit;
    }

    function pairDelta(BalanceDelta delta) internal view returns (int256) {
        return Currency.unwrap(key.currency0) == IMD ? int256(delta.amount0()) : int256(delta.amount1());
    }

    function tokenDelta(BalanceDelta delta) internal view returns (int256) {
        return Currency.unwrap(key.currency0) == IMD ? int256(delta.amount1()) : int256(delta.amount0());
    }

    function checkSwap(bool buy, bool exactInput, uint256 amount, uint160 limit)
        internal
        returns (BalanceDelta d)
    {
        uint256 feeBefore = hook.collected();
        uint256 rate = hook.feeNow();
        uint256 traderPair = IERC20Minimal(IMD).balanceOf(address(this));
        uint256 traderToken = token.balanceOf(address(this));
        uint256 managerPair = IERC20Minimal(IMD).balanceOf(address(manager));
        uint256 managerToken = token.balanceOf(address(manager));
        d = router.swap(key, swapParams(buy, exactInput, amount, limit));
        uint256 fee = hook.collected() - feeBefore;
        int256 pd = pairDelta(d);
        int256 td = tokenDelta(d);
        assertEq(int256(IERC20Minimal(IMD).balanceOf(address(this))) - int256(traderPair), pd);
        assertEq(int256(token.balanceOf(address(this))) - int256(traderToken), td);
        uint256 gross = buy ? uint256(-pd) : uint256(pd) + fee;
        // Gross-up rounding and truncation can leave one wei of trader-favouring dust.
        assertApproxEqAbs(fee, gross * rate / 10_000, 1);
        assertLe(fee, gross * rate / 10_000);
        assertEq(
            IERC20Minimal(IMD).balanceOf(address(manager)) + IERC20Minimal(IMD).balanceOf(address(this)),
            managerPair + traderPair
        );
        assertEq(
            token.balanceOf(address(manager)) + token.balanceOf(address(this)), managerToken + traderToken
        );
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        (,,, uint24 lp) = manager.getSlot0(key.toId());
        assertEq(lp, 12500);
    }
}
