# Security

## Status: UNAUDITED

The contracts in this repository (`contracts/`) have **not** been
professionally audited. They are pre-audit, testnet-stage software.

**Do not deploy this to a network with real value, and do not send real
funds to any instance of these contracts.** Use Anvil/local forks or public
testnets (e.g. Base Sepolia) only, with test accounts and faucet funds.

The `AgentRegistry.sol` contract at the repo root is a superseded v1 design,
kept for reference only; `AgentRegistryV2.sol` is the current version. Neither
has been audited.

## Known design notes and trust assumptions

These are intentional, documented trade-offs in the current design — not
hidden bugs — but anyone integrating with or relying on the protocol should
be aware of them:

- **`DisputeModule` v1 centralization point.** Dispute resolution
  (`resolve()`) is decided by a single `arbiter` address, intended to be a
  multisig. This is an explicit, documented trust assumption for v1 and must
  be decentralized (e.g. bonded validator vote, optimistic
  challenge-escalation, or a Kleros-style court) before any
  trust-minimization milestone. Anyone who controls the arbiter key can
  unilaterally decide every dispute.

- **`DisputeModule` one-challenge-per-receipt limitation.** `disputeOf`
  permits exactly one challenge per `(agentId, receiptHash)`, ever. If the
  arbiter wrongly (or corruptly) rejects a legitimate challenge, that
  attestation is permanently immunized from further challenge — there is no
  appeal path in v1. This is acceptable only while the arbiter is a trusted
  multisig; a future revision must add re-challenge/appeal semantics once
  resolution is decentralized.

- **`RewardDistributor` delegator snapshot timing.** The delegated-stake
  snapshot used to compute a delegator's share of an epoch's rewards is
  taken lazily, at first-claim time for that epoch — not at a true
  per-epoch historical checkpoint. A delegator's weight is their *current*
  delegation measured against that snapshot total, so delegation changes
  between the snapshot and a claim can skew individual payouts (the
  contract's cumulative-payout caps still guarantee total distributed never
  exceeds total received). Delegators seeking exact accounting should claim
  before changing their delegation. A future revision should checkpoint
  delegations on every stake change.

- **Emission and vesting clocks start at deployment.** `Emission.genesis`
  and `TeamVesting.start` are both set to the deploying block's timestamp,
  so the halving schedule and vesting schedule begin ticking the moment
  those contracts are deployed — deploy only when you intend the clocks to
  start.

Read the NatSpec comments directly above each contract (`contracts/*.sol`)
for the full detail behind each of these notes.

## Reporting a vulnerability

Once this repository is public, please report suspected vulnerabilities
privately via [GitHub Security Advisories](../../security/advisories/new)
for this repository rather than opening a public issue.

<!-- TODO(owner): add a direct contact (email / security.txt / other channel)
     for vulnerability reports here. -->

Please do not test for vulnerabilities against any deployment other than
your own local Anvil fork or testnet instance.
