/**
 * voltpass-agentkit — live end-to-end integration test.
 *
 * Proves withVoltPassLogging() actually auto-logs VoltPass receipts for
 * AgentKit wallet-provider calls, against a real local Anvil chain + fresh
 * VoltPass contract deployment. Not a test-framework test — a plain script,
 * run with:
 *
 *   npx tsx agentkit-adapter/test/integration-test.ts
 *
 * Prerequisites (see README / repo DEPLOYMENT.md for the patterns this
 * reuses):
 *   1. `anvil --chain-id 84532 --port 8545` running in the background.
 *   2. Contracts freshly deployed to it via `forge script script/Deploy.s.sol
 *      --broadcast --rpc-url http://127.0.0.1:8545` (this script reads the
 *      resulting addresses from broadcast/Deploy.s.sol/84532/run-latest.json
 *      — it does NOT touch the tracked deployments/anvil-fork-84532.json).
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  createPublicClient, createWalletClient, http, parseEther, type Address, type Hex,
} from 'viem';
import { baseSepolia } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { ViemWalletProvider } from '@coinbase/agentkit';
import { VoltPass } from 'voltpass-sdk';
import { withVoltPassLogging } from '../src/index.js';

// @coinbase/agentkit fires a best-effort, non-awaited usage-analytics beacon
// on wallet-provider construction. In this offline/local-anvil test
// environment that beacon call rejects (network unreachable / non-2xx), and
// since AgentKit doesn't catch it internally, Node treats it as an unhandled
// rejection and would otherwise crash the process. It has nothing to do with
// the behavior under test, so swallow it here.
process.on('unhandledRejection', (err) => {
  const msg = err instanceof Error ? err.message : String(err);
  if (msg.includes('HTTP error! status')) return; // AgentKit's analytics beacon
  throw err;
});

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..');
const RPC_URL = 'http://127.0.0.1:8545';
const CHAIN_ID = 84532;

// Anvil's default test account keys (as printed at anvil startup for this run).
const DEPLOYER_PK: Hex = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const AGENT_PRINCIPAL_PK: Hex = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'; // anvil account #1
const TRADING_KEY_PK: Hex = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a'; // anvil account #2
const DUMMY_RECIPIENT: Address = '0x000000000000000000000000000000000000dEaD';

const publicClient = createPublicClient({ chain: baseSepolia, transport: http(RPC_URL) });

let failures = 0;
function check(label: string, cond: boolean, detail?: string) {
  if (cond) {
    console.log(`PASS - ${label}`);
  } else {
    failures++;
    console.log(`FAIL - ${label}${detail ? ` (${detail})` : ''}`);
  }
}

/** Reads the deployed contract addresses from the forge broadcast artifact
 *  produced by `forge script script/Deploy.s.sol --broadcast`, for the
 *  freshest run against our local anvil chain. Does not touch the tracked
 *  deployments/anvil-fork-84532.json file. */
function loadDeploymentFromBroadcast(): { AgentRegistryV2: Address } {
  const file = path.join(REPO_ROOT, 'broadcast', 'Deploy.s.sol', String(CHAIN_ID), 'run-latest.json');
  const run = JSON.parse(readFileSync(file, 'utf8')) as {
    transactions: Array<{ contractName: string; contractAddress: string }>;
  };
  const found: Record<string, Address> = {};
  for (const t of run.transactions) {
    if (t.contractName && t.contractAddress) {
      found[t.contractName] = t.contractAddress as Address;
    }
  }
  if (!found.AgentRegistryV2) {
    throw new Error('AgentRegistryV2 address not found in broadcast artifact');
  }
  // Persist our own untracked copy for inspection / re-runs.
  const outDir = path.join(__dirname);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(
    path.join(outDir, '.deployment.json'),
    JSON.stringify({ network: 'anvil local (chainId 84532)', rpc: RPC_URL, ...found }, null, 2),
  );
  return { AgentRegistryV2: found.AgentRegistryV2 };
}

async function setBalance(address: Address, ethAmount = '10') {
  const wei = parseEther(ethAmount);
  await publicClient.request({
    method: 'anvil_setBalance' as never,
    params: [address, `0x${wei.toString(16)}`] as never,
  });
}

