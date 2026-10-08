# SIMDTEST launch

SIMDTEST is an ordinary fixed-supply ERC-20 paired with IMD on Ethereum mainnet. `SIMDTESTHook` charges a separate swap fee in IMD, starting at 40% and declining to 3% over one hour. All proceeds belong to the immutable SIMD Hackathon treasury, **0x3dd5f73dd1a4e62630fad3909673f130ad429985**. Neither contract has an owner, admin, setter, pause, upgrade, proxy, subsequent mint, or transfer tax.

## Build and tests

```sh
forge build
forge test
forge fmt --check
python3 tools/check_launch.py
```

Solidity **0.8.26**, Cancun, optimizer 200 runs, via IR, `bytecode_hash = "none"`. All dependencies are vendored as ordinary files with pinned provenance and licenses in [DEPENDENCIES.md](DEPENDENCIES.md). No network, dependency installation, FFI, filesystem cheatcode permissions, or environment variables are required by the default tests. A compatible Foundry installation and the pinned compiler are prerequisites.

Tests use the actual vendored Uniswap v4 PoolManager locally, a standard mock IMD at its prescribed address, and directly CREATE2-deployed production hooks. They cover both currency orderings, all four swap modes, the opening and standing rates, rounding, partial fills, tick crossings, liquidity gaps, empty pools, token-only liquidity, settlement rollback, permission bits, unauthorized callbacks, failed and reentrant sweeps, runtime opcode restrictions, fuzzing and stateful conservation invariants.

The separate mainnet tests require an explicitly selected fork:

```sh
forge test --match-contract MainnetForkTest \
  --fork-url <MAINNET_ARCHIVE_RPC_URL> --fork-block-number <RECENT_BLOCK> -vv
```

They use the **real deployed PoolManager and IMD**, with fresh SIMDTEST/hook deployments and test liquidity; `deal` funds only the simulated wallet. Without a fork they are explicitly skipped. A selected fork with missing contracts or a wrong chain fails. No RPC credentials are committed. This assignment's attempted fork run failed at the RPC with HTTP 504; **no successful live-fork result is claimed**. Repeat at a recent block before release. See [verification](docs/VERIFICATION.md).

## Contracts and deployment parameters

| Parameter | Fixed value |
|---|---|
| Chain | Ethereum mainnet, chain ID 1 |
| PoolManager constructor argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| IMD currency constant | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Treasury constant | `0x3dd5f73dd1a4e62630fad3909673f130ad429985` |
| Token name / symbol | SIMDTEST / SIMDTEST |
| Supply / decimals | `10^27` minor units / 18 |
| LP fee / tick spacing | 12500 (1.25%) / 60 |
| Opening / standing hook fee | 4000 / 300 basis points |
| Decay duration | 3600 seconds from pool initialization |
| Hook permission bits | `0x20cc` = 8396 |

`SIMDTEST()` mints the entire one billion tokens to its deployer. The launch factory allocates **900 million (90%) to the pool and 100 million (10%) through its Merkle distributor**. This resolves the brief's inconsistent phrase about all tokens going to the pool in favor of the explicit mandatory distribution requirements. There is no remaining allocation or burn address, and neither delivered contract sends the swarm allocation. The factory handles its own `remainderTo` configuration; this project requires no remainder recipient.

`SIMDTESTHook(IPoolManager manager, address token)` permanently fixes its manager and launch token. The pair and treasury are compile-time constants, with no constructor choice or subsequent setter. Its initialization callback accepts only this token/IMD pair, this hook, fee 12500 and spacing 60. It records the start time once. The swap callbacks only accept PoolManager. Liquidity addition/removal and donations have no hook callbacks or fees.

