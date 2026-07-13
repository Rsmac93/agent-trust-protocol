# AgentKit adapter — `voltpass-agentkit`

**Status: implemented.** Lives at [`agentkit-adapter/`](../../agentkit-adapter)
in the repo root, pinned against `@coinbase/agentkit@0.10.4`, with a passing
end-to-end integration test (`agentkit-adapter/test/integration-test.ts`)
run against a live local Anvil chain + fresh contract deployment. This doc
originally guessed at AgentKit's method names before implementation
(`invokeContract`, `swap` — neither exists); the design below has been
corrected against the real interface, confirmed by reading the installed
`@coinbase/agentkit@0.10.4` package directly (its `WalletProvider` /
`EvmWalletProvider` type declarations, and `ERC20ActionProvider`'s source,
which routes through `sendTransaction`).

## Why the WalletProvider, not the ActionProvider

AgentKit organizes an agent's capabilities into **ActionProviders** — a
`DeFiActionProvider` for swaps, an `ERC20ActionProvider` for transfers, and
so on, each exposing methods decorated with `@CreateAction`. A naive
integration would ask developers to either (a) rewrite every ActionProvider
they use to call VoltPass after each action, or (b) wrap every individual
action method. Both fail the zero-code requirement — (a) touches existing
provider code, (b) requires per-provider, per-action wrapping that breaks
the moment a new ActionProvider is added.

The actual choke point is one level down: **every ActionProvider that moves
funds or calls a contract does so through a `WalletProvider`** (AgentKit's
abstraction over CDP Wallet, a Viem wallet, etc. — the same object AgentKit
passes as the first argument to any action that needs on-chain access).
Wrap that one object, and every current and future ActionProvider's trades
are covered automatically, because they all call through it.

## Design

```ts
// voltpass-agentkit — wraps any AgentKit WalletProvider so every
// sendTransaction / nativeTransfer call is auto-logged as a VoltPass
// receipt. Zero changes to existing ActionProviders.

import type { WalletProvider } from "@coinbase/agentkit";
import { VoltPass, canonicalHash, type ActionReceipt } from "voltpass-sdk";

export interface VoltPassWalletOptions {
  /** Deployed AgentRegistryV2 address */
  registryAddress: `0x${string}`;
  /** VoltPass agentId this wallet's trades should be attributed to.
   *  Call `registerAgentOnce()` below if you don't have one yet. */
  agentId: bigint;
  /** Private key used ONLY for the VoltPass logReceipt tx — separate from
   *  the wallet provider's own trading key. Can be the same key if the
   *  agent's own wallet is registered as its own VoltPass principal. */
  loggerPrivateKey: `0x${string}`;
  /** Called on logging failures. Never throws into the wrapped call —
   *  a VoltPass outage must never block a real trade. */
  onLogError?: (err: unknown, txHash: string) => void;
}

/** Wraps `inner` so every value-moving / contract-calling method also
 *  produces a VoltPass receipt after the underlying tx confirms. Pass the
 *  result to AgentKit's `AgentKit.from({ walletProvider })` exactly as you
 *  would the unwrapped provider — no other code changes. */
export function withVoltPassLogging<T extends WalletProvider>(
  inner: T,
  opts: VoltPassWalletOptions,
): T {
  const voltpass = new VoltPass({
    registryAddress: opts.registryAddress,
    privateKey: opts.loggerPrivateKey,
  });

  // voltpass-sdk's canonicalHash() JSON.stringify's the payload, which
  // throws on raw bigints — and sendTransaction's TransactionRequest args
  // routinely carry bigint fields (value, gas, maxFeePerGas, ...). The real
  // implementation stringifies bigints recursively before logging (found
  // during integration testing: a plain ETH sendTransaction call was
  // silently failing to log until this was added — omitted here for
  // brevity, see agentkit-adapter/src/index.ts for the full sanitize()).
  //
  // Fire-and-forget logging: the wrapped call returns as soon as the
  // underlying wallet operation resolves. Receipt logging happens after,
  // asynchronously, and never delays or fails the trade itself.
  async function logAfter(action: string, args: unknown, txHash: string) {
    try {
      const receipt: ActionReceipt = {
        agentId: opts.agentId,
        action,
        payload: { args: sanitize(args), txHash },
      };
      await voltpass.logReceipt(receipt);
    } catch (err) {
      opts.onLogError?.(err, txHash);
    }
  }

  // Proxy every method on the wallet provider. Methods whose names match
  // AgentKit's two real fund-moving/tx-submitting choke points get the
  // auto-log behavior; everything else (balance reads, address lookups,
  // readContract, waitForTransactionReceipt) passes through untouched.
  //
  // Confirmed against @coinbase/agentkit@0.10.4's real WalletProvider /
  // EvmWalletProvider interface (not guessed): `sendTransaction` and
  // `nativeTransfer` are the only two fund-moving methods, and both return
  // the tx hash as a plain string — no "result might be an object with
  // .hash" case exists in the real interface, so no normalization is
  // needed here.
  const LOGGED_METHODS = new Set(["sendTransaction", "nativeTransfer"]);

  return new Proxy(inner, {
    get(target, prop, receiver) {
      const orig = Reflect.get(target, prop, receiver);
      if (typeof orig !== "function" || typeof prop !== "string") {
        return orig;
      }
      if (!LOGGED_METHODS.has(prop)) {
        return orig.bind(target);
      }
      return async function (...args: unknown[]) {
        const txHash = (await orig.apply(target, args)) as string;
        // Deliberately not awaited — see logAfter's fire-and-forget note.
        void logAfter(prop, args, txHash);
        return txHash;
      };
    },
  });
}

/** One-time helper: registers this agent's wallet address as a VoltPass
 *  principal, returning the agentId to pass into `withVoltPassLogging`.
 *  Run once per agent (e.g. in a setup script), not on every startup. */
export async function registerAgentOnce(opts: {
  registryAddress: `0x${string}`;
  privateKey: `0x${string}`;
  name: string;
  model?: string;
}): Promise<bigint> {
  const voltpass = new VoltPass({
    registryAddress: opts.registryAddress,
    privateKey: opts.privateKey,
  });
  const { agentId } = await voltpass.registerAgent({
    name: opts.name,
    model: opts.model,
    capabilities: ["defi-trading"],
  });
  return agentId;
}
```

## Developer-facing integration (the entire diff)

```ts
// Before (standard AgentKit setup):
const walletProvider = new ViemWalletProvider(walletClient);
const agentKit = await AgentKit.from({ walletProvider });

// After (the ONLY change — one wrap, at construction time):
import { withVoltPassLogging } from "voltpass-agentkit";

const walletProvider = withVoltPassLogging(
  new ViemWalletProvider(walletClient),
  {
    registryAddress: "0x...",
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

## What this does NOT cover (honest limitations)

- **Read-only actions** (balance checks, address/network lookups,
  `readContract`, `waitForTransactionReceipt`) are correctly *not* logged
  — VoltPass receipts are for actions with real economic effect, not
  queries. `LOGGED_METHODS` (`sendTransaction`, `nativeTransfer`) was
  verified against `@coinbase/agentkit@0.10.4`'s actual `WalletProvider`
  interface, not the documented/guessed one this design started from — if
  a future AgentKit release adds a new fund-moving choke point outside
  these two methods, `LOGGED_METHODS` needs a matching update.
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
