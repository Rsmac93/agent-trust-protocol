/**
 * Agent Trust Protocol — end-to-end demo trading agent.
 *
 * Phases:
 *   0. Setup   — deployer bonds a validator wallet on Staking (as owner/deployer).
 *   1. Agent   — a fresh wallet registers on AgentRegistryV2 via the SDK, runs a
 *                small mock trading loop, and self-reports a receipt per trade.
 *   2. Attest  — the validator attests a subset of those receipts (this is what
 *                actually builds on-chain reputation).
 *   3. Finale  — (optional, best-effort) warp time, crank emission, and have the
 *                validator claim its work reward in AGT.
 *
 * Run: npm run demo   (from demo/), with the anvil fork + deployment already live.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { formatEther, parseEther, type Hex, type Abi } from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { AgentTrust, canonicalHash, DEMO_ATTESTOR_PRIVATE_KEY } from 'agent-trust-protocol-sdk';
import {
  publicClient, deployerWallet, deployerAccount, deployment, walletFor, setBalance, increaseTime,
} from './config.js';
import {
  ERC20_ABI, STAKING_ABI, EMISSION_ABI, REWARD_DISTRIBUTOR_ABI, REGISTRY_ADMIN_ABI,
} from './abi-extra.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..');

/** Loads a forge build artifact (ABI + bytecode) for ad hoc deployment.
 *  PerformancePassport isn't part of Deploy.s.sol yet, so the demo deploys
 *  it itself using the same forge `out/` artifacts forge test/build produce. */
function loadArtifact(name: string): { abi: Abi; bytecode: Hex } {
  const file = path.join(REPO_ROOT, 'out', `${name}.sol`, `${name}.json`);
  const json = JSON.parse(readFileSync(file, 'utf8')) as { abi: Abi; bytecode: { object: Hex } };
  return { abi: json.abi, bytecode: json.bytecode.object };
}

const log = (...args: unknown[]) => console.log(...args);
const hr = () => console.log('─'.repeat(72));
const section = (title: string) => {
  hr();
  console.log(`  ${title}`);
  hr();
};

