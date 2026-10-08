# Local verification record

Executed for this deliverable with the root Foundry configuration (Solidity 0.8.26, Cancun, optimizer 200, via IR, no bytecode metadata hash).

| Check | Result |
|---|---|
| `forge build` | Passed. Compiler 0.8.26. |
| `forge test -vv` | **28 passed, 0 failed, 1 skipped**. The skip is the mainnet-fork suite when no fork is selected. |
| `forge fmt --check` | Passed. |
| `python3 tools/check_launch.py` | Passed: manifest discriminator, pool terms, names, constructor ABI, permission list, creation/runtime sizes and prohibited-opcode scan. |
| Supplied protected Hook and Token tests | **11 passed, 0 failed, 0 skipped** using unmodified copies in a temporary project, with the compiled creation code and explicit test-only factory/token probes. No supplied input files were edited. This is local evidence, not independent admission authority. |
| Mainnet-fork attempt | **Not executed successfully**: `forge test --match-contract MainnetForkTest --fork-url https://rpc.flashbots.net --fork-block-number 26140740 -vv` failed while obtaining RPC state with HTTP 504. Other public endpoints returned HTTP 403 or 504. No successful fork result is claimed. |

Fuzz coverage: 1,000 runs each for transfers/supply conservation, schedule monotonicity and bounds, and real PoolManager swaps across rate/time/direction/exactness; 256 partial-fill runs. The stateful invariant ran **64 sequences / 2,048 calls with zero reverts**, mixing swaps, time advancement and sweeps. Both IMD currency orderings, all four swap modes, tick crossings, liquidity gaps and PoolManager protocol fees are covered locally. The int256-min input request with a small price-limited fill also passes.

The protected checks needed a forge-std revision with `fail(string)` support. The final pinned vendored revision includes it, so the supplied tests compile without local alterations.

Bytecode sizes from the final artifacts:

| Contract | Creation code including constructor arguments | Runtime |
|---|---:|---:|
| SIMDTEST | 2,427 bytes | 1,503 bytes |
| SIMDTESTHook | 11,122 bytes | 10,297 bytes |

The hook remains well below EIP-3860's 49,152-byte init-code limit and EIP-170's 24,576-byte runtime limit. Opcode scans skip PUSH data and find no SELFDESTRUCT, DELEGATECALL or CALLCODE in either application contract.

Forge's source lints still emit notices about bounded integer casts, the intentionally timestamp-based fee schedule, and external calls around sweep. Their relevant conditions and reentrancy defenses are recorded in [SECURITY_REVIEW.md](SECURITY_REVIEW.md); a successful build is not a claim that every automated warning is absent.

Before release, run the included fork suite against a working Ethereum archive RPC at a recent block, verify real IMD settlement and treasury receipts, and obtain the network's separate contributor review. This assignment did not broadcast transactions, sign with a funded wallet, or deploy to Ethereum.
