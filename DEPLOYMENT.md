# Base Sepolia Deployment Walkthrough

End-to-end guide to deploy the Agent Trust Protocol to Base Sepolia (chain id
**84532**), verify every contract on Basescan, and run a live smoke test.

The Foundry pieces are already built and were validated locally against Anvil
(full deploy + wiring post-conditions + register-agent/log-receipt smoke test all
pass). The only things you must do by hand are: create a wallet, get faucet ETH,
and paste in an RPC + Basescan API key.

---

## 1. Create a fresh deployer wallet

Use a brand-new key that has only ever held testnet funds. Never reuse a mainnet key.

```bash
cast wallet new
```

This prints an `Address` and a `Private key`. Copy both.

> Security: the private key controls the deployer (and initially owns every
> contract). For a testnet run a raw key in `.env` is fine. For anything
> touching real value, use a hardware wallet or `cast wallet import` (encrypted
> keystore) instead of a plaintext `.env`.

## 2. Store secrets in `.env`

```bash
cp .env.example .env
```

Edit `.env`:

- `PRIVATE_KEY` = the fresh key from step 1 (keep the `0x` prefix)
- `BASE_SEPOLIA_RPC_URL` = `https://sepolia.base.org` (public) or an Alchemy/
  Infura Base Sepolia URL (more reliable for verification)
- `BASESCAN_API_KEY` = from https://basescan.org/myapikey (free account)
- Leave the role addresses (`TREASURY`, `ARBITER`, …) blank to default them to
  the deployer for a solo testnet run, or set real addresses/multisigs.

`.env` is git-ignored — confirm it never gets committed (`git status` should not
list it).

## 3. Get free Base Sepolia ETH

The deployer needs ~0.02–0.05 ETH for gas. Use any of:

- Coinbase Developer Platform faucet: https://portal.cdp.coinbase.com/products/faucet (Base Sepolia)
- Alchemy faucet: https://www.alchemy.com/faucets/base-sepolia
- If a faucet requires mainnet ETH to qualify, get Sepolia L1 ETH from a
  Sepolia faucet, then bridge to Base Sepolia at https://superbridge.app (Testnet).

Verify the balance landed:

```bash
source .env
cast balance $(cast wallet address --private-key $PRIVATE_KEY) --rpc-url base_sepolia --ether
```

## 4. Deploy + verify (one command)

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url base_sepolia \
  --broadcast \
  --verify \
  -vvv
```

- `--verify` submits source to Basescan automatically as each contract lands
  (uses `[etherscan]` in `foundry.toml`).
- The script deploys in dependency order — **TeamVesting, AGTToken** (via a
  predicted-address trick to break the token⇄vesting cycle), **Staking,
  AgentRegistryV2, RewardDistributor, Emission, DisputeModule** — then wires
  everything: `setMinter` (locked to Emission), `setSlasher` → DisputeModule,
  `setStaking`, `setDisputeModule`, `setRewardDistributor`, `setRegistry`,
  `setEmission`. It ends with on-chain `require`s asserting all wiring is
  correct, so a botched deploy reverts instead of leaving a half-wired system.
- The address summary prints in the `== Logs ==` block. Copy all seven
  addresses into your deployments record.

If verification is flaky (public RPCs sometimes rate-limit), re-run just the
verification for a single contract:

```bash
forge verify-contract <ADDRESS> contracts/AGTToken.sol:AGTToken \
  --chain 84532 --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" <VESTING> <TREASURY> <LIQUIDITY>)
```

(Constructor args per contract: AGTToken `(teamVesting, treasury, liquidity)`;
Staking `(token)`; AgentRegistryV2 `(feeTreasury)`; RewardDistributor
`(token, staking)`; Emission `(token, rewardDistributor, builderPool)`;
DisputeModule `(registry, staking, arbiter, insuranceFund)`; TeamVesting
`(token, beneficiary)`.)

## 5. Live smoke test — register an agent + log a receipt

Put the deployed `AgentRegistryV2` address into `.env` as `REGISTRY`, then:

```bash
source .env
forge script script/SmokeTest.s.sol:SmokeTest \
  --rpc-url base_sepolia \
  --broadcast \
  -vvv
```

It registers an agent (paying the ETH `registrationFee`), logs a self-reported
receipt, reads the state back, and asserts `principal`, `active`,
`selfReceipts == 1`, and the receipt timestamp — printing `SMOKE TEST PASSED`.

Confirm on Basescan: open the `AgentRegistryV2` address → Events → you should see
`AgentRegistered` and `ReceiptLogged`.

---

## Deployment order & wiring (reference)

```
TeamVesting(token=predicted, beneficiary)
AGTToken(teamVesting, treasury, liquidity)   # premines 2.1M: 1.05M vest / 0.84M treasury / 0.21M liq
Staking(token)
AgentRegistryV2(feeTreasury)
RewardDistributor(token, staking)
Emission(token, stakingPool=RewardDistributor, builderPool)
DisputeModule(registry, staking, arbiter, insuranceFund)

token.setMinter(emission, locked=true)
staking.setSlasher(disputeModule)
registry.setStaking(staking)
registry.setDisputeModule(disputeModule)
registry.setRewardDistributor(rewardDistributor)
rewardDistributor.setRegistry(registry)
rewardDistributor.setEmission(emission)
```

Note: Emission's `genesis` (and therefore the whole halving schedule and epoch
clock) is set to the block timestamp at Emission deployment. TeamVesting's
`start` is set at its own deployment. Deploy when you actually want the clocks
to start.
```
