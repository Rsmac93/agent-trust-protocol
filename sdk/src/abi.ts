// Minimal ABI for AgentRegistryV2 — only what the SDK touches.
export const REGISTRY_ABI = [
  {
    type: 'function', name: 'registerAgent', stateMutability: 'payable',
    inputs: [{ name: 'metadataHash', type: 'bytes32' }],
    outputs: [{ name: 'agentId', type: 'uint256' }],
  },
  {
    type: 'function', name: 'logReceipt', stateMutability: 'nonpayable',
    inputs: [
      { name: 'agentId', type: 'uint256' },
      { name: 'receiptHash', type: 'bytes32' },
    ],
    outputs: [],
  },
  {
    type: 'function', name: 'reputation', stateMutability: 'view',
    inputs: [{ name: 'agentId', type: 'uint256' }],
    outputs: [{ name: '', type: 'int256' }],
  },
  {
    type: 'function', name: 'agents', stateMutability: 'view',
    inputs: [{ name: '', type: 'uint256' }],
    outputs: [
      { name: 'principal', type: 'address' },
      { name: 'metadataHash', type: 'bytes32' },
      { name: 'registeredAt', type: 'uint64' },
      { name: 'active', type: 'bool' },
      { name: 'selfReceipts', type: 'uint64' },
      { name: 'attestedReceipts', type: 'uint64' },
      { name: 'disputes', type: 'uint64' },
    ],
  },
  {
    type: 'function', name: 'registrationFee', stateMutability: 'view',
    inputs: [], outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'deactivate', stateMutability: 'nonpayable',
    inputs: [{ name: 'agentId', type: 'uint256' }], outputs: [],
  },
  {
    type: 'function', name: 'attestReceipt', stateMutability: 'nonpayable',
    inputs: [
      { name: 'agentId', type: 'uint256' },
      { name: 'receiptHash', type: 'bytes32' },
    ],
    outputs: [],
  },
  {
    type: 'function', name: 'attestor', stateMutability: 'view',
    inputs: [
      { name: '', type: 'uint256' },
      { name: '', type: 'bytes32' },
    ],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    type: 'event', name: 'AgentRegistered',
    inputs: [
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'principal', type: 'address', indexed: true },
      { name: 'metadataHash', type: 'bytes32', indexed: false },
    ],
  },
  {
    type: 'event', name: 'ReceiptLogged',
    inputs: [
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'receiptHash', type: 'bytes32', indexed: true },
    ],
  },
  {
    type: 'event', name: 'ReceiptAttested',
    inputs: [
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'receiptHash', type: 'bytes32', indexed: true },
      { name: 'validator', type: 'address', indexed: true },
    ],
  },
] as const;

/// Minimal ABI for PerformancePassport — only what the SDK touches.
export const PASSPORT_ABI = [
  {
    type: 'function', name: 'submitClaim', stateMutability: 'nonpayable',
    inputs: [
      { name: 'agentId', type: 'uint256' },
      { name: 'epoch', type: 'uint32' },
      { name: 'claimType', type: 'uint8' },
      { name: 'claimData', type: 'uint256' },
      { name: 'receiptHashRangeStart', type: 'bytes32' },
      { name: 'receiptHashRangeEnd', type: 'bytes32' },
      { name: 'proof', type: 'bytes' },
    ],
    outputs: [],
  },
  {
    type: 'function', name: 'latestClaim', stateMutability: 'view',
    inputs: [{ name: 'agentId', type: 'uint256' }],
    outputs: [{ name: 'latestEpoch', type: 'uint32' }],
  },
  {
    type: 'function', name: 'getLatestClaim', stateMutability: 'view',
    inputs: [{ name: 'agentId', type: 'uint256' }],
    outputs: [{
      name: '', type: 'tuple',
      components: [
        { name: 'agentId', type: 'uint256' },
        { name: 'epoch', type: 'uint32' },
        { name: 'claimType', type: 'uint8' },
        { name: 'claimData', type: 'uint256' },
        { name: 'receiptHashRangeStart', type: 'bytes32' },
        { name: 'receiptHashRangeEnd', type: 'bytes32' },
        { name: 'submittedAt', type: 'uint64' },
        { name: 'verifierSignature', type: 'bytes' },
      ],
    }],
  },
  {
    type: 'event', name: 'ClaimSubmitted',
    inputs: [
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'epoch', type: 'uint32', indexed: true },
      { name: 'claimType', type: 'uint8', indexed: false },
    ],
  },
  {
    type: 'event', name: 'ClaimVerified',
    inputs: [
      { name: 'agentId', type: 'uint256', indexed: true },
      { name: 'epoch', type: 'uint32', indexed: true },
    ],
  },
] as const;
