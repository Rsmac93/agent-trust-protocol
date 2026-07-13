// Test suite for the execution-integrity circuit, using the 5-trade PoC
// example from docs/circuits/execution_integrity.noir.
//
// NOTE: Noir `bin` packages discover `#[test]` functions via `mod`
// declarations rooted at src/main.nr (there is no automatic `tests/`
// directory scan, unlike Rust). This file is that module. A byte-identical
// copy is kept at tests/execution_integrity_test.nr for discoverability /
// review purposes — see the README for details. If you edit one, edit both.
//
// The expected ledger hash below was computed off-circuit with Python +
// pycryptodome, replicating the exact packing this circuit uses:
//   for each of the 5 trades, in order: trade_id, amount, size_bps,
//   entry_price, exit_price, timestamp — each written as a 32-byte
//   big-endian word, concatenated with no separators (960 bytes total) —
//   then keccak256'd, then the top byte of the 32-byte digest is dropped to
//   get a 31-byte (248-bit) value that fits the BN254 scalar field.
//
// Reference script: circuits/execution_integrity/scripts/compute_ref_hash.py
//   Full keccak256 digest: 0x4ab29d9162a43935d034aaeeedf48189ee37548ecdfee0fbf32b0310e2f44bb9
//   Truncated (low 31 bytes) field value:
//     0xb29d9162a43935d034aaeeedf48189ee37548ecdfee0fbf32b0310e2f44bb9
use crate::{Trade, main, MAX_RECEIPT_CANDIDATES};

// The precomputed keccak256(pack(trades)) for the 5-trade PoC ledger below,
// truncated to 31 bytes as described above.
global EXPECTED_LEDGER_HASH: Field =
    0xb29d9162a43935d034aaeeedf48189ee37548ecdfee0fbf32b0310e2f44bb9;

fn poc_trades() -> [Trade; 5] {
    [
        Trade {
            trade_id: 1,
            amount: 1000,
            size_bps: 100,
            entry_price: 60000,
            exit_price: 61000,
            timestamp: 1000000,
        },
        Trade {
            trade_id: 2,
            amount: 2000,
            size_bps: 200,
            entry_price: 61000,
            exit_price: 62000,
            timestamp: 1000100,
        },
        Trade {
            trade_id: 3,
            amount: 1500,
            size_bps: 150,
            entry_price: 62000,
            exit_price: 61500,
            timestamp: 1000200,
        },
        Trade {
            trade_id: 4,
            amount: 3000,
            size_bps: 300,
            entry_price: 61500,
            exit_price: 63000,
            timestamp: 1000300,
        },
        Trade {
            trade_id: 5,
            amount: 2500,
            size_bps: 250,
            entry_price: 63000,
            exit_price: 62500,
            timestamp: 1000400,
        },
    ]
}

fn poc_receipt_hashes() -> [Field; MAX_RECEIPT_CANDIDATES] {
    // Slot 0 holds the real precomputed ledger hash; the rest are dummy /
    // zero, mirroring the "all other slots are dummy/zero" note in the
    // pseudocode's PoC example section.
    let mut hashes: [Field; MAX_RECEIPT_CANDIDATES] = [0; MAX_RECEIPT_CANDIDATES];
    hashes[0] = EXPECTED_LEDGER_HASH;
    hashes
}

#[test]
fn test_execution_integrity_happy_path() {
    let trades = poc_trades();
    let expected_receipt_hashes = poc_receipt_hashes();

    main(
        trades,
        0x123, // receipt_hash_start (dummy, non-degenerate)
        0x456, // receipt_hash_end (dummy, != receipt_hash_start)
        100, // strategy_param_min
        500, // strategy_param_max
        5, // trade_count_expected
        expected_receipt_hashes,
    );
}

#[test(should_fail)]
fn test_fails_when_size_bps_out_of_range() {
    let mut trades = poc_trades();
    // Push trade 0 below strategy_param_min (100).
    trades[0].size_bps = 50;
    let expected_receipt_hashes = poc_receipt_hashes();

    main(trades, 0x123, 0x456, 100, 500, 5, expected_receipt_hashes);
}

#[test(should_fail)]
fn test_fails_when_trade_count_mismatched() {
    let trades = poc_trades();
    let expected_receipt_hashes = poc_receipt_hashes();

    main(trades, 0x123, 0x456, 100, 500, 4, expected_receipt_hashes);
}

#[test(should_fail)]
fn test_fails_when_ledger_hash_not_a_member() {
    let trades = poc_trades();
    // All-zero receipt hash candidates: the real ledger hash is not among
    // them, so membership must fail.
    let expected_receipt_hashes: [Field; MAX_RECEIPT_CANDIDATES] = [0; MAX_RECEIPT_CANDIDATES];

    main(trades, 0x123, 0x456, 100, 500, 5, expected_receipt_hashes);
}

#[test(should_fail)]
fn test_fails_when_receipt_range_degenerate() {
    let trades = poc_trades();
    let expected_receipt_hashes = poc_receipt_hashes();

    // receipt_hash_start == receipt_hash_end, which must be rejected.
    main(trades, 0x123, 0x123, 100, 500, 5, expected_receipt_hashes);
}
