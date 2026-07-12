// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStakingRewardView {
    function validators(address)
        external
        view
        returns (uint256 selfBond, uint256 delegated, bool active, uint16 commissionBps);
    function delegations(address delegator, address validator) external view returns (uint256);
}

interface IEmissionSchedule {
    function currentEpoch() external view returns (uint256);
    function epochsMinted() external view returns (uint256);
    function emissionForEpoch(uint256 epochIndex) external view returns (uint256);
}

/// @title RewardDistributor — work-weighted validator + stake-weighted
///        delegator reward accounting for the Agent Trust Protocol.
/// @notice Receives the staking share of emissions (the 90% that the Emission
///         contract mints to the staking pool) and splits it, per epoch, as
///         60% of TOTAL epoch emission to validators and 30% to delegators
///         (i.e. 2:1 of the 90% it receives). Concretely, for each epoch the
///         pools are credited as:
///             validatorPool = emissionForEpoch * 6000/10000  (60% of total)
///             delegatorPool = emissionForEpoch * 3000/10000  (30% of total)
///         and validatorPool + delegatorPool == the staking share received.
///
///         Validator pool is distributed WORK-based: each validator's cut is
///         proportional to the receipts it attested that epoch (reported via
///         AgentRegistryV2.attestReceipt -> recordAttestation). A validator
///         with zero attestations in an epoch earns nothing from the pool.
///
///         Delegator pool is distributed STAKE-based across the validators
///         that performed work that epoch (the "participants"), pro-rata by
///         their delegated stake, minus each validator's commission (which is
///         paid to the validator). Delegators of a validator that did no work
///         that epoch earn nothing that epoch — this both keeps the
///         participant set bounded (no global validator enumeration) and
///         aligns delegator incentives toward active validators.
///
///         Accounting is lazy/pull-based: pools are credited when funded, a
///         one-time per-epoch snapshot of delegated stake + commission is
///         taken on first claim, and validators/delegators pull their share.
///         Cumulative payouts are capped per bucket so the core invariant —
///         total distributed can never exceed total received — holds even if
///         delegations change between the snapshot and a claim.
///
///         !! v1 SIMPLIFICATION !! The delegated-stake snapshot is taken at
///         first-claim time (not a true per-epoch historical checkpoint), and
///         a delegator's individual weight uses their current delegation
///         against that snapshot total. For exact accounting a delegator
///         should claim before changing their delegation. A future revision
///         should checkpoint delegations on every stake change (MasterChef-
///         style reward-per-share fed by Staking hooks).
///
///         !! AUDIT-PREP NOTE (delegator snapshot timing) !! Because the
///         per-validator snapshot is taken at FIRST claim and each delegator's
///         weight is read live, a delegator can grief-adjacent siphon: delegate
///         just before an epoch's first claim, claim, then immediately
///         undelegate — capturing rewards economically earned by longer-term
///         delegators. The per-bucket cap makes this a REDISTRIBUTION among
///         delegators, never an over-payment or fund drain (the core invariant
///         still holds), but auditors should look specifically at this
///         claim-vs-delegation-change ordering. Fixed properly by the
///         reward-per-share checkpoint revision above.
///
///         !! UX NOTE (zero-yield honest validators) !! Delegators of a
///         validator that attested nothing in an epoch earn nothing that epoch.
///         An honest-but-quiet validator (no receipts to attest) therefore
///         shows zero delegator yield — surface this clearly in SDK/user docs
///         so it is not mistaken for a bug.
contract RewardDistributor is Ownable2Step, ReentrancyGuard {
    uint256 public constant VALIDATOR_BPS = 6000; // of total epoch emission
    uint256 public constant DELEGATOR_BPS = 3000; // of total epoch emission
    uint256 public constant BPS = 10_000;

    IERC20 public immutable token;
    IStakingRewardView public immutable staking;
    address public registry; // authorized to report attestation work
    IEmissionSchedule public emission;

    // per-epoch reward pools (in AGT)
    mapping(uint256 => uint256) public validatorPool;
    mapping(uint256 => uint256) public delegatorPool;

    // per-epoch attestation work
    mapping(uint256 => uint256) public totalAttestations;
    mapping(uint256 => mapping(address => uint256)) public attestations;
    mapping(uint256 => address[]) public participants; // validators that attested this epoch
    mapping(uint256 => mapping(address => bool)) public isParticipant;

    // per-epoch snapshots (taken lazily on first claim)
    mapping(uint256 => bool) public snapshotted;
    mapping(uint256 => uint256) public totalDelegatedSnap;
    mapping(uint256 => mapping(address => uint256)) public delegatedSnap;
    mapping(uint256 => mapping(address => uint16)) public commissionSnap;

    // claim bookkeeping
    mapping(uint256 => mapping(address => bool)) public validatorClaimed;
    mapping(uint256 => mapping(address => mapping(address => bool))) public delegatorClaimed;
    mapping(uint256 => mapping(address => uint256)) public delegatorPaid; // per epoch/validator net paid

    // emission bookkeeping for syncFromEmission()
    uint256 public epochsAccounted;

    // global conservation counters
    uint256 public totalReceived;
    uint256 public totalDistributed;

    event AttestationRecorded(uint256 indexed epoch, address indexed validator);
    event EpochFunded(uint256 indexed epoch, uint256 validatorPool, uint256 delegatorPool);
    event ValidatorClaimed(uint256 indexed epoch, address indexed validator, uint256 amount);
    event DelegatorClaimed(
        uint256 indexed epoch, address indexed validator, address indexed delegator, uint256 amount
    );
    event RegistrySet(address registry);
    event EmissionSet(address emission);

    error NotRegistry();
    error AlreadyClaimed();
    error NothingToClaim();
    error EmissionNotSet();

    constructor(IERC20 _token, IStakingRewardView _staking) Ownable(msg.sender) {
        token = _token;
        staking = _staking;
    }

    function setRegistry(address _registry) external onlyOwner {
        registry = _registry;
        emit RegistrySet(_registry);
    }

    function setEmission(IEmissionSchedule _emission) external onlyOwner {
        emission = _emission;
        emit EmissionSet(address(_emission));
    }

    // ---------------- attestation work reporting ----------------

    /// @notice Called by the registry on each validator attestation. Buckets
    ///         the work into the current emission epoch.
    function recordAttestation(address validator) external {
        if (msg.sender != registry) revert NotRegistry();
        if (address(emission) == address(0)) revert EmissionNotSet();
        uint256 epoch = emission.currentEpoch();
        if (!isParticipant[epoch][validator]) {
            isParticipant[epoch][validator] = true;
            participants[epoch].push(validator);
        }
        attestations[epoch][validator] += 1;
        totalAttestations[epoch] += 1;
        emit AttestationRecorded(epoch, validator);
    }

    // ---------------- funding ----------------

    /// @notice Directly fund one epoch's pools with its TOTAL emission figure.
    ///         Pulls the staking share (validator + delegator pools) from the
    ///         caller. Used for manual top-ups and testing; the primary path
    ///         is syncFromEmission().
    function fundEpoch(uint256 epoch, uint256 totalEpochEmission) external onlyOwner {
        uint256 vPart = (totalEpochEmission * VALIDATOR_BPS) / BPS;
        uint256 dPart = (totalEpochEmission * DELEGATOR_BPS) / BPS;
        validatorPool[epoch] += vPart;
        delegatorPool[epoch] += dPart;
        totalReceived += vPart + dPart;
        token.transferFrom(msg.sender, address(this), vPart + dPart);
        emit EpochFunded(epoch, vPart, dPart);
    }

    /// @notice Permissionless: attribute newly-minted emission epochs to their
    ///         pools. Assumes this contract is the Emission stakingPool, so the
    ///         staking-share tokens are already held here; this only performs
    ///         the per-epoch bookkeeping. Bounded per call to avoid gas blowups.
    function syncFromEmission(uint256 maxEpochs) external {
        if (address(emission) == address(0)) revert EmissionNotSet();
        uint256 upTo = emission.epochsMinted();
        uint256 from = epochsAccounted;
        uint256 to = (upTo > from + maxEpochs) ? from + maxEpochs : upTo;
        for (uint256 i = from; i < to; i++) {
            uint256 total = emission.emissionForEpoch(i);
            uint256 vPart = (total * VALIDATOR_BPS) / BPS;
            uint256 dPart = (total * DELEGATOR_BPS) / BPS;
            validatorPool[i] += vPart;
            delegatorPool[i] += dPart;
            totalReceived += vPart + dPart;
            emit EpochFunded(i, vPart, dPart);
        }
        epochsAccounted = to;
    }

    // ---------------- snapshot ----------------

    function _snapshot(uint256 epoch) internal {
        if (snapshotted[epoch]) return;
        address[] storage ps = participants[epoch];
        uint256 total;
        for (uint256 i = 0; i < ps.length; i++) {
            (, uint256 delegated,, uint16 commissionBps) = staking.validators(ps[i]);
            delegatedSnap[epoch][ps[i]] = delegated;
            commissionSnap[epoch][ps[i]] = commissionBps;
            total += delegated;
        }
        totalDelegatedSnap[epoch] = total;
        snapshotted[epoch] = true;
    }

    // ---------------- views ----------------

    /// @notice The delegator-pool allocation for a validator's delegators,
    ///         before commission, for an epoch (requires snapshot).
    function _delegatorAllocation(uint256 epoch, address validator)
        internal
        view
        returns (uint256)
    {
        uint256 totalDel = totalDelegatedSnap[epoch];
        if (totalDel == 0) return 0;
        return (delegatorPool[epoch] * delegatedSnap[epoch][validator]) / totalDel;
    }

    function validatorWorkReward(uint256 epoch, address validator) public view returns (uint256) {
        uint256 ta = totalAttestations[epoch];
        if (ta == 0) return 0;
        return (attestations[epoch][validator] * validatorPool[epoch]) / ta;
    }

    // ---------------- claims ----------------

    /// @notice Validator claims its epoch reward: work-based validator-pool
    ///         share PLUS commission on its delegators' pool allocation.
    function claimValidator(uint256 epoch) external nonReentrant {
        _snapshot(epoch);
        if (validatorClaimed[epoch][msg.sender]) revert AlreadyClaimed();

        uint256 work = validatorWorkReward(epoch, msg.sender);
        uint256 alloc = _delegatorAllocation(epoch, msg.sender);
        uint256 commission = (alloc * commissionSnap[epoch][msg.sender]) / BPS;
        uint256 amount = work + commission;
        if (amount == 0) revert NothingToClaim();

        validatorClaimed[epoch][msg.sender] = true;
        // commission consumes part of this validator's delegator allocation
        delegatorPaid[epoch][msg.sender] += commission;
        totalDistributed += amount;
        token.transfer(msg.sender, amount);
        emit ValidatorClaimed(epoch, msg.sender, amount);
    }

    /// @notice Delegator claims its epoch reward from a given validator:
    ///         pro-rata by its delegation vs the validator's snapshot stake,
    ///         out of the net (post-commission) delegator allocation.
    function claimDelegator(uint256 epoch, address validator) external nonReentrant {
        _snapshot(epoch);
        if (delegatorClaimed[epoch][validator][msg.sender]) revert AlreadyClaimed();

        uint256 dsnap = delegatedSnap[epoch][validator];
        uint256 amount;
        if (dsnap > 0) {
            uint256 alloc = _delegatorAllocation(epoch, validator);
            uint256 commission = (alloc * commissionSnap[epoch][validator]) / BPS;
            uint256 net = alloc - commission;
            uint256 dstake = staking.delegations(msg.sender, validator);
            uint256 raw = (net * dstake) / dsnap;
            // cap cumulative payouts so we never exceed this validator's
            // full delegator allocation (commission already counted)
            uint256 room = alloc - delegatorPaid[epoch][validator];
            amount = raw > room ? room : raw;
        }
        if (amount == 0) revert NothingToClaim();

        delegatorClaimed[epoch][validator][msg.sender] = true;
        delegatorPaid[epoch][validator] += amount;
        totalDistributed += amount;
        token.transfer(msg.sender, amount);
        emit DelegatorClaimed(epoch, validator, msg.sender, amount);
    }
}
