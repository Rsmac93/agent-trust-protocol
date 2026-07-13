# ElizaOS adapter — `@elizaos-plugins/plugin-voltpass`

## Why the Evaluator, not the Action

ElizaOS's plugin system composes four kinds of extension: **Actions**
(things the agent can do), **Providers** (data sources fed into the
agent's context), **Evaluators** (run *after* an action/response, used to
score, filter, or post-process what just happened), and **Services**
(long-lived background singletons a plugin can register).

A naive integration would add VoltPass logging as a new **Action** — e.g.
an explicit "log this trade" action the agent has to decide to call. That
fails the zero-code requirement in the same way explicit SDK calls do: it
depends on the agent (or the developer's action, or the LLM's judgment)
choosing to invoke it, and every existing trading plugin (`plugin-auto-trader`,
`plugin-arbitrage`, any custom swap plugin) would need to know to call it.

**Evaluators are explicitly designed for this exact use case** — they run
after every action completes, regardless of which plugin's action just
executed, and receive the action's result. That is the framework's own
"something happened, now process it" hook. Pointing a VoltPass evaluator at
that hook means *any* trading plugin — present or future, first-party or
third-party — gets its trades logged without knowing VoltPass exists.

## Design

```ts
// @elizaos-plugins/plugin-voltpass
//
// Contributes:
//   - VoltPassService   — background singleton holding the VoltPass client
//   - voltpassEvaluator — runs after every action; if the action's result
//                          looks like a trade, logs it as a VoltPass receipt
//
// Zero changes required to existing trading plugins (plugin-auto-trader,
// plugin-arbitrage, custom swap actions, etc.) — this plugin observes their
// output, it doesn't participate in their execution.

import type {
  Plugin,
  IAgentRuntime,
  Memory,
  State,
  Evaluator,
  Service,
} from "@elizaos/core";
import { VoltPass, canonicalHash, type ActionReceipt } from "voltpass-sdk";

// ---------------------------------------------------------------------
// Service: one VoltPass client per running agent, constructed once from
// character/plugin settings and reused across every evaluator invocation.
// ---------------------------------------------------------------------

export class VoltPassService implements Service {
  static serviceType = "voltpass" as const;
  private client!: VoltPass;
  private agentId!: bigint;

  async initialize(runtime: IAgentRuntime): Promise<void> {
    const registryAddress = runtime.getSetting("VOLTPASS_REGISTRY_ADDRESS");
    const loggerKey = runtime.getSetting("VOLTPASS_LOGGER_KEY");
    const agentIdSetting = runtime.getSetting("VOLTPASS_AGENT_ID");

    if (!registryAddress || !loggerKey || !agentIdSetting) {
      throw new Error(
        "plugin-voltpass: VOLTPASS_REGISTRY_ADDRESS, VOLTPASS_LOGGER_KEY, " +
          "and VOLTPASS_AGENT_ID must be set (character secrets or env). " +
          "Run the one-time registration script if you don't have an " +
          "agentId yet — see registerAgentOnce() in the AgentKit adapter " +
          "doc, the registration flow is identical.",
      );
    }
    this.agentId = BigInt(agentIdSetting);
    this.client = new VoltPass({
      registryAddress: registryAddress as `0x${string}`,
      privateKey: loggerKey as `0x${string}`,
    });
  }

  async logTrade(action: string, memory: Memory, extracted: TradeShape): Promise<void> {
    const receipt: ActionReceipt = {
      agentId: this.agentId,
      action,
      payload: {
        roomId: memory.roomId,
        txHash: extracted.txHash,
        pair: extracted.pair,
        amount: extracted.amount,
        side: extracted.side,
      },
    };
    await this.client.logReceipt(receipt);
  }
}

// ---------------------------------------------------------------------
// Evaluator: fires after every action. `validate` cheaply checks whether
// the just-completed action looks trade-shaped before `handler` does any
// real work — most non-trading actions (chat replies, memory lookups)
// short-circuit here at near-zero cost.
// ---------------------------------------------------------------------

interface TradeShape {
  txHash: string;
  pair?: string;
  amount?: string;
  side?: "buy" | "sell";
}

/** Recognizes the shape trading plugins conventionally return: a result
 *  object or memory content carrying a transaction hash plus optional
 *  trade metadata. Matches by structure, not by plugin name, so it works
 *  against plugins this adapter has never seen. */
function extractTradeShape(memory: Memory): TradeShape | null {
  const content = memory.content as Record<string, unknown>;
  const txHash =
    (content.txHash as string) ??
    (content.transactionHash as string) ??
    (content.hash as string);
  if (!txHash || !/^0x[0-9a-fA-F]{64}$/.test(txHash)) return null;
  return {
    txHash,
    pair: content.pair as string | undefined,
    amount: (content.amount ?? content.amountIn) as string | undefined,
    side: content.side as "buy" | "sell" | undefined,
  };
}

export const voltpassEvaluator: Evaluator = {
  name: "VOLTPASS_AUTO_LOG",
  similes: ["LOG_TRADE_RECEIPT", "NOTARIZE_TRADE"],
  description:
    "Automatically logs a VoltPass receipt for any completed action whose " +
    "result contains a transaction hash — covers every trading plugin " +
    "without requiring them to know VoltPass exists.",

  // Cheap structural check — no network calls, safe to run on every action.
  validate: async (_runtime: IAgentRuntime, memory: Memory, _state?: State) => {
    return extractTradeShape(memory) !== null;
  },

  // Only reached when validate() found a trade-shaped result.
  handler: async (runtime: IAgentRuntime, memory: Memory, _state?: State) => {
    const trade = extractTradeShape(memory);
    if (!trade) return; // defensive; validate() already gated this

    const service = runtime.getService<VoltPassService>(
      VoltPassService.serviceType,
    );
    if (!service) {
      runtime.logger?.warn(
        "plugin-voltpass: VoltPassService not initialized, skipping log " +
          `for tx ${trade.txHash}`,
      );
      return;
    }

    try {
      await service.logTrade(memory.content?.action as string ?? "trade", memory, trade);
    } catch (err) {
      // Never throw out of an evaluator — a VoltPass outage must not
      // break the agent's normal response flow.
      runtime.logger?.error(`plugin-voltpass: logReceipt failed — ${err}`);
    }
  },

  examples: [], // populated at implementation time per ElizaOS convention
};

// ---------------------------------------------------------------------
// Plugin export — the entire developer-facing integration surface.
// ---------------------------------------------------------------------

export const voltpassPlugin: Plugin = {
  name: "voltpass",
  description: "Auto-logs every trade action as a VoltPass receipt.",
  services: [VoltPassService],
  evaluators: [voltpassEvaluator],
  actions: [],
  providers: [],
};

export default voltpassPlugin;
```

