# Agent Trust Protocol — Demo Trading Agent

An end-to-end demo of the full protocol loop against the live Anvil fork:
a validator gets bonded, a fresh agent registers itself, runs a small mock
trading strategy, notarizes each trade as an on-chain receipt, has a subset
of those receipts validator-attested (which is what actually builds
reputation), and finally the validator cranks emissions and claims its AGT
work reward.

## Prerequisites

- The Anvil fork of Base Sepolia already running at `http://127.0.0.1:8545`
  (chainId `84532`), with the protocol already deployed per
  `deployments/anvil-fork-84532.json` at the repo root.
- The repo-root `.env` has `PRIVATE_KEY` for the deployer/owner account (the
  same one used to deploy — it holds the AGT premine and owns the contracts).
- Node 18+.

This demo does **not** start or manage Anvil / the deployment — it assumes
both are already up, exactly as described in the task.

## Install & run

```bash
cd demo
npm install
npm run demo
```

(`agent-trust-sdk` is pulled in via a `file:../sdk` dependency — if you've
changed the SDK source, rebuild it first: `cd ../sdk && npx tsc -p tsconfig.json`.)

## What it does

1. **Validator setup** (as deployer/owner) — generates a fresh validator
   wallet, funds it with local ETH (`anvil_setBalance`), transfers it
   `2 * Staking.MIN_BOND` AGT, approves `Staking`, and calls
   `Staking.bond(...)`. Confirms `validators(addr).active == true`.

2. **Agent registration** — generates a fresh agent wallet, funds it with
   local ETH, and registers it on `AgentRegistryV2` via the SDK
   (`AgentTrust.registerAgent`), paying the ETH registration fee. No AGT is
   ever touched by the agent — by design, the registry's agent-facing lane
   is fee-in-ETH only.

3. **Mock trading loop** — 10 ticks of a simple simulated random-walk price
   series with a naive momentum strategy (buy on a >0.5% uptick, sell on a
   >0.5% downtick, else hold). After each tick the trade record is passed to
   `AgentTrust.logReceipt(...)`, which canonicalizes it to a `keccak256` hash
   and notarizes that hash on-chain (self-reported lane — free, no
   validators required).

4. **Validator attestation** — the validator wallet (via a second
   `AgentTrust` instance, its own key) calls `attestReceipt` on a subset of
   the trade receipts (every other non-HOLD trade, 4 of 10 in a typical run).
   This is the validator-attested lane that actually feeds `reputation()`.

5. **Final profile** — reads back `AgentRegistryV2.reputation(agentId)` and
   the full agent struct (self vs. attested receipt counts, disputes).

6. **Optional finale (reward claim)** — warps chain time forward 2 days
   (`evm_increaseTime` + `evm_mine`), calls the permissionless
   `Emission.mintPending()` to crank the halving drip, then
   `RewardDistributor.syncFromEmission(...)` to bucket that epoch's emission
   into the validator/delegator pools, and finally has the validator call
   `claimValidator(epoch)` — printing the AGT amount claimed. This step is
   wrapped in try/catch and will say so plainly (not fake success) if
   anything about the reward path doesn't cooperate on a given run.

## SDK changes

`sdk/src/index.ts` and `sdk/src/abi.ts` gained `attestReceipt(agentId,
receiptHash)` and `getAttestor(agentId, receiptHash)` on the `AgentTrust`
class — the SDK previously only supported the self-reported `logReceipt`
lane. Both are backwards compatible additions (no existing method
signatures changed). Contract addresses continue to be passed in via
`AgentTrustConfig`, never hardcoded into the SDK.

## Files

- `src/config.ts` — loads `deployments/anvil-fork-84532.json` + repo-root
  `.env`, sets up viem clients, and Anvil-only RPC helpers
  (`anvil_setBalance`, `evm_increaseTime`).
- `src/abi-extra.ts` — minimal ABIs for `Staking`, `AGTToken` (ERC20),
  `Emission`, and `RewardDistributor` — the protocol-admin / validator-side
  surface that's intentionally outside the agent-facing SDK's scope.
- `src/run-demo.ts` — the demo itself.
