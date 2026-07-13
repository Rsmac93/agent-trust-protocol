// voltpass-agentkit — wraps any AgentKit WalletProvider so every
// sendTransaction / nativeTransfer call is auto-logged as a VoltPass
// receipt. Zero changes to existing ActionProviders.
//
// Pinned against @coinbase/agentkit@0.10.4. Verified against that
// package's real interface (not guessed): every fund-moving ActionProvider
// (e.g. ERC20ActionProvider.transfer) routes through
// EvmWalletProvider.sendTransaction(...); native ETH sends go through
// WalletProvider.nativeTransfer(...). Both return the tx hash as a plain
// string in the real interface — there's no "result might be wrapped in an
// object" case to normalize.

import type { WalletProvider } from '@coinbase/agentkit';
import { VoltPass, type ActionReceipt } from 'voltpass-sdk';

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
  /** 'baseSepolia' (testnet, default) or 'base'. Passed through to the
   *  underlying VoltPass SDK client used for logging receipts. */
  network?: 'base' | 'baseSepolia';
  /** Optional custom RPC URL for the VoltPass logging client (defaults to
   *  the SDK's network default; does NOT need to match the wallet
   *  provider's own RPC). */
  rpcUrl?: string;
  /** Called on logging failures. Never throws into the wrapped call —
   *  a VoltPass outage must never block a real trade. */
  onLogError?: (err: unknown, txHash: string) => void;
}

/** Methods on AgentKit's WalletProvider / EvmWalletProvider hierarchy that
 *  actually move funds or submit transactions on-chain, as of
 *  @coinbase/agentkit@0.10.4. Every ActionProvider that moves funds routes
 *  through one of these two — confirmed by reading
 *  action-providers/erc20/erc20ActionProvider.js, which calls
 *  walletProvider.sendTransaction(...) internally. Read-only methods
 *  (getBalance, getAddress, getNetwork, getName, readContract,
 *  getPublicClient, waitForTransactionReceipt) are deliberately excluded —
 *  VoltPass receipts are for actions with real economic effect, not
 *  queries. */
const LOGGED_METHODS = new Set(['sendTransaction', 'nativeTransfer']);

/** Wraps `inner` so every value-moving method (`sendTransaction`,
 *  `nativeTransfer`) also produces a VoltPass receipt after the underlying
 *  tx confirms. Pass the result to AgentKit's `AgentKit.from({
 *  walletProvider })` exactly as you would the unwrapped provider — no
 *  other code changes. */
export function withVoltPassLogging<T extends WalletProvider>(
  inner: T,
  opts: VoltPassWalletOptions,
): T {
  const voltpassOpts: ConstructorParameters<typeof VoltPass>[0] = {
    registryAddress: opts.registryAddress,
    privateKey: opts.loggerPrivateKey,
    ...(opts.network !== undefined ? { network: opts.network } : {}),
    ...(opts.rpcUrl !== undefined ? { rpcUrl: opts.rpcUrl } : {}),
  };
  const voltpass = new VoltPass(voltpassOpts);

  // Fire-and-forget logging: the wrapped call returns as soon as the
  // underlying wallet operation resolves. Receipt logging happens after,
  // asynchronously, and never delays or fails the trade itself.
  //
  // Note: sendTransaction's TransactionRequest args routinely carry raw
  // bigint fields (value, gas, maxFeePerGas, ...) — passed straight through
  // here uncoerced. voltpass-sdk@0.1.1's canonicalHash() (used internally
  // by logReceipt) recursively stringifies bigints before JSON.stringify,
  // so this doesn't need its own sanitize layer — see voltpass-sdk's
  // test/canonicalHash.test.ts for the regression coverage. Requires
  // voltpass-sdk >=0.1.1; this package's package.json pins that floor.
  async function logAfter(action: string, args: unknown, txHash: string) {
    try {
      const receipt: ActionReceipt = {
        agentId: opts.agentId,
        action,
        payload: { args, txHash },
      };
      await voltpass.logReceipt(receipt);
    } catch (err) {
      opts.onLogError?.(err, txHash);
    }
  }

  return new Proxy(inner, {
    get(target, prop, receiver) {
      const orig = Reflect.get(target, prop, receiver);
      if (typeof orig !== 'function' || typeof prop !== 'string') {
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
  network?: 'base' | 'baseSepolia';
  rpcUrl?: string;
}): Promise<bigint> {
  const voltpassOpts: ConstructorParameters<typeof VoltPass>[0] = {
    registryAddress: opts.registryAddress,
    privateKey: opts.privateKey,
    ...(opts.network !== undefined ? { network: opts.network } : {}),
    ...(opts.rpcUrl !== undefined ? { rpcUrl: opts.rpcUrl } : {}),
  };
  const voltpass = new VoltPass(voltpassOpts);
  const { agentId } = await voltpass.registerAgent({
    name: opts.name,
    ...(opts.model !== undefined ? { model: opts.model } : {}),
    capabilities: ['defi-trading'],
  });
  return agentId;
}
