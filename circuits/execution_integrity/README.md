# Execution Integrity Circuit

Noir implementation of `docs/circuits/execution_integrity.noir`, built to a
runnable PoC for the fixed N = 5 trade case.

## Purpose

Proves "N trades were executed consistent with strategy parameters" (e.g.
"all 5 trades had position sizes between 1% and 5% of portfolio NAV")
without revealing the trade ledger, while cryptographically binding the
private ledger to a receipt hash already notarized on-chain
(`AgentRegistryV2` / `PerformancePassport.submitClaim`'s
`receiptHashRangeStart..receiptHashRangeEnd` window). This is what prevents
an agent from fabricating or cherry-picking trades after the fact — the
ledger proven here must be *exactly* the one already committed on chain.

Constraints enforced in `main`:

1. `trade_count_expected == 5` (fixed-size PoC; a variable-length version
   would sum a per-slot `valid` bitmap instead).
2. Every trade's `size_bps` falls within
   `[strategy_param_min, strategy_param_max]`.
3. `keccak256(pack(trades))`, truncated to fit the field (see below), equals
   one of the 8 `expected_receipt_hashes` slots.
4. `receipt_hash_start != receipt_hash_end` (non-degenerate range sanity
   check; the actual range-membership check against on-chain history
   happens in `PerformancePassport`, not in this circuit).

## Build & test

```bash
# one-time toolchain install (this repo was built against nargo 1.0.0-beta.22)
curl -L https://raw.githubusercontent.com/noir-lang/noirup/main/install | bash
noirup

cd circuits/execution_integrity
nargo build   # compiles the circuit, resolves the keccak256 dependency
nargo test    # runs the 5 tests in src/tests.nr
nargo info    # circuit size (ACIR opcode count)
```

Both `nargo build` and `nargo test` currently succeed:

```
[execution_integrity] Running 5 test functions
[execution_integrity] Testing tests::test_execution_integrity_happy_path ... ok
[execution_integrity] Testing tests::test_fails_when_size_bps_out_of_range ... ok
[execution_integrity] Testing tests::test_fails_when_trade_count_mismatched ... ok
[execution_integrity] Testing tests::test_fails_when_ledger_hash_not_a_member ... ok
[execution_integrity] Testing tests::test_fails_when_receipt_range_degenerate ... ok
[execution_integrity] 5 tests passed
```

`nargo info` reports **14,756 ACIR opcodes** for `main` at N = 5 — almost
entirely from the single `keccak256` call over the 960-byte packed ledger
(the range/count/membership checks are a handful of field comparisons by
comparison). This is the dominant cost noted in the source pseudocode: for
100+ trade epochs, keccak256-in-circuit becomes the proving-time
bottleneck.

## Byte packing scheme (must match the off-chain receipt logger exactly)

For each of the 5 trades, **in ledger order**, six fields are serialized as
32-byte big-endian words, in this exact order:

```
trade_id | amount | size_bps | entry_price | exit_price | timestamp
```

