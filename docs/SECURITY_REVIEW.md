# Local security review

This is the implementer's review against the supplied protected checks and security references, not a separate contributor audit. No deployment or transaction broadcast was performed. An independent release review and a successful recent mainnet-fork rehearsal remain operational responsibilities.

## Reviewed properties

| Area | Review and evidence |
|---|---|
| Privileges | Token exposes only standard ERC-20 operations. Hook configuration is constant/immutable. No owner, setter, upgrade, proxy, selfdestruct, delegatecall or callcode in application runtime; executable-opcode scan and forbidden-selector tests. |
| Initialization | Exactly one matching SIMDTEST/IMD key at fee 12500 and spacing 60. Only immutable PoolManager can invoke callbacks. A separate initialized boolean handles timestamp zero. Invalid pools, unauthorized callers, replay and timestamp-zero tests. |
| CREATE2 | Constructor validates all fourteen permission bits. Tests mine and directly deploy the production creation code, check predicted address and reject incorrect bits. Manifest names the hook directly. |
| Fee schedule | Opening/steady rates and 3600-second period cannot change. Fuzzed monotonicity and bounds, rounding and endpoints; no fee dependence on sender or hook data. Builders can slightly influence timestamp; there is no randomness. |
| Currency choice | Positive hook deltas apply only to IMD, in both sorted currency positions and all exactness/direction combinations. Token transfers are untouched. Real local PoolManager settlement tests verify final zero deltas. |
| BeforeSwap return delta / NoOp risk | A fee-only hook: it never takes all input as a substitute for an AMM swap. Canonical v4 math determines actual fills; empty pools accrue no fee, and price-limited unused input is uncharged. Partial-fill fuzzing, liquidity-gap/tick-crossing tests and protocol-fee tests. No arbitrary nested swap or external quoter. |
| Accounting | Each returned fee delta is balanced by a manager IMD claim minted to the hook. Swap failure reverts both. Stateful randomized trades, time advancement and sweeps enforce `pending + paid = collected`, pair conservation, fixed supply and zero outstanding manager deltas. |
| Reserve timing | Accrual only mints claims, with no token/treasury calls. A buy on a fresh token-only manager holding zero IMD passes before input settlement. |
| Sweep | Fixed treasury, permissionless trigger, no bounty. Guard remains set across manager unlock and loose-token transfer. Claims burn before payout, failures roll back atomically. Reentry and calls during another unlock return zero. Failure cannot block swap accrual. |
| External token assumptions | Only the fixed IMD is collected; it must remain an ordinary non-rebasing, non-taxed v4-compatible token. Failed recipient transfers are tested. Fee-on-transfer behavior is not supported by this pool architecture. |
| Rounding and casts | Arithmetic uses at most signed-128-bit settlement-sized quote budgets, with larger request magnitudes safely obtained in unchecked negation. Rate is at most 4000 and gross-up denominator at least 6000. Fee casts therefore fit int128. Timestamp subtraction is guarded. Tiny-trade and huge-request partial-fill checks accompany the main fuzz suite. |
| LP fee | Static 12500 tier and zero override. No call to `updateDynamicLPFee`. Pool state assertions verify the LP fee after swaps, including manager protocol-fee scenarios. |

## Limits and residual risks

- The read-only fill quote repeats v4 traversal, and must remain consistent with the pinned manager storage layout and arithmetic. It adds gas proportional to crossed bitmap words/ticks. It is internal code, not an external oracle or independently upgradable dependency. The vendored manager and mainnet manager must be compatible; fork validation is still owed.
- Swaps remain subject to protocol amount/price validation, output availability, ERC-20 settlement, gas and signed-128-bit final deltas. Positive specified hook fees can overflow PoolManager's `int256` addition on an exact-output request within a fee of `int256.max`. Supported router amounts should be in the representable settlement domain. The hook provides no admin or economic trade gate; it cannot make malformed protocol inputs valid.
- Integer rounding gives tiny trades a zero fee. Splitting trades can save minor-unit dust. With 18-decimal IMD this is not a material economic advantage at ordinary trade sizes.
- The hook pins its launch token in its constructor. Atomic factory deployment and initialization are required to prevent anyone else starting the clock or setting the opening price before the launch. No factory-specific administrative authority is introduced.
- Claims remain pending if IMD transfers to treasury are blocked or manager reserves cannot be redeemed. Sweep rolls back safely. Monitoring and retries are operational tasks; there is no alternate recipient or rescue authority.
- Fees remain IMD exposure until the treasury receives them. No automatic sale or ETH conversion exists, as required by the brief. The treasury's key control and future actions are outside the contracts.
- Accidental non-IMD token transfers to the hook cannot be rescued. No arbitrary token withdrawal is included.
- No separate human or independent contributor audit, formal proof, Slither or Mythril result is claimed. Automated local verification is evidence only. Dependency revisions and MIT attribution for the referenced launch #909 code are included.
