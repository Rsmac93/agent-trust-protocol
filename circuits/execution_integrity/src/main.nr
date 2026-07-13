// Circuit: Execution Integrity
//
// Proves "N trades were executed consistent with strategy parameters" (e.g.
// "all 5 trades had position sizes between 1% and 5% of portfolio") without
// revealing the trade ledger, and binds the ledger to an on-chain-notarized
// receipt hash via keccak256.
//
// This is a direct implementation of docs/circuits/execution_integrity.noir
// for the N = 5 PoC case. See that file for full design rationale, and see
// README.md in this directory for the full byte-packing spec and worked
// example.
//
// Byte packing scheme (must match the off-chain receipt logger exactly):
//   For each trade, in ledger order, we serialize six fields as 32-byte
//   big-endian words, in this exact order:
//     trade_id | amount | size_bps | entry_price | exit_price | timestamp
//   giving 6 * 32 = 192 bytes per trade, and 5 * 192 = 960 bytes total for
//   the full ledger. This is equivalent to Solidity's
//   `abi.encode(trade_id, amount, size_bps, entry_price, exit_price,
//   timestamp)` for a struct of six uint256-compatible fields (each Field
//   element is written as a 32-byte big-endian word, same as EVM word
//   encoding), concatenated per trade with no separators. `timestamp` is a
//   `u64` in the Trade struct but is padded out to a full 32-byte big-endian
//   word for hashing, so it lines up byte-for-byte with a `uint256`-encoded
//   on-chain receipt field.
//
// Field-encoding of the digest:
//   keccak256 produces a 32-byte (256-bit) digest, which does not always fit
//   in a BN254 Field element (~254-bit modulus). We take the low 31 bytes
//   (248 bits) of the big-endian digest as the canonical Field
//   representation — i.e. `field_hash = uint256(keccak256(data)) &
//   ((1 << 248) - 1)`, dropping the top byte. This is a standard truncation
//   used when bridging a 256-bit EVM hash into a scalar field, at the cost
//   of 8 bits of collision resistance (248-bit instead of 256-bit). The
//   off-chain receipt logger (and the test below) must apply the exact same
//   truncation before pushing `expected_receipt_hashes` on-chain.
use keccak256::keccak256;

mod tests;

global NUM_TRADES: u32 = 5;
pub global MAX_RECEIPT_CANDIDATES: u32 = 8;
global FIELDS_PER_TRADE: u32 = 6;
global BYTES_PER_FIELD: u32 = 32;
global TRADE_BYTES: u32 = FIELDS_PER_TRADE * BYTES_PER_FIELD; // 192
global LEDGER_BYTES: u32 = NUM_TRADES * TRADE_BYTES; // 960

// A "Trade" as stored in the agent's private ledger. `size_bps` is the
// position size as basis points of portfolio NAV at trade time (e.g. 250 =
// 2.50%), which is what strategy_param_min/max bound.
pub struct Trade {
    trade_id: Field,
    amount: Field,
    size_bps: Field,
    entry_price: Field,
    exit_price: Field,
    timestamp: u64,
}

fn main(
    // --- private inputs ---
    trades: [Trade; NUM_TRADES],
    // --- public inputs ---
    receipt_hash_start: pub Field,
    receipt_hash_end: pub Field,
    strategy_param_min: pub Field,
    strategy_param_max: pub Field,
    trade_count_expected: pub Field,
    expected_receipt_hashes: pub [Field; MAX_RECEIPT_CANDIDATES],
) {
    // 1. Trade count check. Fixed-size PoC: N == trade_count_expected is
    //    asserted directly against the compile-time array length.
    assert(trade_count_expected == NUM_TRADES as Field);

    // 2. Per-trade position-sizing check, and range-bound sanity.
    assert(strategy_param_min != strategy_param_max);
    for i in 0..NUM_TRADES {
        let sz = trades[i].size_bps;
        assert((sz == strategy_param_min) | strategy_param_min.lt(sz));
        assert((sz == strategy_param_max) | sz.lt(strategy_param_max));
    }

    // 3. Receipt-hash binding: hash the full ledger and prove it is one of
    //    the receipt hashes the on-chain PerformancePassport range commits
    //    to.
    let ledger_hash = pack_and_hash(trades);

    let mut is_member = false;
    for i in 0..MAX_RECEIPT_CANDIDATES {
        if ledger_hash == expected_receipt_hashes[i] {
            is_member = true;
        }
    }
    assert(is_member);

    // 4. Sanity: the claimed range bounds are non-degenerate.
    assert(receipt_hash_start != receipt_hash_end);
}

// keccak256 over the packed (trade_id, amount, size_bps, entry_price,
// exit_price, timestamp) tuples, concatenated in ledger order. Each field is
// serialized as a 32-byte big-endian word (see module doc comment for the
// exact layout). Returns the truncated 31-byte digest re-packed into a
// single Field (see module doc comment), so it can be compared directly
// against `expected_receipt_hashes`.
fn pack_and_hash(trades: [Trade; NUM_TRADES]) -> Field {
    let mut bytes: [u8; LEDGER_BYTES] = [0; LEDGER_BYTES];

    for i in 0..NUM_TRADES {
        let trade = trades[i];
        let base = i * TRADE_BYTES;
        write_field_be(&mut bytes, base, trade.trade_id);
        write_field_be(&mut bytes, base + BYTES_PER_FIELD, trade.amount);
        write_field_be(&mut bytes, base + 2 * BYTES_PER_FIELD, trade.size_bps);
        write_field_be(&mut bytes, base + 3 * BYTES_PER_FIELD, trade.entry_price);
        write_field_be(&mut bytes, base + 4 * BYTES_PER_FIELD, trade.exit_price);
        write_field_be(&mut bytes, base + 5 * BYTES_PER_FIELD, trade.timestamp as Field);
    }

    let digest: [u8; 32] = keccak256(bytes, LEDGER_BYTES);

    // Drop the top byte (8 bits) of the big-endian digest so the remaining
    // 31 bytes (248 bits) fit canonically inside the BN254 scalar field.
    let mut truncated: [u8; 31] = [0; 31];
    for j in 0..31 {
        truncated[j] = digest[j + 1];
    }
    Field::from_be_bytes(truncated)
}

// Writes `value` into `bytes[offset..offset+32]` as a big-endian 32-byte
// word (EVM word encoding).
fn write_field_be(bytes: &mut [u8; LEDGER_BYTES], offset: u32, value: Field) {
    let be: [u8; 32] = value.to_be_bytes();
    for j in 0..32 {
        bytes[offset + j] = be[j];
    }
}
