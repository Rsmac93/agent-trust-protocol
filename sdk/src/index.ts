import {
  createPublicClient, createWalletClient, http, keccak256, toHex, encodeAbiParameters,
  type Address, type Hex, type Chain, parseEventLogs,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base, baseSepolia } from 'viem/chains';
import { REGISTRY_ABI, PASSPORT_ABI } from './abi.js';

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

/** PerformancePassport claim types (must match PerformancePassport.ClaimType). */
export type ClaimTypeName = 'PROFIT' | 'RISK_COMPLIANCE' | 'EXECUTION_INTEGRITY';
const CLAIM_TYPE_CODE: Record<ClaimTypeName, number> = {
  PROFIT: 0, RISK_COMPLIANCE: 1, EXECUTION_INTEGRITY: 2,
};
const CLAIM_TYPE_NAME: ClaimTypeName[] = ['PROFIT', 'RISK_COMPLIANCE', 'EXECUTION_INTEGRITY'];

export interface Claim {
  agentId: bigint;
  epoch: number;
  claimType: ClaimTypeName;
  claimData: bigint;
  receiptHashRangeStart: Hex;
  receiptHashRangeEnd: Hex;
  submittedAt: Date;
  verifierSignature: Hex;
}

/** DEMO-ONLY signing key standing in for the StubVerifier's off-chain
 *  attestor. NOT for production use: v1's StubVerifier is a disclosed
 *  centralization point (see contracts/StubVerifier.sol), and shipping its
 *  signing key in SDK source is only acceptable because it exists purely so
 *  the litepaper demo can publish a claim end-to-end without standing up a
 *  real attestation service. A real deployment configures its own attestor
 *  (or, later, swaps in a real Noir/SP1 verifier) and never ships its key. */
export const DEMO_ATTESTOR_PRIVATE_KEY: Hex =
  '0xcab3a68048f0a2d12489c0e890a58915b88dbb240ad04e6df314814e2e5fc614';

export interface AgentTrustConfig {
  /** 'baseSepolia' (testnet, default) or 'base' */
  network?: 'base' | 'baseSepolia';
  /** Deployed AgentRegistryV2 address */
  registryAddress: Address;
  /** Deployed PerformancePassport address. Required for submitClaim/getPassport. */
  passportAddress?: Address;
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
  private passport: Address | undefined;

  constructor(cfg: AgentTrustConfig) {
    const chain = CHAINS[cfg.network ?? 'baseSepolia'];
    const transport = http(cfg.rpcUrl);
    this.registry = cfg.registryAddress;
    this.passport = cfg.passportAddress;
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

  /** Publish a performance claim to PerformancePassport.
   *
   *  v1 note: PerformancePassport verifies claims against a StubVerifier
   *  (a designated attestor's ECDSA signature standing in for a real ZK
   *  proof). This method signs with DEMO_ATTESTOR_PRIVATE_KEY — a
   *  demo-only key hardcoded so the litepaper's "agent publishes a
   *  performance claim" story runs end-to-end without a live attestation
   *  service. The PerformancePassport instance the demo deploys wires its
   *  StubVerifier to that same demo key; a real deployment would run its
   *  own off-chain attestor (or a real ZK verifier) and never sign with a
   *  key that ships in SDK source. */
  async submitClaim(
    agentId: bigint, epoch: number, claimType: string, claimData: string,
  ): Promise<{ txHash: Hex; claimed: boolean }> {
    if (!this.passport) throw new Error('AgentTrust: passportAddress required for submitClaim');
    const type = claimType as ClaimTypeName;
    const code = CLAIM_TYPE_CODE[type];
    if (code === undefined) throw new Error(`AgentTrust: unknown claim type "${claimType}"`);

    const data = BigInt(claimData);
    const rangeStart: Hex = `0x${'0'.repeat(64)}`;
    const rangeEnd: Hex = `0x${'0'.repeat(64)}`;

    // Must match PerformancePassport.submitClaim's publicInputs encoding exactly.
    const publicInputs = [
      agentId, BigInt(epoch), BigInt(code), data, BigInt(rangeStart), BigInt(rangeEnd),
    ];
    const encoded = encodeAbiParameters(
      [{ type: 'uint8' }, { type: 'uint256[]' }],
      [code, publicInputs],
    );
    const digest = keccak256(encoded);
    const demoAttestor = privateKeyToAccount(DEMO_ATTESTOR_PRIVATE_KEY);
    const proof = await demoAttestor.signMessage({ message: { raw: digest } });

    const txHash = await this.wallet!.writeContract({
      address: this.passport, abi: PASSPORT_ABI, functionName: 'submitClaim',
      args: [BigInt(agentId), epoch, code, data, rangeStart, rangeEnd, proof],
      account: this.account, chain: this.wallet!.chain,
    });
    const receipt = await this.pub.waitForTransactionReceipt({ hash: txHash });
    return { txHash, claimed: receipt.status === 'success' };
  }

  /** Read an agent's PerformancePassport: latest epoch reached, and the
   *  claim currently stored for it (empty array if the agent has never
   *  published a claim). */
  async getPassport(agentId: bigint): Promise<{ latestEpoch: number; claims: Claim[] }> {
    if (!this.passport) throw new Error('AgentTrust: passportAddress required for getPassport');
    const id = BigInt(agentId);
    const [latestEpoch, c] = await Promise.all([
      this.pub.readContract({
        address: this.passport, abi: PASSPORT_ABI, functionName: 'latestClaim', args: [id],
      }),
      this.pub.readContract({
        address: this.passport, abi: PASSPORT_ABI, functionName: 'getLatestClaim', args: [id],
      }),
    ]);

    const claims: Claim[] = [];
    if (c.submittedAt > 0n) {
      claims.push({
        agentId: c.agentId,
        epoch: Number(c.epoch),
        claimType: CLAIM_TYPE_NAME[c.claimType] ?? 'PROFIT',
        claimData: c.claimData,
        receiptHashRangeStart: c.receiptHashRangeStart,
        receiptHashRangeEnd: c.receiptHashRangeEnd,
        submittedAt: new Date(Number(c.submittedAt) * 1000),
        verifierSignature: c.verifierSignature,
      });
    }
    return { latestEpoch: Number(latestEpoch), claims };
  }

  /** Verify that a locally-held receipt matches what was notarized on-chain. */
  verifyReceipt(fullReceipt: Record<string, unknown>, onChainHash: Hex): boolean {
    return canonicalHash(fullReceipt) === onChainHash;
  }
}

export default AgentTrust;
