/**
 * voltpass-sdk — canonicalHash() unit tests.
 *
 * Plain script (this repo's convention — no test framework is installed;
 * see demo/src/run-demo.ts and agentkit-adapter/test/integration-test.ts
 * for the same pattern), run with:
 *
 *   npx tsx sdk/test/canonicalHash.test.ts
 *
 * Regression coverage for the bug found while building agentkit-adapter:
 * payloads containing raw bigints (tx values, gas, agentIds, ...) used to
 * throw ("Do not know how to serialize a BigInt") because JSON.stringify
 * can't serialize bigint. canonicalHash() now stringifies bigints
 * recursively before JSON.stringify.
 */
import assert from 'node:assert/strict';
import { canonicalHash } from '../src/index.js';

let failures = 0;
function check(label: string, fn: () => void) {
  try {
    fn();
    console.log(`PASS - ${label}`);
  } catch (err) {
    failures++;
    console.log(`FAIL - ${label}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

check('top-level bigint does not throw', () => {
  assert.doesNotThrow(() => canonicalHash(123n));
});

check('bigint nested in an object does not throw', () => {
  assert.doesNotThrow(() => canonicalHash({ agentId: 42n, action: 'sendTransaction' }));
});

check('bigint nested inside an array does not throw', () => {
  assert.doesNotThrow(() => canonicalHash({ args: [{ value: 10000000000000000n }] }));
});

check('deeply nested bigint (object -> array -> object) does not throw', () => {
  assert.doesNotThrow(() =>
    canonicalHash({ payload: { args: [{ tx: { value: 1n, gas: 21000n } }] } }),
  );
});

check('bigint hashes the same as the equivalent string (canonicalized before stringify)', () => {
  const a = canonicalHash({ value: 5n });
  const b = canonicalHash({ value: '5' });
  assert.equal(a, b);
});

check('canonicalHash is deterministic regardless of key order (bigint present)', () => {
  const a = canonicalHash({ agentId: 7n, action: 'nativeTransfer', txHash: '0xabc' });
  const b = canonicalHash({ txHash: '0xabc', agentId: 7n, action: 'nativeTransfer' });
  assert.equal(a, b);
});

check('canonicalHash still differs for genuinely different bigint values', () => {
  const a = canonicalHash({ value: 1n });
  const b = canonicalHash({ value: 2n });
  assert.notEqual(a, b);
});

check('plain (non-bigint) receipts still hash as before (no behavior change)', () => {
  const h = canonicalHash({ action: 'swap', payload: { amount: '10' } });
  assert.match(h, /^0x[0-9a-f]{64}$/);
});

console.log('─'.repeat(60));
if (failures > 0) {
  console.log(`RESULT: ${failures} assertion(s) FAILED`);
  process.exit(1);
} else {
  console.log('RESULT: all assertions PASSED');
  process.exit(0);
}
