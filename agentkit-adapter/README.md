# voltpass-agentkit

Wraps a Coinbase AgentKit `WalletProvider` so every fund-moving call it
makes is auto-logged as a VoltPass receipt — zero changes to the
developer's existing trading logic or ActionProviders.

Pinned against `@coinbase/agentkit@0.10.4`. See
[`docs/integrations/agentkit-adapter.md`](../docs/integrations/agentkit-adapter.md)
in the repo root for the full design rationale.

## Integration (the entire diff)

```ts
// Before (standard AgentKit setup):
const walletProvider = new ViemWalletProvider(walletClient);
const agentKit = await AgentKit.from({ walletProvider });

// After (the ONLY change — one wrap, at construction time):
import { withVoltPassLogging } from 'voltpass-agentkit';

const walletProvider = withVoltPassLogging(
  new ViemWalletProvider(walletClient),
  {
    registryAddress: '0x...',
    agentId: 4217n,
    loggerPrivateKey: process.env.VOLTPASS_LOGGER_KEY as `0x${string}`,
  },
);
const agentKit = await AgentKit.from({ walletProvider });
```

Every `ERC20ActionProvider.transfer(...)`, or any other ActionProvider's
on-chain call that routes through `sendTransaction`/`nativeTransfer`, now
produces a VoltPass receipt automatically. Nothing in the agent's
action-selection logic, prompt, or existing ActionProviders changes.

Don't have a VoltPass `agentId` yet? Use the one-time helper:

```ts
import { registerAgentOnce } from 'voltpass-agentkit';

const agentId = await registerAgentOnce({
  registryAddress: '0x...',
  privateKey: process.env.VOLTPASS_LOGGER_KEY as `0x${string}`,
  name: 'my-trading-agent',
  model: 'claude-sonnet-5',
});
```

## Version note

Built and integration-tested against `@coinbase/agentkit@0.10.4`. The
logged method set (`sendTransaction`, `nativeTransfer`) was verified
directly against that version's `WalletProvider` / `EvmWalletProvider`
class hierarchy and against `ERC20ActionProvider`'s source, which calls
`walletProvider.sendTransaction(...)` internally. If a future AgentKit
release adds a new fund-moving choke point outside these two methods,
`LOGGED_METHODS` in `src/index.ts` needs a matching update — pin your
`@coinbase/agentkit` version and re-check before upgrading.

## What this does NOT cover (honest limitations)

- **Read-only actions** (balance checks, address/network lookups,
  `readContract`, `waitForTransactionReceipt`) are correctly *not*
  logged — VoltPass receipts are for actions with real economic effect,
  not queries.
- **The logger key is separate from the trading key by design** — using
  the agent's own trading wallet as its VoltPass principal is simplest,
  but a security-conscious deployment may want the two decoupled so a
  compromised logging key can't move funds. This is a deployment choice,
  not something the adapter enforces.
- **No attestation.** This adapter only covers the free `logReceipt`
  self-reported lane. Getting these receipts *attested* (the lane that
  actually builds reputation) requires a validator — out of scope for an
  auto-logging adapter, which is about removing developer friction on the
  reporting side, not bootstrapping the validator network.

## Local development

```bash
npm install
npm run build   # tsc -p tsconfig.json -> dist/
```

An end-to-end integration test (`test/integration-test.ts`) exercises this
package against a live local Anvil chain — see that file for what it
proves and how to run it.
