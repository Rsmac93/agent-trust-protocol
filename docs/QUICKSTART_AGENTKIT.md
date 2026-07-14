# Give your AgentKit trading bot a verifiable track record in one line

5 minutes, from install to seeing your first receipt on-chain.

> **Current status:** `voltpass-sdk` and `voltpass-agentkit` are built,
> tested, and not yet published to npm (publish is pending review — see
> [SECURITY.md](../SECURITY.md), this is pre-audit testnet software). The
> `npm install` commands below are the intended end-state UX and are what
> you'll run once they're live. Until then, use the **local install**
> variant in Step 1 — everything else in this guide works today, against a
> local Anvil chain, exactly as written.

## What you're about to do

Wrap your AgentKit `WalletProvider` in one function call. From then on,
every trade your agent executes — through any current or future
ActionProvider — automatically produces a signed, on-chain **VoltPass
receipt**: a timestamped, hash-committed record of what the agent did. No
changes to your trading logic, your ActionProviders, or your agent's
prompt.

This is the free, self-reported lane (no validator required to get
started). See the [litepaper](./LITEPAPER.md) for how attested receipts
build on top of this into portable, third-party-checkable reputation.

## Step 1 — install

Once published:

```bash
npm install voltpass-agentkit @coinbase/agentkit viem
```

**Today (local install, not yet on npm):**

```bash
git clone https://github.com/Rsmac93/agent-trust-protocol.git voltpass
cd voltpass/sdk && npm install && npm run build
cd ../agentkit-adapter && npm install && npm run build
```

`voltpass-agentkit` depends on `voltpass-sdk` via a local `file:` reference,
so building the SDK first is required — this is purely an artifact of the
pre-publish state, not something you'll need to think about once both
packages are live on npm.

## Step 2 — get a chain to point at

You need a deployed `AgentRegistryV2` to register against. There's no live
testnet deployment yet (see [DEPLOYMENT.md](../DEPLOYMENT.md) for why —
faucet access is the current blocker), so for this quickstart, deploy
everything locally on Anvil — takes under a minute:

```bash
# from the repo root, in one shell:
anvil --chain-id 84532 --port 8545
```

```bash
# in another shell:
cp .env.example .env
# edit .env: set PRIVATE_KEY to one of the funded accounts Anvil printed on startup

source .env
forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
```

Grab the `AgentRegistryV2` address from the script's output (or from
[deployments/anvil-fork-84532.json](../deployments/anvil-fork-84532.json)
if you're reusing that fork) — you'll need it in the next step.

## Step 3 — register your agent and get an `agentId`

One-time setup, not something you run on every startup:

```ts
import { registerAgentOnce } from 'voltpass-agentkit';

const agentId = await registerAgentOnce({
  registryAddress: '0x...',              // from Step 2
  privateKey: process.env.VOLTPASS_LOGGER_KEY as `0x${string}`,
  name: 'my-trading-agent',
  model: 'claude-sonnet-5',
});

console.log('agentId:', agentId);        // save this — you'll pass it into Step 4
```

`registerAgentOnce` pays the registration fee (native ETH, not VOLT) and
returns the numeric `agentId` this wallet is now registered under.

## Step 4 — the one line

This is the entire integration. Wrap the `WalletProvider` you already pass
to `AgentKit.from(...)`:

```ts
import { AgentKit } from '@coinbase/agentkit';
import { ViemWalletProvider } from '@coinbase/agentkit';
import { withVoltPassLogging } from 'voltpass-agentkit';

const walletProvider = withVoltPassLogging(
  new ViemWalletProvider(walletClient),   // your existing wallet client, untouched
  {
    registryAddress: '0x...',             // from Step 2
    agentId: 4217n,                       // from Step 3
    loggerPrivateKey: process.env.VOLTPASS_LOGGER_KEY as `0x${string}`,
  },
);

const agentKit = await AgentKit.from({ walletProvider });
```

Nothing else changes. Every `ERC20ActionProvider.transfer(...)`, or any
other ActionProvider action that routes through `sendTransaction` or
`nativeTransfer`, now logs a VoltPass receipt automatically, after the
underlying trade confirms, without blocking or risking it (logging is
fire-and-forget — a VoltPass outage can never break a real trade).

## Step 5 — see your first receipt on-chain

Run your agent and let it make one trade — or, to see this in isolation
without a full agent loop, just call the wrapped provider directly:

```ts
await walletProvider.nativeTransfer('0x000000000000000000000000000000000000dEaD', '1000000000000000');
```

Then, a moment later, check the agent's receipt count went up by one:

```ts
import { VoltPass } from 'voltpass-sdk';

const voltpass = new VoltPass({ registryAddress: '0x...' }); // read-only, no key needed
const info = await voltpass.getAgent(agentId);

console.log('self-reported receipts:', info.selfReceipts); // was N, now N+1
```

That receipt is now a permanent, hash-committed record on
`AgentRegistryV2` — the same one a validator can later attest, and the
same one a marketplace or counterparty can query before trusting this
agent. You didn't write a single line of receipt-logging code to get it.

## What this doesn't do (yet)

- **This is the self-reported lane only.** Getting receipts *attested*
  (the step that actually builds reputation, not just a log) requires a
  bonded validator — see the [litepaper](./LITEPAPER.md).
- **`sendTransaction` and `nativeTransfer` are the only logged methods** —
  read-only calls (balance/network checks) are correctly not logged. Full
  rationale and version-pinning notes in
  [agentkit-adapter/README.md](../agentkit-adapter/README.md).
- Full honest-limitations list (logger-key vs. trading-key separation,
  what happens if AgentKit adds a new fund-moving method in a future
  release) is in that same README — worth reading before you point this
  at a production agent.

## Next steps

- [demo/](../demo) — a full runnable end-to-end example (validator
  bonding, agent registration, a mock trading loop, receipt attestation,
  reward claim) if you want to see the whole protocol, not just the
  adapter.
- [docs/integrations/agentkit-adapter.md](./integrations/agentkit-adapter.md) —
  the design rationale for why `WalletProvider` is the right place to hook,
  not `ActionProvider`.
- [docs/LITEPAPER.md](./LITEPAPER.md) — the full vision, including ZK
  performance passports for proving profitability without revealing
  strategy.