[launch.json](launch.json) uses **`"kind": "univ4_hook"`** and names **SIMDTESTHook itself**. Arguments are `["$poolManager", "$token"]`, resolved by the launch factory in constructor order. Permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`; all others are false. The constructor enforces the permission bits in the deployed address. No dynamic LP fee flag, LP fee override or `updateDynamicLPFee` call is used.

The manifest's `initialPrice = "79228162514264337593543950336"` is provenance only. **The launch factory computes the actual opening price from the economics.** The hook does not constrain that price, establish a price oracle, or determine the factory's liquidity range.

## Fee arithmetic and custody

For elapsed seconds `t` after initialization:

```text
rateBps = 300 + floor(3700 * (3600 - t) / 3600), t < 3600
rateBps = 300,                                t >= 3600
```

Before initialization `feeNow()` reports 4000. At 1800 seconds it reports 2150; at 3599 it reports 301; at and after 3600 it reports 300. Timestamp zero is a valid initialization time. The rate rounds down to whole basis points and token fees round down to minor units. Tiny swaps can have zero fee.

The fee is a fraction of **gross IMD**: total IMD paid by a buyer, or IMD paid out by the pool before a seller's fee deduction. Let `r = feeNow()`, `D = 10000`, and `P` be the pool's IMD delta magnitude, including the static LP fee when IMD is input.

| Trade | Hook delta | Full-fill fee |
|---|---|---|
| Buy, exact IMD input `A` | BeforeSwap, specified IMD | `floor(A*r/D)`; remaining input goes to AMM |
| Buy, exact SIMDTEST output | AfterSwap, unspecified IMD | `floor(P*r/(D-r))`; trader pays `P+fee` |
| Sell, exact SIMDTEST input | AfterSwap, unspecified IMD | `floor(P*r/D)`; trader receives `P-fee` |
| Sell, exact net IMD output `A` | BeforeSwap, specified IMD | `floor(A*r/(D-r))`; AMM outputs `A+fee` |

Thus 40% of gross IMD corresponds to approximately 66.67% of net IMD, and 3% of gross corresponds to approximately 3.0928% of net. Frontends must quote this gross/net distinction correctly. Integer conversions favor the trader by at most one minor unit relative to the gross-fee expression for partial input fills.

When IMD is specified, `SpecifiedAmount` reads PoolManager state and repeats canonical v4 swap arithmetic to quote the actual fill. It accounts for price limits, initialized ticks, liquidity gaps and protocol fees. The fee is recomputed on the filled portion; unused input and unavailable output incur no fee. An empty pool collects no fee. This is necessary because AfterSwap can only return a delta in the unspecified currency. The quote performs no nested swap and never changes pool state. Its gas usage scales with tick traversal, in addition to the manager's own traversal.

All fees accrue as **IMD-denominated ERC-6909 claims owned by the hook inside PoolManager**. These are claims on IMD, not conversion to ETH or an unrelated reward token. No IMD or SIMDTEST transfer happens during hook fee collection. This preserves settlement on a fresh manager that has not yet received a buyer's IMD. Ordinary SIMDTEST transfers, including transfers to and from PoolManager, are always untaxed.

- `openedAt()` returns the pool's one-time initialization timestamp.
- `feeNow()` returns the current basis-point rate.
- `pending()` returns IMD claims plus any loose IMD donated to the hook.
- `collected()` returns cumulative swap fees; sweeps do not reduce it and donations do not increase it.
- `sweep()` lets anyone redeem all claims and forward loose IMD **only to treasury**. There is no caller reward or caller-selected recipient.

Sweep burns claims and takes IMD to treasury in a dedicated manager unlock. A failed treasury transfer reverts only the sweep, restoring its claims. It does not block later swaps. A reentrant sweep, or a sweep while PoolManager is already unlocked, returns zero without changing claims; retry after settlement. Empty and repeated sweeps are harmless. Tokens other than IMD accidentally sent to the hook have no recovery path.

## Launch and operation

1. Verify mainnet, the canonical PoolManager address and the real IMD code/transfer behavior. Complete the live-fork rehearsal and independent contributor review before funding.
2. Deploy SIMDTEST through the factory and verify it holds exactly `10^27` units. Resolve the hook's token argument to that actual address.
3. Mine CREATE2 using the **actual deploying factory address**, constructor-encoded creation code and permission mask `0x20cc`. `script/HookDeployer.sol` supplies a tested, optional `mine`/`predict`/`deploy` helper; it is neither a proxy nor required in the launch path. A salt mined for the helper is not a salt for a different factory. The manifest deploys the hook directly.
4. Deploy the hook, initialize its pool and seed policy liquidity **atomically** through the factory. The required initialization permission prevents opening a pool against a not-yet-deployed hook. Atomic deployment/initialization prevents someone else starting the fee clock between transactions. The optional helper alone does not perform the factory's atomic launch.
5. Check the actual pool key/price, total supply, 90/10 allocation, permission mask, treasury, start time, and runtime bytes against the pinned build. Factory/LP operators handle position custody, ranges and liquidity; the hook has no LP management power.
6. Publish addresses and verified sources. Anyone can call `sweep()` when economical. Monitor `pending`, `collected`, treasury receipts and liquidity. Treasury key custody belongs to its existing operator. No after-launch setup or admin action is needed or possible.

The hook imposes no trader/router allowlist, time gate, wallet cap or administrative swap rejection. Normal PoolManager requirements still apply: valid prices, sufficient funds, successful ERC-20 settlement and signed 128-bit representable **final deltas including fees**. A positive specified fee can overflow PoolManager's int256 addition for an exact-output request extremely close to `int256.max`; such an unrepresentable request remains outside the supported input domain. Gas exhaustion and external protocol failures cannot be prevented by a hook. IMD is assumed to remain a standard, non-rebasing, non-taxed token compatible with v4.

The implementation follows the explicitly requested [launch #909 pattern](docs/PROVENANCE.md), with constant SIMDTEST parameters and treasury. [Security review](docs/SECURITY_REVIEW.md) records this assignment's local review and remaining release responsibilities; it is not an independent security audit.