## Developer-facing integration (the entire diff)

```json5
// character.json — the ONLY change: add one plugin + three settings.
{
  "name": "MyTradingBot",
  "plugins": [
    "@elizaos-plugins/plugin-auto-trader",  // existing trading plugin, untouched
    "@elizaos-plugins/plugin-voltpass"       // new — that's the whole integration
  ],
  "settings": {
    "secrets": {
      "VOLTPASS_REGISTRY_ADDRESS": "0x...",
      "VOLTPASS_LOGGER_KEY": "0x...",
      "VOLTPASS_AGENT_ID": "4217"
    }
  }
}
```

`plugin-auto-trader`, `plugin-arbitrage`, or any custom trading plugin
already in the character's `plugins` array needs **no modification**.
Every action they complete that produces a recognizable transaction hash
gets picked up by the evaluator and logged automatically.

## What this does NOT cover (honest limitations)

- **Structural matching is a best-effort heuristic**, not a guarantee.
  `extractTradeShape` looks for common field names (`txHash`,
  `transactionHash`, `hash`) on the action's result memory — a trading
  plugin that returns its tx hash under an unconventional field name
  won't be picked up without extending the matcher. This is the honest
  cost of "zero code changes to existing plugins": there's no explicit
  contract to rely on, only convention.
- **Evaluators run per-action, not per-sub-transaction.** If a single
  action internally executes multiple trades (e.g. a multi-leg arbitrage)
  and only surfaces one tx hash in its result, only that one gets logged.
  Full coverage of multi-leg actions would require the trading plugin
  itself to surface each leg — which reintroduces the coordination problem
  this design is trying to avoid. Worth flagging to any plugin author
  this adapter partners with directly.
- **Same attestation caveat as the AgentKit adapter** — this covers only
  the self-reported `logReceipt` lane, not validator attestation.
- **Exact ElizaOS core types** (`IAgentRuntime`, `Memory`, `State`,
  `Evaluator`, `Service`) should be pinned against the actual installed
  `@elizaos/core` version at implementation time — the plugin system has
  moved fast historically and field names may have shifted since this
  research pass.
