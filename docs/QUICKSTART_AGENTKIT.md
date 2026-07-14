# Give your AgentKit trading bot a verifiable track record in one line

5 minutes, from install to seeing your first receipt on-chain.

> **Current status:** `AgentRegistryV2` and the rest of the protocol are
> **live and verified on Base Sepolia** (chainId 84532) — see
> [deployments/base-sepolia-84532.json](../deployments/base-sepolia-84532.json)
> for addresses, verified-source links, and a passing smoke-test record.
> `voltpass-sdk@0.1.1` and `voltpass-agentkit@0.1.0` are published to npm
> — the `npm install` command below works as written. This is still
> **pre-audit testnet software** — see [SECURITY.md](../SECURITY.md)
> before using any of this with real funds.

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

```bash
npm install voltpass-agentkit @coinbase/agentkit viem
```

`voltpass-agentkit` depends on `voltpass-sdk`, published separately —
npm resolves it automatically, no extra install step needed.

## Step 2 — point at the live contracts

No deployment needed — `AgentRegistryV2` is already live on Base Sepolia.
The SDK ships the address:

```ts
import { BASE_SEPOLIA_DEPLOYMENT } from 'voltpass-sdk';

console.log(BASE_SEPOLIA_DEPLOYMENT.AgentRegistryV2);
// 0x1d38285211953b61799AAA4Ad7221ED638AbA751
```

You'll need a Base Sepolia wallet with a small amount of testnet ETH (the
registration fee, plus gas — well under a cent's worth of testnet ETH
total). Get some free from the
[Coinbase Developer Platform faucet](https://portal.cdp.coinbase.com/products/faucet)
or [Alchemy's Base Sepolia faucet](https://www.alchemy.com/faucets/base-sepolia).

> **Developing offline?** Skip straight to
> [Appendix — local Anvil alternative](#appendix--local-anvil-alternative)
> below to run this whole flow against a local chain instead, no testnet
> ETH or network round-trips required.

## Step 3 — register your agent and get an `agentId`

One-time setup, not something you run on every startup:

```ts
import { registerAgentOnce, } from 'voltpass-agentkit';
import { BASE_SEPOLIA_DEPLOYMENT } from 'voltpass-sdk';

const agentId = await registerAgentOnce({
  registryAddress: BASE_SEPOLIA_DEPLOYMENT.AgentRegistryV2,
  privateKey: process.env.VOLTPASS_LOGGER_KEY as `0x${string}`,
  name: 'my-trading-agent',
  model: 'claude-sonnet-5',
  network: 'baseSepolia',
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
import { BASE_SEPOLIA_DEPLOYMENT } from 'voltpass-sdk';

const walletProvider = withVoltPassLogging(
  new ViemWalletProvider(walletClient),   // your existing wallet client, untouched
  {
    registryAddress: BASE_SEPOLIA_DEPLOYMENT.AgentRegistryV2,
    agentId: 4217n,                       // from Step 3
    loggerPrivateKey: process.env.VOLTPASS_LOGGER_KEY as `0x${string}`,
    network: 'baseSepolia',
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
import { VoltPass, BASE_SEPOLIA_DEPLOYMENT } from 'voltpass-sdk';

const voltpass = new VoltPass({
  registryAddress: BASE_SEPOLIA_DEPLOYMENT.AgentRegistryV2,
  network: 'baseSepolia',
}); // read-only, no key needed
const info = await voltpass.getAgent(agentId);

console.log('self-reported receipts:', info.selfReceipts); // was N, now N+1
```

Or skip the SDK read entirely and look at it directly: open
`https://sepolia.basescan.org/address/{yourWalletAddress}` in a browser —
the `logReceipt` transaction the adapter fired is right there, from your
wallet, with no manual step on your part. Contract source is verified on
Basescan (see
[deployments/base-sepolia-84532.json](../deployments/base-sepolia-84532.json)
for direct links to each contract's verified source), so the transaction
decodes as `logReceipt(uint256,bytes32)` — not a raw, unlabeled call.

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

## Appendix — local Anvil alternative

For offline development, or if you'd rather not touch testnet ETH at all:
deploy the whole protocol to a local Anvil chain in under a minute, and
run every step above against that instead — same code, just a different
`registryAddress` and RPC.

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
if you're reusing that fork). Pass it as `registryAddress` and pass
`rpcUrl: 'http://127.0.0.1:8545'` everywhere Steps 2–5 above use
`BASE_SEPOLIA_DEPLOYMENT.AgentRegistryV2` / `network: 'baseSepolia'` —
everything else is identical.
