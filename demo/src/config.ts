import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import {
  createPublicClient, createWalletClient, http, type Address, type Hex,
} from 'viem';
import { baseSepolia } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..');

// --- .env (repo root) -------------------------------------------------
function loadEnv(file: string): Record<string, string> {
  const out: Record<string, string> = {};
  let text: string;
  try {
    text = readFileSync(file, 'utf8');
  } catch {
    return out;
  }
  for (const line of text.split('\n')) {
    const l = line.trim();
    if (!l || l.startsWith('#')) continue;
    const eq = l.indexOf('=');
    if (eq === -1) continue;
    out[l.slice(0, eq).trim()] = l.slice(eq + 1).trim();
  }
  return out;
}

const env = loadEnv(path.join(REPO_ROOT, '.env'));

export const RPC_URL = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
export const DEPLOYER_PK = (process.env.PRIVATE_KEY ?? env.PRIVATE_KEY) as Hex;
if (!DEPLOYER_PK) throw new Error('PRIVATE_KEY not found in environment or repo .env');

// --- deployment addresses ----------------------------------------------
export interface Deployment {
  network: string;
  rpc: string;
  deployer: Address;
  AGTToken: Address;
  TeamVesting: Address;
  Staking: Address;
  AgentRegistryV2: Address;
  RewardDistributor: Address;
  Emission: Address;
  DisputeModule: Address;
}

export const deployment: Deployment = JSON.parse(
  readFileSync(path.join(REPO_ROOT, 'deployments', 'anvil-fork-84532.json'), 'utf8'),
);

// --- clients -------------------------------------------------------------
export const chain = baseSepolia; // chainId 84532 — matches the local fork
export const transport = http(RPC_URL);

export const publicClient = createPublicClient({ chain, transport });

export function walletFor(pk: Hex) {
  return createWalletClient({ chain, transport, account: privateKeyToAccount(pk) });
}

export const deployerAccount = privateKeyToAccount(DEPLOYER_PK);
export const deployerWallet = walletFor(DEPLOYER_PK);

/** Anvil-only RPC helper: fund an address with local test ETH. */
export async function setBalance(address: Address, ethAmount = '10') {
  const wei = BigInt(Math.round(Number(ethAmount) * 1e18));
  await publicClient.request({
    method: 'anvil_setBalance' as never,
    params: [address, `0x${wei.toString(16)}`] as never,
  });
}

export async function increaseTime(seconds: number) {
  await publicClient.request({ method: 'evm_increaseTime' as never, params: [seconds] as never });
  await publicClient.request({ method: 'evm_mine' as never, params: [] as never });
}