- 6 fields × 32 bytes = **192 bytes per trade**
- 5 trades × 192 bytes = **960 bytes total** ledger encoding
- Fields are concatenated with **no separators, no length prefixes**
- Each `Field` (including `timestamp`, which is typed `u64` in the `Trade`
  struct) is written as a full 32-byte big-endian word — i.e. byte-for-byte
  identical to Solidity's `abi.encode(trade_id, amount, size_bps,
  entry_price, exit_price, timestamp)` for a struct of six
  `uint256`-compatible fields (EVM words are 32-byte big-endian).

This is implemented in `pack_and_hash` / `write_field_be` in `src/main.nr`.
An off-circuit reference implementation, used to precompute the expected
hash for the test fixtures, lives at `scripts/compute_ref_hash.py`.

### Field-encoding of the digest

`keccak256` produces a 32-byte (256-bit) digest, which does not always fit
into a BN254 `Field` element (~254-bit modulus — roughly 1-in-4 raw digests
would overflow it). To sidestep this, the circuit (and the off-circuit
reference script) **drop the top byte** of the big-endian digest and treat
the remaining 31 bytes (248 bits) as the canonical `Field` value:

```
field_hash = uint256(keccak256(data)) & ((1 << 248) - 1)
```

This is a standard truncation technique for bridging a 256-bit EVM hash
into a scalar field element, at the cost of 8 bits of collision resistance
(248-bit instead of 256-bit — still far beyond any practical attack budget).
**The off-chain receipt logger that pushes `expected_receipt_hashes` on
AgentRegistryV2 must apply this exact same truncation**, or membership will
never hold. (An alternative used elsewhere in ZK-EVM bridges is to split the
digest into two Field elements — hi/lo 128 bits each — preserving full
256-bit collision resistance; not done here for PoC simplicity, but worth
revisiting before a production deployment.)

## Worked example (5-trade PoC)

Trades (`size_bps` 100..500, i.e. 1%-5%):

| trade_id | amount | size_bps | entry_price | exit_price | timestamp |
|---|---|---|---|---|---|
| 1 | 1000 | 100 | 60000 | 61000 | 1000000 |
| 2 | 2000 | 200 | 61000 | 62000 | 1000100 |
| 3 | 1500 | 150 | 62000 | 61500 | 1000200 |
| 4 | 3000 | 300 | 61500 | 63000 | 1000300 |
| 5 | 2500 | 250 | 63000 | 62500 | 1000400 |

Public inputs used in the happy-path test:

- `strategy_param_min = 100`, `strategy_param_max = 500`
- `trade_count_expected = 5`
- `receipt_hash_start = 0x123`, `receipt_hash_end = 0x456` (dummy,
  non-degenerate — the real on-chain range check is out of scope for this
  circuit)
- `expected_receipt_hashes[0] = 0xb29d9162a43935d034aaeeedf48189ee37548ecdfee0fbf32b0310e2f44bb9`
  (the truncated `keccak256(pack(trades))` for the table above; full 32-byte
  digest is
  `0x4ab29d9162a43935d034aaeeedf48189ee37548ecdfee0fbf32b0310e2f44bb9`),
  slots `1..8` are zero.

Reproduce the hash:

```bash
python3 -m venv /tmp/venv_keccak && /tmp/venv_keccak/bin/pip install pycryptodome
/tmp/venv_keccak/bin/python3 scripts/compute_ref_hash.py
```

## Why tests live in `src/tests.nr`

Noir `bin` packages discover `#[test]` functions by walking `mod`
declarations rooted at `src/main.nr` — there's no Cargo-style automatic
`tests/`-directory scan, and (confirmed experimentally against nargo
1.0.0-beta.22) no `#[path = "..."]` attribute support to point a `mod`
declaration at a file outside `src/`. The real, compiled test suite is
therefore `src/tests.nr`, wired in via `mod tests;` in `src/main.nr`. A
byte-identical copy is kept at `tests/execution_integrity_test.nr` purely
for discoverability/review; it is not part of the compiled module graph — if
you edit the tests, edit both files.

## Known limitations

- **Fixed N = 5.** Array lengths are compile-time constants in Noir. A real
  deployment would need one circuit per supported epoch-size bucket (e.g. 8,
  32, 128 trades), with a per-slot `valid: bool` flag to pad short ledgers
  and skip padded slots in the range/hash checks — noted but not
  implemented here, per the original pseudocode's scope.
- **keccak256 cost dominates.** ~14.7k ACIR opcodes for 5 trades, almost all
  from one `keccak256` call over 960 bytes. This scales roughly linearly
  with ledger size (more 136-byte Keccak blocks to absorb), so a 100+ trade
  epoch will make keccak256 the proving-time bottleneck, as flagged in the
  source pseudocode.
- **248-bit (not 256-bit) hash collision resistance**, from the field
  truncation described above.
- **`keccak256` is not in Noir's `std` in this compiler version.** The
  pseudocode's `dep::std::hash::keccak256` reference is out of date for
  nargo 1.0.0-beta.22, where the built-in stdlib only exposes the raw
  `keccakf1600` permutation; full byte-oriented `keccak256(bytes, len)` was
  moved to the external `noir-lang/keccak256` package (pinned here via git
  dependency at tag `v0.1.3`, itself built on `std::hash::keccakf1600`). No
  functional difference — same algorithm, same output — just a different
  import path than the docs comment currently shows.
- **No on-chain verifier wiring yet.** This PoC only exercises
  `nargo build` / `nargo test` (witness generation + constraint
  satisfaction). Generating an actual proof and Solidity verifier
  (`nargo compile` artifacts + `bb write_vk` / `bb prove` / a
  `barretenberg`-generated `Verifier.sol`) is the next step toward wiring
  this into `PerformancePassport.submitClaim`, and is out of scope for this
  PoC.
- **Public-input array (`expected_receipt_hashes: [Field; 8]`) is a fixed
  8-slot window.** A production version would need this sized (or chunked)
  to match `PerformancePassport`'s actual on-chain receipt-hash range
  width, which may differ from 8.
