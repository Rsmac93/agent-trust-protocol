import { type Address, type Hex } from 'viem';
/** Metadata describing an agent — hashed on-chain, stored wherever you like. */
export interface AgentCard {
    name: string;
    description?: string;
    model?: string;
    capabilities?: string[];
    endpoint?: string;
    [key: string]: unknown;
}
/** An action record. The SDK canonicalizes + hashes it; the hash is notarized on-chain. */
export interface ActionReceipt {
    agentId: bigint | number;
    action: string;
    timestamp?: number;
    payload?: Record<string, unknown>;
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
/** PerformancePassport claim types (must match PerformancePassport.ClaimType). */
export type ClaimTypeName = 'PROFIT' | 'RISK_COMPLIANCE' | 'EXECUTION_INTEGRITY';
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
export declare const DEMO_ATTESTOR_PRIVATE_KEY: Hex;
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
export declare function canonicalHash(obj: unknown): Hex;
export declare class AgentTrust {
    private pub;
    private wallet;
    private registry;
    private passport;
    constructor(cfg: AgentTrustConfig);
    private get account();
    /** Register an agent identity. Returns its on-chain agentId.
     *  Fee is paid in native ETH — no protocol token required. */
    registerAgent(card: AgentCard): Promise<{
        agentId: bigint;
        txHash: Hex;
        metadataHash: Hex;
    }>;
    /** Notarize an action receipt on-chain (self-reported lane).
     *  Store the full receipt yourself; the chain stores its hash + timestamp. */
    logReceipt(r: ActionReceipt): Promise<{
        receiptHash: Hex;
        txHash: Hex;
    }>;
    /** Validator-attested receipt (validator-lane wallet only). The caller's
     *  wallet must be an active validator on the Staking contract wired to this
     *  registry, or the tx reverts with NotActiveValidator. Attested receipts
     *  (unlike self-reports) feed reputation() and validator work rewards. */
    attestReceipt(agentId: bigint | number, receiptHash: Hex): Promise<{
        txHash: Hex;
    }>;
    /** Who (if anyone) attested a given receipt hash for this agent. */
    getAttestor(agentId: bigint | number, receiptHash: Hex): Promise<Address>;
    /** Full agent profile + reputation. Read-only; no key needed. */
    getAgent(agentId: bigint | number): Promise<AgentInfo>;
    /** Convenience: just the reputation score. */
    getReputation(agentId: bigint | number): Promise<bigint>;
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
    submitClaim(agentId: bigint, epoch: number, claimType: string, claimData: string): Promise<{
        txHash: Hex;
        claimed: boolean;
    }>;
    /** Read an agent's PerformancePassport: latest epoch reached, and the
     *  claim currently stored for it (empty array if the agent has never
     *  published a claim). */
    getPassport(agentId: bigint): Promise<{
        latestEpoch: number;
        claims: Claim[];
    }>;
    /** Verify that a locally-held receipt matches what was notarized on-chain. */
    verifyReceipt(fullReceipt: Record<string, unknown>, onChainHash: Hex): boolean;
}
export default AgentTrust;
//# sourceMappingURL=index.d.ts.map