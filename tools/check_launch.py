#!/usr/bin/env python3
"""Offline manifest/artifact consistency and executable-opcode checks. Run after forge build."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
m = json.loads((root / 'launch.json').read_text())
assert m['kind'] == 'univ4_hook'
assert m['hook']['contract'] == 'SIMDTESTHook'
assert m['hook']['constructorArgs'] == ['$poolManager', '$token']
assert m['hook']['permissions'] == ['beforeInitialize', 'beforeSwap', 'afterSwap',
                                    'beforeSwapReturnDelta', 'afterSwapReturnDelta']
assert m['token'] == {'contract': 'SIMDTEST', 'name': 'SIMDTEST', 'symbol': 'SIMDTEST', 'decimals': 18}
assert m['pool'] == {'pairedCurrency': '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7',
                     'fee': 12500, 'tickSpacing': 60, 'initialPrice': '79228162514264337593543950336'}
for contract, args in [('SIMDTEST', []), ('SIMDTESTHook', ['address', 'address'])]:
    artifact = json.loads((root / 'out' / (contract + '.sol') / (contract + '.json')).read_text())
    constructor = next(a for a in artifact['abi'] if a['type'] == 'constructor')
    assert [i['type'] for i in constructor['inputs']] == args
    creation = bytes.fromhex(artifact['bytecode']['object'].removeprefix('0x'))
    runtime = bytes.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    assert len(creation) + 32 * len(args) <= 49152
    assert 0 < len(runtime) <= 24576
    i = 0
    while i < len(runtime):
        op = runtime[i]
        assert op not in (0xf2, 0xf4, 0xff), f'{contract}: prohibited opcode {op:#x} at {i}'
        i += 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
    print(f'{contract}: init code including arguments {len(creation) + 32 * len(args)} bytes; '
          f'runtime {len(runtime)} bytes; opcode scan passed')
print('Manifest and constructor ABI checks passed; declared permission mask = 8396 (0x20cc).')