async function main() {
  console.log('voltpass-agentkit integration test\n' + '─'.repeat(60));

  const { AgentRegistryV2: registryAddress } = loadDeploymentFromBroadcast();
  console.log(`AgentRegistryV2: ${registryAddress}`);

  // --- Step 1: register a test agent via the SDK directly -----------------
  const agentAccount = privateKeyToAccount(AGENT_PRINCIPAL_PK);
  await setBalance(agentAccount.address, '10');
  const voltpassAsAgent = new VoltPass({
    registryAddress,
    privateKey: AGENT_PRINCIPAL_PK,
    rpcUrl: RPC_URL,
  });
  const { agentId } = await voltpassAsAgent.registerAgent({
    name: 'agentkit-adapter-integration-test',
    model: 'test',
    capabilities: ['defi-trading'],
  });
  console.log(`Registered agentId: ${agentId} (principal ${agentAccount.address})`);

  // --- Step 2: construct a viem WalletClient for a second Anvil account, ---
  // wrap it in AgentKit's ViemWalletProvider, then wrap THAT with
  // withVoltPassLogging(), pointing logging at the agent principal above.
  const tradingAccount = privateKeyToAccount(TRADING_KEY_PK);
  await setBalance(tradingAccount.address, '10');
  const tradingWalletClient = createWalletClient({
    account: tradingAccount, chain: baseSepolia, transport: http(RPC_URL),
  });
  // @coinbase/agentkit@0.10.4 pins its own nested viem (2.38.3) that is
  // structurally but not nominally identical to this workspace's viem
  // (2.55.1) — TS sees two distinct `WalletClient` types even though
  // they're runtime-compatible. Cast at the one call site that crosses the
  // package boundary; the adapter's own src/index.ts never touches viem
  // types directly, so it isn't affected.
  // ViemWalletProvider builds its OWN internal read-only public client for
  // gas estimation etc., defaulting to `gasConfig?.rpcUrl || process.env.RPC_URL
  // || http()` (the chain's default public RPC) if not told otherwise — it
  // does NOT infer this from the walletClient's own transport. Without this,
  // it silently estimates gas against the real Base Sepolia network instead
  // of our local Anvil chain. Point it at our local RPC explicitly.
  const viemProvider = new ViemWalletProvider(tradingWalletClient as never, { rpcUrl: RPC_URL });
  const wrappedProvider = withVoltPassLogging(viemProvider, {
    registryAddress,
    agentId,
    loggerPrivateKey: AGENT_PRINCIPAL_PK,
    rpcUrl: RPC_URL,
    onLogError: (err, txHash) => console.error(`  [onLogError] txHash=${txHash}:`, err),
  });

  const voltpassReader = new VoltPass({ registryAddress, rpcUrl: RPC_URL });

  async function selfReceiptsCount(): Promise<number> {
    const info = await voltpassReader.getAgent(agentId);
    return info.selfReceipts;
  }

  // Small delay to let a fire-and-forget log settle before we read state.
  const settle = () => new Promise((r) => setTimeout(r, 1500));

  // --- Step 3-5: sendTransaction --------------------------------------------
  const before1 = await selfReceiptsCount();
  const recipientBalBefore1 = await publicClient.getBalance({ address: DUMMY_RECIPIENT });

  const txHash1 = await wrappedProvider.sendTransaction({
    to: DUMMY_RECIPIENT,
    value: parseEther('0.01'),
  });
  await publicClient.waitForTransactionReceipt({ hash: txHash1 as Hex });
  await settle();

  const recipientBalAfter1 = await publicClient.getBalance({ address: DUMMY_RECIPIENT });
  check(
    'sendTransaction: underlying ETH transfer landed on-chain',
    recipientBalAfter1 > recipientBalBefore1,
    `before=${recipientBalBefore1} after=${recipientBalAfter1}`,
  );

  const after1 = await selfReceiptsCount();
  check(
    'sendTransaction: VoltPass receipt auto-logged (selfReceipts +1), no explicit logReceipt() call',
    after1 === before1 + 1,
    `before=${before1} after=${after1}`,
  );

  // --- Step 6: read-only getBalance must NOT log -----------------------------
  const beforeRead = await selfReceiptsCount();
  await wrappedProvider.getBalance();
  await settle();
  const afterRead = await selfReceiptsCount();
  check(
    'getBalance (read-only, non-logged method): selfReceipts unchanged',
    afterRead === beforeRead,
    `before=${beforeRead} after=${afterRead}`,
  );

  // --- Step 7: repeat with nativeTransfer -------------------------------------
  const before2 = await selfReceiptsCount();
  const recipientBalBefore2 = await publicClient.getBalance({ address: DUMMY_RECIPIENT });

  const txHash2 = await wrappedProvider.nativeTransfer(DUMMY_RECIPIENT, parseEther('0.01').toString());
  await publicClient.waitForTransactionReceipt({ hash: txHash2 as Hex });
  await settle();

  const recipientBalAfter2 = await publicClient.getBalance({ address: DUMMY_RECIPIENT });
  check(
    'nativeTransfer: underlying ETH transfer landed on-chain',
    recipientBalAfter2 > recipientBalBefore2,
    `before=${recipientBalBefore2} after=${recipientBalAfter2}`,
  );

  const after2 = await selfReceiptsCount();
  check(
    'nativeTransfer: VoltPass receipt auto-logged (selfReceipts +1), no explicit logReceipt() call',
    after2 === before2 + 1,
    `before=${before2} after=${after2}`,
  );

  console.log('─'.repeat(60));
  if (failures > 0) {
    console.log(`RESULT: ${failures} assertion(s) FAILED`);
    process.exit(1);
  } else {
    console.log('RESULT: all assertions PASSED');
    process.exit(0);
  }
}

main().catch((err) => {
  console.error('FATAL:', err);
  process.exit(1);
});
