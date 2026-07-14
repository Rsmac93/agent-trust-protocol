import { createPublicClient, createWalletClient, http, keccak256, toHex, encodeAbiParameters, parseEventLogs, } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base, baseSepolia } from 'viem/chains';
import { REGISTRY_ABI, PASSPORT_ABI } from './abi.js';
const CHAINS = { base, baseSepolia };
/** VoltPass's live Base Sepolia deployment (chainId 84532), deployed
 *  2026-07-14. Not verified on Basescan yet (verify separately once a
 *  BASESCAN_API_KEY is available — this constant is accurate regardless).
 *  `PerformancePassport` is not part of this deployment. See
 *  `deployments/base-sepolia-84532.json` in the repo for tx hashes and the
 *  smoke-test record. Pass `BASE_SEPOLIA_DEPLOYMENT.AgentRegistryV2` as
 *  `registryAddress` to skip hunting for the address yourself. */
export const BASE_SEPOLIA_DEPLOYMENT = {
    network: 'baseSepolia',
    chainId: 84532,
    VoltToken: '0x6A53a18Ca136D829ffFF3f8eAFCF4c108D834E05',
    TeamVesting: '0x6c3008bCb4767CF11B3B79bb5203A8B678cf7d5F',
    Staking: '0x3E6c4306A6E25B47206b80E1ee277FE072c1280F',
    AgentRegistryV2: '0x1d38285211953b61799AAA4Ad7221ED638AbA751',
    RewardDistributor: '0xbe3937E04B0605681942480f9FdD61d102F7A5dd',
    Emission: '0xe5342dbd7EC3ba82E107c3090ddad9328e7B5Fc3',
    DisputeModule: '0x99eF4DD96fcCddb1A7659EdD9816Bd75F3AA253A',
};
const CLAIM_TYPE_CODE = {
    PROFIT: 0, RISK_COMPLIANCE: 1, EXECUTION_INTEGRITY: 2,
};
const CLAIM_TYPE_NAME = ['PROFIT', 'RISK_COMPLIANCE', 'EXECUTION_INTEGRITY'];
/** DEMO-ONLY signing key standing in for the StubVerifier's off-chain
 *  attestor. NOT for production use: v1's StubVerifier is a disclosed
 *  centralization point (see contracts/StubVerifier.sol), and shipping its
 *  signing key in SDK source is only acceptable because it exists purely so
 *  the litepaper demo can publish a claim end-to-end without standing up a
 *  real attestation service. A real deployment configures its own attestor
 *  (or, later, swaps in a real Noir/SP1 verifier) and never ships its key. */
export const DEMO_ATTESTOR_PRIVATE_KEY = '0xcab3a68048f0a2d12489c0e890a58915b88dbb240ad04e6df314814e2e5fc614';
/** Deterministic JSON canonicalization (sorted keys) so the same logical
 *  receipt always produces the same hash. Bigints (tx values, gas, agentIds
 *  passed as bigint, etc. — routine in payloads coming from viem/AgentKit
 *  call args) are stringified recursively before JSON.stringify, which
 *  otherwise throws on raw bigints ("Do not know how to serialize a
 *  BigInt"). */
export function canonicalHash(obj) {
    const canon = (v) => {
        if (typeof v === 'bigint')
            return v.toString();
        if (Array.isArray(v))
            return v.map(canon);
        if (v && typeof v === 'object') {
            return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])]));
        }
        return v;
    };
    return keccak256(toHex(JSON.stringify(canon(obj))));
}
export class VoltPass {
    pub;
    wallet;
    registry;
    passport;
    constructor(cfg) {
        const chain = CHAINS[cfg.network ?? 'baseSepolia'];
        const transport = http(cfg.rpcUrl);
        this.registry = cfg.registryAddress;
        this.passport = cfg.passportAddress;
        this.pub = createPublicClient({ chain, transport });
        this.wallet = cfg.privateKey
            ? createWalletClient({ chain, transport, account: privateKeyToAccount(cfg.privateKey) })
            : undefined;
    }
    get account() {
        if (!this.wallet)
            throw new Error('VoltPass: privateKey required for write operations');
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
    /** Validator-attested receipt (validator-lane wallet only). The caller's
     *  wallet must be an active validator on the Staking contract wired to this
     *  registry, or the tx reverts with NotActiveValidator. Attested receipts
     *  (unlike self-reports) feed reputation() and validator work rewards. */
    async attestReceipt(agentId, receiptHash) {
        const txHash = await this.wallet.writeContract({
            address: this.registry, abi: REGISTRY_ABI, functionName: 'attestReceipt',
            args: [BigInt(agentId), receiptHash], account: this.account, chain: this.wallet.chain,
        });
        await this.pub.waitForTransactionReceipt({ hash: txHash });
        return { txHash };
    }
    /** Who (if anyone) attested a given receipt hash for this agent. */
    async getAttestor(agentId, receiptHash) {
        return this.pub.readContract({
            address: this.registry, abi: REGISTRY_ABI, functionName: 'attestor',
            args: [BigInt(agentId), receiptHash],
        });
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
    async submitClaim(agentId, epoch, claimType, claimData) {
        if (!this.passport)
            throw new Error('VoltPass: passportAddress required for submitClaim');
        const type = claimType;
        const code = CLAIM_TYPE_CODE[type];
        if (code === undefined)
            throw new Error(`VoltPass: unknown claim type "${claimType}"`);
        const data = BigInt(claimData);
        const rangeStart = `0x${'0'.repeat(64)}`;
        const rangeEnd = `0x${'0'.repeat(64)}`;
        // Must match PerformancePassport.submitClaim's publicInputs encoding exactly.
        const publicInputs = [
            agentId, BigInt(epoch), BigInt(code), data, BigInt(rangeStart), BigInt(rangeEnd),
        ];
        const encoded = encodeAbiParameters([{ type: 'uint8' }, { type: 'uint256[]' }], [code, publicInputs]);
        const digest = keccak256(encoded);
        const demoAttestor = privateKeyToAccount(DEMO_ATTESTOR_PRIVATE_KEY);
        const proof = await demoAttestor.signMessage({ message: { raw: digest } });
        const txHash = await this.wallet.writeContract({
            address: this.passport, abi: PASSPORT_ABI, functionName: 'submitClaim',
            args: [BigInt(agentId), epoch, code, data, rangeStart, rangeEnd, proof],
            account: this.account, chain: this.wallet.chain,
        });
        const receipt = await this.pub.waitForTransactionReceipt({ hash: txHash });
        return { txHash, claimed: receipt.status === 'success' };
    }
    /** Read an agent's PerformancePassport: latest epoch reached, and the
     *  claim currently stored for it (empty array if the agent has never
     *  published a claim). */
    async getPassport(agentId) {
        if (!this.passport)
            throw new Error('VoltPass: passportAddress required for getPassport');
        const id = BigInt(agentId);
        const [latestEpoch, c] = await Promise.all([
            this.pub.readContract({
                address: this.passport, abi: PASSPORT_ABI, functionName: 'latestClaim', args: [id],
            }),
            this.pub.readContract({
                address: this.passport, abi: PASSPORT_ABI, functionName: 'getLatestClaim', args: [id],
            }),
        ]);
        const claims = [];
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
    verifyReceipt(fullReceipt, onChainHash) {
        return canonicalHash(fullReceipt) === onChainHash;
    }
}
export default VoltPass;
//# sourceMappingURL=index.js.map