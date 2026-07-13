from Crypto.Hash import keccak

trades = [
    dict(trade_id=1, amount=1000, size_bps=100, entry_price=60000, exit_price=61000, timestamp=1000000),
    dict(trade_id=2, amount=2000, size_bps=200, entry_price=61000, exit_price=62000, timestamp=1000100),
    dict(trade_id=3, amount=1500, size_bps=150, entry_price=62000, exit_price=61500, timestamp=1000200),
    dict(trade_id=4, amount=3000, size_bps=300, entry_price=61500, exit_price=63000, timestamp=1000300),
    dict(trade_id=5, amount=2500, size_bps=250, entry_price=63000, exit_price=62500, timestamp=1000400),
]

FIELDS = ["trade_id", "amount", "size_bps", "entry_price", "exit_price", "timestamp"]

def pack(trades):
    buf = b""
    for t in trades:
        for f in FIELDS:
            buf += int(t[f]).to_bytes(32, "big")
    return buf

packed = pack(trades)
assert len(packed) == 5 * 6 * 32 == 960, len(packed)

h = keccak.new(digest_bits=256)
h.update(packed)
digest = h.digest()
print("full digest (32 bytes):", digest.hex())

truncated = digest[1:]  # drop top byte -> low 31 bytes
field_val = int.from_bytes(truncated, "big")
print("truncated field (31 bytes):", truncated.hex())
print("field_val decimal:", field_val)
print("field_val hex: 0x" + format(field_val, "x"))

BN254_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617
assert field_val < BN254_MODULUS, "does not fit modulus (shouldn't happen for 248-bit value)"
print("fits BN254 modulus:", field_val < BN254_MODULUS)
