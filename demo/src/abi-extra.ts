// Minimal ABIs for the contracts the demo touches directly (setup + optional
// reward finale). The registry/reputation surface goes through the SDK
// (agent-trust-sdk); these are the protocol-admin / validator-side pieces
// that are intentionally out of the agent-facing SDK's scope.

export const ERC20_ABI = [
  {
    type: 'function', name: 'approve', stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function', name: 'transfer', stateMutability: 'nonpayable',
    inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'decimals', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint8' }],
  },
] as const;

export const STAKING_ABI = [
  {
    type: 'function', name: 'bond', stateMutability: 'nonpayable',
    inputs: [{ name: 'amount', type: 'uint256' }, { name: 'commissionBps', type: 'uint16' }],
    outputs: [],
  },
  {
    type: 'function', name: 'validators', stateMutability: 'view',
    inputs: [{ name: '', type: 'address' }],
    outputs: [
      { name: 'selfBond', type: 'uint256' },
      { name: 'delegated', type: 'uint256' },
      { name: 'active', type: 'bool' },
      { name: 'commissionBps', type: 'uint16' },
    ],
  },
  {
    type: 'function', name: 'MIN_BOND', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
] as const;

export const EMISSION_ABI = [
  { type: 'function', name: 'mintPending', stateMutability: 'nonpayable', inputs: [], outputs: [] },
  {
    type: 'function', name: 'currentEpoch', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'epochsMinted', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'emissionForEpoch', stateMutability: 'pure',
    inputs: [{ name: 'epochIndex', type: 'uint256' }], outputs: [{ name: '', type: 'uint256' }],
  },
] as const;

export const REWARD_DISTRIBUTOR_ABI = [
  {
    type: 'function', name: 'syncFromEmission', stateMutability: 'nonpayable',
    inputs: [{ name: 'maxEpochs', type: 'uint256' }], outputs: [],
  },
  {
    type: 'function', name: 'claimValidator', stateMutability: 'nonpayable',
    inputs: [{ name: 'epoch', type: 'uint256' }], outputs: [],
  },
  {
    type: 'function', name: 'validatorWorkReward', stateMutability: 'view',
    inputs: [{ name: 'epoch', type: 'uint256' }, { name: 'validator', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'validatorPool', stateMutability: 'view',
    inputs: [{ name: '', type: 'uint256' }], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'totalAttestations', stateMutability: 'view',
    inputs: [{ name: '', type: 'uint256' }], outputs: [{ name: '', type: 'uint256' }],
  },
] as const;
