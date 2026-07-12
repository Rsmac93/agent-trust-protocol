import { createPublicClient, createWalletClient, http, keccak256, toHex, parseEventLogs, } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base, baseSepolia } from 'viem/chains';
import { REGISTRY_ABI } from './abi.js';
const CHAINS = { base, baseSepolia };
/** Deterministic JSON canonicalization (sorted keys) so the same logical
 *  receipt always produces the same hash. */
export function canonicalHash(obj) {
    const canon = (v) => {
        if (Array.isArray(v))
            return v.map(canon);
        if (v && typeof v === 'object') {
            return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])]));
        }
        return v;
    };
    return keccak256(toHex(JSON.stringify(canon(obj))));
}
export class AgentTrust {
    pub;
    wallet;
    registry;
    constructor(cfg) {
        const chain = CHAINS[cfg.network ?? 'baseSepolia'];
        const transport = http(cfg.rpcUrl);
        this.registry = cfg.registryAddress;
        this.pub = createPublicClient({ chain, transport });
        this.wallet = cfg.privateKey
            ? createWalletClient({ chain, transport, account: privateKeyToAccount(cfg.privateKey) })
            : undefined;
    }
    get account() {
        if (!this.wallet)
            throw new Error('AgentTrust: privateKey required for write operations');
        return this.wallet.account;
    }
    /** Register an agent identity. Returns its on-chain agentId.
     *  Fee is paid in native ETH — no protocol token required. */
    async registerAgent(card) {
        const metadataHash = canonicalHash(card);
        const fee = await this.pub.readContract({
            address: this.registry, abi: REGISTRY_ABI, functionName: 'registrationFee',
        });
        const txHash = await this.wallet.writeContract({
            address: this.registry, abi: REGISTRY_ABI, functionName: 'registerAgent',
            args: [metadataHash], value: fee, account: this.account, chain: this.wallet.chain,
        });
        const receipt = await this.pub.waitForTransactionReceipt({ hash: txHash });
        const logs = parseEventLogs({ abi: REGISTRY_ABI, eventName: 'AgentRegistered', logs: receipt.logs });
        const agentId = logs[0].args.agentId;
        return { agentId, txHash, metadataHash };
    }
    /** Notarize an action receipt on-chain (self-reported lane).
     *  Store the full receipt yourself; the chain stores its hash + timestamp. */
    async logReceipt(r) {
        const full = { ...r, timestamp: r.timestamp ?? Date.now(), agentId: r.agentId.toString() };
        const receiptHash = canonicalHash(full);
        const txHash = await this.wallet.writeContract({
            address: this.registry, abi: REGISTRY_ABI, functionName: 'logReceipt',
            args: [BigInt(r.agentId), receiptHash], account: this.account, chain: this.wallet.chain,
        });
        await this.pub.waitForTransactionReceipt({ hash: txHash });
        return { receiptHash, txHash };
    }
    /** Full agent profile + reputation. Read-only; no key needed. */
    async getAgent(agentId) {
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
    async getReputation(agentId) {
        return this.pub.readContract({
            address: this.registry, abi: REGISTRY_ABI, functionName: 'reputation', args: [BigInt(agentId)],
        });
    }
    /** Verify that a locally-held receipt matches what was notarized on-chain. */
    verifyReceipt(fullReceipt, onChainHash) {
        return canonicalHash(fullReceipt) === onChainHash;
    }
}
export default AgentTrust;
//# sourceMappingURL=index.js.map