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
export declare function canonicalHash(obj: unknown): Hex;
export declare class AgentTrust {
    private pub;
    private wallet;
    private registry;
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
    /** Full agent profile + reputation. Read-only; no key needed. */
    getAgent(agentId: bigint | number): Promise<AgentInfo>;
    /** Convenience: just the reputation score. */
    getReputation(agentId: bigint | number): Promise<bigint>;
    /** Verify that a locally-held receipt matches what was notarized on-chain. */
    verifyReceipt(fullReceipt: Record<string, unknown>, onChainHash: Hex): boolean;
}
export default AgentTrust;
//# sourceMappingURL=index.d.ts.map