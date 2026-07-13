import {
  createPublicClient, createWalletClient, http, keccak256, toHex,
  type Address, type Hex, type Chain, parseEventLogs,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base, baseSepolia } from 'viem/chains';
import { REGISTRY_ABI } from './abi.js';

/** Metadata describing an agent — hashed on-chain, stored wherever you like. */
export interface AgentCard {
  name: string;
  description?: string;
  model?: string;          // e.g. "claude-sonnet-4-6"
  capabilities?: string[]; // e.g. ["defi-trading", "x402-payments"]
  endpoint?: string;       // where the agent can be reached
  [key: string]: unknown;
}

/** An action record. The SDK canonicalizes + hashes it; the hash is notarized on-chain. */
export interface ActionReceipt {
  agentId: bigint | number;
  action: string;              // e.g. "swap", "api-call", "payment"
  timestamp?: number;          // ms epoch; defaults to now
  payload?: Record<string, unknown>; // action details (tx hash, amounts, etc.)
}

export interface AgentInfo {
  agentId: bigint;
  principal: Address;
  metadataHash: Hex;
  registeredAt: Date;
  active: boolean;
  selfReceipts: number;
  attestedReceipts: number;
  disputes: number;
  reputation: bigint;
}

const CHAINS: Record<string, Chain> = { base, baseSepolia };

export interface AgentTrustConfig {
  /** 'baseSepolia' (testnet, default) or 'base' */
  network?: 'base' | 'baseSepolia';
  /** Deployed AgentRegistryV2 address */
  registryAddress: Address;
  /** Private key for write ops. Omit for read-only usage. */
  privateKey?: Hex;
  /** Optional custom RPC URL */
  rpcUrl?: string;
}

/** Deterministic JSON canonicalization (sorted keys) so the same logical
 *  receipt always produces the same hash. */
export function canonicalHash(obj: unknown): Hex {
  const canon = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(canon);
    if (v && typeof v === 'object') {
      return Object.fromEntries(
        Object.keys(v as object).sort().map((k) => [k, canon((v as Record<string, unknown>)[k])]),
      );
    }
    return v;
  };
  return keccak256(toHex(JSON.stringify(canon(obj))));
}

export class AgentTrust {
  private pub;
  private wallet;
  private registry: Address;

  constructor(cfg: AgentTrustConfig) {
    const chain = CHAINS[cfg.network ?? 'baseSepolia'];
    const transport = http(cfg.rpcUrl);
    this.registry = cfg.registryAddress;
    this.pub = createPublicClient({ chain, transport });
    this.wallet = cfg.privateKey
      ? createWalletClient({ chain, transport, account: privateKeyToAccount(cfg.privateKey) })
      : undefined;
  }

  private get account() {
    if (!this.wallet) throw new Error('AgentTrust: privateKey required for write operations');
    return this.wallet.account!;
  }

  /** Register an agent identity. Returns its on-chain agentId.
   *  Fee is paid in native ETH — no protocol token required. */
  async registerAgent(card: AgentCard): Promise<{ agentId: bigint; txHash: Hex; metadataHash: Hex }> {
    const metadataHash = canonicalHash(card);
    const fee = await this.pub.readContract({
      address: this.registry, abi: REGISTRY_ABI, functionName: 'registrationFee',
    });
    const txHash = await this.wallet!.writeContract({
      address: this.registry, abi: REGISTRY_ABI, functionName: 'registerAgent',
      args: [metadataHash], value: fee, account: this.account, chain: this.wallet!.chain,
    });
    const receipt = await this.pub.waitForTransactionReceipt({ hash: txHash });
    const logs = parseEventLogs({ abi: REGISTRY_ABI, eventName: 'AgentRegistered', logs: receipt.logs });
    const agentId = (logs[0] as { args: { agentId: bigint } }).args.agentId;
    return { agentId, txHash, metadataHash };
  }

  /** Notarize an action receipt on-chain (self-reported lane).
   *  Store the full receipt yourself; the chain stores its hash + timestamp. */
  async logReceipt(r: ActionReceipt): Promise<{ receiptHash: Hex; txHash: Hex }> {
    const full = { ...r, timestamp: r.timestamp ?? Date.now(), agentId: r.agentId.toString() };
    const receiptHash = canonicalHash(full);
    const txHash = await this.wallet!.writeContract({
      address: this.registry, abi: REGISTRY_ABI, functionName: 'logReceipt',
      args: [BigInt(r.agentId), receiptHash], account: this.account, chain: this.wallet!.chain,
    });
    await this.pub.waitForTransactionReceipt({ hash: txHash });
    return { receiptHash, txHash };
  }

  /** Validator-attested receipt (validator-lane wallet only). The caller's
   *  wallet must be an active validator on the Staking contract wired to this
   *  registry, or the tx reverts with NotActiveValidator. Attested receipts
   *  (unlike self-reports) feed reputation() and validator work rewards. */
  async attestReceipt(agentId: bigint | number, receiptHash: Hex): Promise<{ txHash: Hex }> {
    const txHash = await this.wallet!.writeContract({
      address: this.registry, abi: REGISTRY_ABI, functionName: 'attestReceipt',
      args: [BigInt(agentId), receiptHash], account: this.account, chain: this.wallet!.chain,
    });
    await this.pub.waitForTransactionReceipt({ hash: txHash });
    return { txHash };
  }

  /** Who (if anyone) attested a given receipt hash for this agent. */
  async getAttestor(agentId: bigint | number, receiptHash: Hex): Promise<Address> {
    return this.pub.readContract({
      address: this.registry, abi: REGISTRY_ABI, functionName: 'attestor',
      args: [BigInt(agentId), receiptHash],
    });
  }

  /** Full agent profile + reputation. Read-only; no key needed. */
  async getAgent(agentId: bigint | number): Promise<AgentInfo> {
    const id = BigInt(agentId);
    const [a, rep] = await Promise.all([
      this.pub.readContract({ address: this.registry, abi: REGISTRY_ABI, functionName: 'agents', args: [id] }),
      this.pub.readContract({ address: this.registry, abi: REGISTRY_ABI, functionName: 'reputation', args: [id] }),
    ]);
    return {
      agentId: id,
      principal: a[0], metadataHash: a[1],
      registeredAt: new Date(Number(a[2]) * 1000),
      active: a[3],
      selfReceipts: Number(a[4]), attestedReceipts: Number(a[5]), disputes: Number(a[6]),
      reputation: rep,
    };
  }

  /** Convenience: just the reputation score. */
  async getReputation(agentId: bigint | number): Promise<bigint> {
    return this.pub.readContract({
      address: this.registry, abi: REGISTRY_ABI, functionName: 'reputation', args: [BigInt(agentId)],
    });
  }

  /** Verify that a locally-held receipt matches what was notarized on-chain. */
  verifyReceipt(fullReceipt: Record<string, unknown>, onChainHash: Hex): boolean {
    return canonicalHash(fullReceipt) === onChainHash;
  }
}

export default AgentTrust;
