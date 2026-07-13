# Auto-logging adapters — research + design

VoltPass's value only compounds if agents actually log their trades. Asking
every developer to sprinkle `voltpass.logReceipt(...)` after every trade call
is exactly the kind of "one more thing to remember" friction that kills
adoption. The right integration point is **the framework's own execution
choke point** — the place every trade already passes through regardless of
which strategy or plugin produced it — so logging happens automatically, with
zero code changes to existing agent logic.

This doc covers the research (why these two frameworks) and links to the two
adapter designs.

## Landscape (researched July 2026)

| Framework | Chain focus | Why it's relevant to VoltPass | Why NOT chosen for the first two adapters |
|---|---|---|---|
| **Coinbase AgentKit** | Base-native (CDP SDK), broader EVM + Solana | Official Coinbase stack; Base is VoltPass's home chain; wallet-provider abstraction is a single clean choke point | — (selected) |
| **ElizaOS** | Chain-agnostic (60+ chains via plugins), heavy Base/EVM usage | Most widely deployed open-source agent framework in crypto ("WordPress for Agents"); explicit Evaluator hook designed exactly for post-action processing | — (selected) |
| GOAT | Multi-framework tool library (LangChain, Vercel AI, LlamaIndex, MCP, OpenAI) | 200+ onchain tools, TS + Python, broad reach | A tool *library*, not an agent framework with its own lifecycle — no single choke point to hook; would need per-consuming-framework adapters anyway |
| Virtuals Protocol | Base-native agent economy/launchpad | Large ecosystem (15,800+ agent projects, $477M aGDP as of Feb 2026) | Primarily an agent *marketplace/tokenization* layer, not a dev-facing execution framework — agents built elsewhere (often AgentKit or ElizaOS) plug into it |
| LangChain / CrewAI / AutoGen | General-purpose LLM orchestration | Widely used for the *reasoning* layer of trading agents | Not trading-specific; the actual trade execution in these stacks is usually delegated to AgentKit, GOAT, or custom code anyway — better to hook at the execution layer, not the orchestration layer |

**Selected: Coinbase AgentKit and ElizaOS.** Both are Base/EVM-first (or
Base-first), both have an explicit, documented interception point that
covers *every* trade action regardless of which specific action/plugin
triggered it, and together they cover the two dominant patterns in the
space: a minimal wallet-centric SDK (AgentKit) and a full agent runtime with
a plugin/character system (ElizaOS).

## The zero-code principle

Both adapters below follow the same rule: **the developer's existing trading
code is never touched.** Integration is a single line at agent-construction
time (wrap a wallet provider, or add a plugin to a character file) — after
that, every trade the agent executes is auto-logged as a VoltPass receipt
with no further action from the developer.

- [`agentkit-adapter.md`](./agentkit-adapter.md) — wraps AgentKit's
  `WalletProvider`, the single choke point every ActionProvider's on-chain
  effects pass through.
- [`elizaos-adapter.md`](./elizaos-adapter.md) — a plugin contributing a
  `Service` (holds the VoltPass client) + an `Evaluator` (runs after every
  action, regardless of which plugin produced it).

## Status

- **AgentKit adapter: implemented.** Lives at
  [`agentkit-adapter/`](../../agentkit-adapter) in the repo root, pinned
  against `@coinbase/agentkit@0.10.4`, with a passing end-to-end
  integration test run against a live local Anvil chain + fresh contract
  deployment (auto-logged `sendTransaction`/`nativeTransfer` receipts,
  read-only calls correctly excluded).
- **ElizaOS adapter: design only** — pseudocode/interface-level, not yet
  implemented or tested against a live ElizaOS agent. A natural next SDK
  milestone once a real integration partner is lined up (see
  [NOIR_GRANT_PROPOSAL.md](../NOIR_GRANT_PROPOSAL.md) for the parallel ZK
  circuit funding track — this adapter would similarly suit a Base
  ecosystem grant or a direct partnership pitch to the ElizaOS team).