async function main() {
  section('PHASE 0 — validator setup (deployer/owner)');

  const validatorPk: Hex = generatePrivateKey();
  const validatorAccount = privateKeyToAccount(validatorPk);
  const validatorWallet = walletFor(validatorPk);
  log(`validator wallet:  ${validatorAccount.address}`);

  await setBalance(validatorAccount.address, '5');
  log('  funded validator with 5 local ETH (anvil_setBalance)');

  const minBond = await publicClient.readContract({
    address: deployment.Staking, abi: STAKING_ABI, functionName: 'MIN_BOND',
  });
  const selfBond = minBond * 2n; // comfortably above the activation floor
  log(`  Staking.MIN_BOND = ${formatEther(minBond)} AGT; bonding ${formatEther(selfBond)} AGT`);

  let tx = await deployerWallet.writeContract({
    address: deployment.AGTToken, abi: ERC20_ABI, functionName: 'transfer',
    args: [validatorAccount.address, selfBond], account: deployerAccount, chain: deployerWallet.chain,
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  log(`  deployer -> validator: transferred ${formatEther(selfBond)} AGT  (tx ${tx})`);

  tx = await validatorWallet.writeContract({
    address: deployment.AGTToken, abi: ERC20_ABI, functionName: 'approve',
    args: [deployment.Staking, selfBond], account: validatorAccount, chain: validatorWallet.chain,
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  log(`  validator approved Staking for ${formatEther(selfBond)} AGT  (tx ${tx})`);

  tx = await validatorWallet.writeContract({
    address: deployment.Staking, abi: STAKING_ABI, functionName: 'bond',
    args: [selfBond, 500], // 5% commission
    account: validatorAccount, chain: validatorWallet.chain,
  });
  const bondReceipt = await publicClient.waitForTransactionReceipt({ hash: tx });
  log(`  validator bonded (tx ${tx}, block ${bondReceipt.blockNumber})`);

  const validatorState = await publicClient.readContract({
    address: deployment.Staking, abi: STAKING_ABI, functionName: 'validators',
    args: [validatorAccount.address],
  });
  log(`  Staking.validators(validator) => selfBond=${formatEther(validatorState[0])} AGT, active=${validatorState[2]}`);
  if (!validatorState[2]) throw new Error('validator failed to activate');

  section('PHASE 1 — demo trading agent: wallet + registration');

  const agentPk: Hex = generatePrivateKey();
  const agentAccount = privateKeyToAccount(agentPk);
  log(`agent wallet:      ${agentAccount.address}`);

  await setBalance(agentAccount.address, '2');
  log('  funded agent with 2 local ETH (anvil_setBalance)');

  const agentTrust = new AgentTrust({
    network: 'baseSepolia',
    registryAddress: deployment.AgentRegistryV2,
    privateKey: agentPk,
    rpcUrl: process.env.RPC_URL ?? 'http://127.0.0.1:8545',
  });

  const { agentId, txHash: regTx, metadataHash } = await agentTrust.registerAgent({
    name: 'DemoMomentumBot',
    description: 'Demo agent: simple momentum strategy over a simulated price feed.',
    model: 'claude-sonnet-5',
    capabilities: ['defi-trading', 'momentum-strategy'],
    endpoint: 'local://demo-agent',
  });
  log(`  registered as agentId=${agentId}  metadataHash=${metadataHash}`);
  log(`  registration tx: ${regTx}`);

  // validator-side SDK handle, used only for attestReceipt in phase 2
  const validatorTrust = new AgentTrust({
    network: 'baseSepolia',
    registryAddress: deployment.AgentRegistryV2,
    privateKey: validatorPk,
    rpcUrl: process.env.RPC_URL ?? 'http://127.0.0.1:8545',
  });

  section('PHASE 2 — mock trading loop (10 iterations) + receipt logging + attestation');

  // Simulated price series: a mildly noisy random walk seeded for reproducibility.
  let seed = 42;
  const rand = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };

  let price = 100;
  let position = 0; // units held
  let cash = 10_000;
  const prices: number[] = [price];

  interface TradeRecord {
    iteration: number;
    action: 'BUY' | 'SELL' | 'HOLD';
    price: number;
    qty: number;
    positionAfter: number;
    cashAfter: number;
  }

  const trades: { record: TradeRecord; receiptHash: Hex; logTx: Hex; attested: boolean; attestTx?: Hex }[] = [];

  for (let i = 1; i <= 10; i++) {
    // simulate next tick: +/- up to 3%, slight upward drift
    const pctMove = (rand() - 0.45) * 0.06;
    price = Math.max(1, price * (1 + pctMove));
    prices.push(price);

    // simple momentum strategy: compare to previous tick
    const prev = prices[prices.length - 2]!;
    let action: TradeRecord['action'] = 'HOLD';
    let qty = 0;
    if (price > prev * 1.005) {
      action = 'BUY';
      qty = 10;
      cash -= qty * price;
      position += qty;
    } else if (price < prev * 0.995) {
      action = 'SELL';
      qty = Math.min(10, position);
      if (qty > 0) {
        cash += qty * price;
        position -= qty;
      } else {
        action = 'HOLD';
      }
    }

    const record: TradeRecord = {
      iteration: i, action, price: Number(price.toFixed(4)), qty,
      positionAfter: position, cashAfter: Number(cash.toFixed(2)),
    };

    const { receiptHash, txHash: logTx } = await agentTrust.logReceipt({
      agentId,
      action: `trade-${action.toLowerCase()}`,
      payload: record,
    });

    log(`  [${i.toString().padStart(2, '0')}] price=${record.price.toFixed(2)}  ${action.padEnd(4)} qty=${qty}  pos=${position}  cash=${record.cashAfter}`);
    log(`       receiptHash=${receiptHash}`);
    log(`       logReceipt tx=${logTx}`);

    const t = { record, receiptHash, logTx, attested: false as boolean, attestTx: undefined as Hex | undefined };
    trades.push(t);

    // validator attests every other trade that wasn't a HOLD (a realistic
    // "spot-check a subset" pattern — attestation is what builds reputation)
    if (action !== 'HOLD' && i % 2 === 0) {
      const { txHash: attestTx } = await validatorTrust.attestReceipt(agentId, receiptHash);
      t.attested = true;
      t.attestTx = attestTx;
      log(`       ATTESTED by validator (tx ${attestTx})`);
    }
  }

  const attestedCount = trades.filter((t) => t.attested).length;
  log(`\n  ${trades.length} receipts logged, ${attestedCount} attested by the validator.`);

  section('PHASE 3 — final agent profile');

  const profile = await agentTrust.getAgent(agentId);
  log(`  principal:        ${profile.principal}`);
  log(`  active:           ${profile.active}`);
  log(`  selfReceipts:     ${profile.selfReceipts}`);
  log(`  attestedReceipts: ${profile.attestedReceipts}`);
  log(`  disputes:         ${profile.disputes}`);
  log(`  reputation():     ${profile.reputation.toString()}`);

  section('PHASE 4 (optional) — emission crank + validator reward claim');

  try {
    const attestEpoch = await publicClient.readContract({
      address: deployment.Emission, abi: EMISSION_ABI, functionName: 'currentEpoch',
    });
    log(`  attestations were recorded in emission epoch ${attestEpoch}`);

    log('  warping chain time forward 2 days (evm_increaseTime + mine)...');
    await increaseTime(2 * 24 * 60 * 60);

    tx = await deployerWallet.writeContract({
      address: deployment.Emission, abi: EMISSION_ABI, functionName: 'mintPending',
      account: deployerAccount, chain: deployerWallet.chain,
    });
    await publicClient.waitForTransactionReceipt({ hash: tx });
    const epochsMinted = await publicClient.readContract({
      address: deployment.Emission, abi: EMISSION_ABI, functionName: 'epochsMinted',
    });
    log(`  Emission.mintPending() done (tx ${tx}); epochsMinted=${epochsMinted}`);

    tx = await deployerWallet.writeContract({
      address: deployment.RewardDistributor, abi: REWARD_DISTRIBUTOR_ABI, functionName: 'syncFromEmission',
      args: [365n], account: deployerAccount, chain: deployerWallet.chain,
    });
    await publicClient.waitForTransactionReceipt({ hash: tx });
    log(`  RewardDistributor.syncFromEmission(365) done (tx ${tx})`);

    const workReward = await publicClient.readContract({
      address: deployment.RewardDistributor, abi: REWARD_DISTRIBUTOR_ABI, functionName: 'validatorWorkReward',
      args: [attestEpoch, validatorAccount.address],
    });
    log(`  validator's computed work reward for epoch ${attestEpoch}: ${formatEther(workReward)} AGT`);

    const balBefore = await publicClient.readContract({
      address: deployment.AGTToken, abi: ERC20_ABI, functionName: 'balanceOf', args: [validatorAccount.address],
    });

    tx = await validatorWallet.writeContract({
      address: deployment.RewardDistributor, abi: REWARD_DISTRIBUTOR_ABI, functionName: 'claimValidator',
      args: [attestEpoch], account: validatorAccount, chain: validatorWallet.chain,
    });
    await publicClient.waitForTransactionReceipt({ hash: tx });

    const balAfter = await publicClient.readContract({
      address: deployment.AGTToken, abi: ERC20_ABI, functionName: 'balanceOf', args: [validatorAccount.address],
    });
    const claimed = balAfter - balBefore;
    log(`  validator claimed reward (tx ${tx})`);
    log(`  AGT balance: ${formatEther(balBefore)} -> ${formatEther(balAfter)}  (claimed ${formatEther(claimed)} AGT)`);
  } catch (err) {
    log('  finale skipped/failed — not weakening the demo to hide this:');
    log(`  ${(err as Error).message}`);
  }

  section('PHASE 5 — performance passport: agent publishes a verified profit claim');

  // v1's PerformancePassport verifies claims via StubVerifier: a designated
  // off-chain "attestor" signs (claimType, publicInputs) in place of a real
  // ZK proof. The SDK's submitClaim() signs with a hardcoded demo attestor
  // key, so we deploy StubVerifier wired to that same address.
  const demoAttestor = privateKeyToAccount(DEMO_ATTESTOR_PRIVATE_KEY);
  log(`  demo attestor (stand-in for a ZK verifier's off-chain signer): ${demoAttestor.address}`);

  const stubVerifierArtifact = loadArtifact('StubVerifier');
  let deployTx = await deployerWallet.deployContract({
    abi: stubVerifierArtifact.abi, bytecode: stubVerifierArtifact.bytecode,
    args: [demoAttestor.address], account: deployerAccount, chain: deployerWallet.chain,
  });
  let deployReceipt = await publicClient.waitForTransactionReceipt({ hash: deployTx });
  const verifierAddress = deployReceipt.contractAddress!;
  log(`  StubVerifier deployed at ${verifierAddress}  (tx ${deployTx})`);

  const passportArtifact = loadArtifact('PerformancePassport');
  deployTx = await deployerWallet.deployContract({
    abi: passportArtifact.abi, bytecode: passportArtifact.bytecode,
    args: [deployment.AgentRegistryV2, verifierAddress],
    account: deployerAccount, chain: deployerWallet.chain,
  });
  deployReceipt = await publicClient.waitForTransactionReceipt({ hash: deployTx });
  const passportAddress = deployReceipt.contractAddress!;
  log(`  PerformancePassport deployed at ${passportAddress}  (tx ${deployTx})`);

  tx = await deployerWallet.writeContract({
    address: deployment.AgentRegistryV2, abi: REGISTRY_ADMIN_ABI, functionName: 'setPerformancePassport',
    args: [passportAddress], account: deployerAccount, chain: deployerWallet.chain,
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  log(`  AgentRegistryV2.setPerformancePassport(${passportAddress})  (tx ${tx})`);

  const passportTrust = new AgentTrust({
    network: 'baseSepolia',
    registryAddress: deployment.AgentRegistryV2,
    passportAddress,
    privateKey: agentPk,
    rpcUrl: process.env.RPC_URL ?? 'http://127.0.0.1:8545',
  });

  log('  agent generates a mock profit claim: +12.5% over month 1 (hardcoded for demo)');
  const { txHash: claimTx, claimed } = await passportTrust.submitClaim(agentId, 1, 'PROFIT', '1250');
  log(`  submitClaim tx: ${claimTx}  (claimed=${claimed})`);

  const passportProfile = await passportTrust.getPassport(agentId);
  const latestClaim = passportProfile.claims[0];
  if (!latestClaim) throw new Error('expected a readable claim after submitClaim');
  log(`  passport.latestEpoch:  ${passportProfile.latestEpoch}`);
  log(`  passport.claim.type:   ${latestClaim.claimType}`);
  log(`  passport.claim.epoch:  ${latestClaim.epoch}`);
  log(`  passport.claim.submittedAt: ${latestClaim.submittedAt.toISOString()}`);
  log(`Passport claim published: +${(Number(latestClaim.claimData) / 100).toFixed(2)}%`);

  hr();
  console.log('DEMO COMPLETE');
  hr();
}

main().catch((err) => {
  console.error('DEMO FAILED:', err);
  process.exit(1);
});
