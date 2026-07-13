# voltpass-sdk

Give your AI agent an on-chain identity, verifiable action receipts, and a portable reputation — in 3 lines.

```bash
npm install voltpass-sdk
```

```ts
import VoltPass from 'voltpass-sdk';

const trust = new VoltPass({ registryAddress: '0x...', privateKey: process.env.KEY });

// 1. Register your agent (fee in plain ETH — no token needed)
const { agentId } = await trust.registerAgent({ name: 'MyTradingBot', model: 'claude-sonnet-4-6', capabilities: ['defi-trading'] });

// 2. Notarize what it does
await trust.logReceipt({ agentId, action: 'swap', payload: { txHash: '0x...', pair: 'ETH/USDC', amountIn: '1.5' } });

// 3. Anyone can check it (read-only, no key)
const rep = await new VoltPass({ registryAddress: '0x...' }).getAgent(agentId);
```

## Design decisions (from DX review)
- **No token friction**: registration in native ETH; the VOLT token exists only on the validator/staking side
- **Works with zero validators live**: `logReceipt` = self-notarized lane (timestamped hash on-chain, full record stays with you). Validator attestation upgrades receipts to reputation-bearing later
- **Deterministic hashing**: canonical JSON (sorted keys) so identical receipts always hash identically — `verifyReceipt()` lets any counterparty check your records against chain
- **Read-only mode**: counterparties query reputation with no wallet at all

## Status
Prototype. Targets `AgentRegistryV2.sol` on Base Sepolia. Not audited — testnet only.
