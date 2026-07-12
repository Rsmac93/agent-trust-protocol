// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AGTToken} from "./AGTToken.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Staking — validator bonding, delegation & slashing for the
///        Agent Trust Protocol.
/// @notice Validators bond >= MIN_BOND to earn the right to attest agent
///         receipts. Emissions arrive from the Emission contract and are
///         split 60% validators / 30% delegators (of the total epoch
///         emission; i.e. 2/3 : 1/3 of what this pool receives).
///         Slashing: false attestation 20%, double-sign 10%, downtime 0.5%.
///         50% of slashed stake burned, 50% to the challenger.
contract Staking is Ownable2Step, ReentrancyGuard {
    uint256 public constant MIN_BOND = 1_000e18;
    uint256 public constant UNBONDING_PERIOD = 21 days;

    // slash rates in basis points
    uint256 public constant SLASH_FALSE_ATTESTATION = 2000; // 20%
    uint256 public constant SLASH_DOUBLE_SIGN = 1000; // 10%
    uint256 public constant SLASH_DOWNTIME = 50; // 0.5%

    AGTToken public immutable token;
    /// @notice contract authorized to prove misbehavior (dispute module)
    address public slasher;

    struct Validator {
        uint256 selfBond;
        uint256 delegated;
        bool active;
        uint16 commissionBps; // 0–2000 (0–20%)
    }

    struct Unbond {
        uint256 amount;
        uint256 releaseAt;
        address validator; // originating validator (self for validator unbonds)
    }

    mapping(address => Validator) public validators;
    mapping(address => mapping(address => uint256)) public delegations; // delegator => validator => amount
    mapping(address => Unbond[]) public unbonds;

    uint256 public totalBonded;

    event Bonded(address indexed validator, uint256 amount);
    event Delegated(address indexed delegator, address indexed validator, uint256 amount);
    event UnbondQueued(address indexed who, uint256 amount, uint256 releaseAt);
    event Withdrawn(address indexed who, uint256 amount);
    event Slashed(address indexed validator, uint256 amount, uint8 reason, address challenger);
    event SlasherSet(address slasher);

    error BelowMinBond();
    error NotActiveValidator();
    error NotSlasher();
    error NothingClaimable();
    error CommissionTooHigh();

    constructor(AGTToken _token) Ownable(msg.sender) {
        token = _token;
    }

    function setSlasher(address _slasher) external onlyOwner {
        slasher = _slasher;
        emit SlasherSet(_slasher);
    }

    // ---------------- bonding ----------------

    function bond(uint256 amount, uint16 commissionBps) external nonReentrant {
        if (commissionBps > 2000) revert CommissionTooHigh();
        Validator storage v = validators[msg.sender];
        token.transferFrom(msg.sender, address(this), amount);
        v.selfBond += amount;
        v.commissionBps = commissionBps;
        if (v.selfBond < MIN_BOND) revert BelowMinBond();
        v.active = true;
        totalBonded += amount;
        emit Bonded(msg.sender, amount);
    }

    function delegate(address validator, uint256 amount) external nonReentrant {
        Validator storage v = validators[validator];
        if (!v.active) revert NotActiveValidator();
        token.transferFrom(msg.sender, address(this), amount);
        v.delegated += amount;
        delegations[msg.sender][validator] += amount;
        totalBonded += amount;
        emit Delegated(msg.sender, validator, amount);
    }

    // ---------------- unbonding ----------------

    function startUnbondValidator(uint256 amount) external {
        Validator storage v = validators[msg.sender];
        v.selfBond -= amount; // reverts on underflow
        if (v.selfBond < MIN_BOND) v.active = false;
        _queueUnbond(msg.sender, msg.sender, amount);
    }

    function startUndelegate(address validator, uint256 amount) external {
        delegations[msg.sender][validator] -= amount;
        validators[validator].delegated -= amount;
        _queueUnbond(msg.sender, validator, amount);
    }

    function _queueUnbond(address who, address validator, uint256 amount) internal {
        totalBonded -= amount;
        uint256 releaseAt = block.timestamp + UNBONDING_PERIOD;
        unbonds[who].push(Unbond(amount, releaseAt, validator));
        emit UnbondQueued(who, amount, releaseAt);
    }

    function withdraw() external nonReentrant {
        Unbond[] storage q = unbonds[msg.sender];
        uint256 claimable;
        for (uint256 i = 0; i < q.length; i++) {
            if (q[i].amount > 0 && block.timestamp >= q[i].releaseAt) {
                claimable += q[i].amount;
                q[i].amount = 0;
            }
        }
        if (claimable == 0) revert NothingClaimable();
        token.transfer(msg.sender, claimable);
        emit Withdrawn(msg.sender, claimable);
    }

    // ---------------- slashing ----------------

    /// @notice Sum of the validator's own queued unbonds that have not yet
    ///         matured (still inside the unbonding period). These remain
    ///         slashable until releaseAt — a validator cannot evade a slash
    ///         by queuing an unbond before the dispute resolves.
    function slashableUnbonding(address validator) public view returns (uint256 queued) {
        Unbond[] storage q = unbonds[validator];
        for (uint256 i = 0; i < q.length; i++) {
            if (
                q[i].validator == validator && q[i].amount > 0
                    && block.timestamp < q[i].releaseAt
            ) {
                queued += q[i].amount;
            }
        }
    }

    /// @param reason 0 = false attestation, 1 = double sign, 2 = downtime
    /// @dev Penalty is computed on the validator's full exposure — active
    ///      selfBond PLUS their still-unbonding queued amounts — and taken
    ///      pro-rata from the two buckets. Matured (releasable) entries are
    ///      immune, as is delegated stake (unchanged from v1).
    function slash(address validator, uint8 reason, address challenger)
        external
        nonReentrant
    {
        if (msg.sender != slasher) revert NotSlasher();
        Validator storage v = validators[validator];
        uint256 rate = reason == 0
            ? SLASH_FALSE_ATTESTATION
            : reason == 1 ? SLASH_DOUBLE_SIGN : SLASH_DOWNTIME;

        uint256 queued = slashableUnbonding(validator);
        uint256 exposure = v.selfBond + queued;
        uint256 penalty = (exposure * rate) / 10_000;

        // pro-rata split between active selfBond and unbonding queue
        uint256 fromSelf = exposure == 0 ? 0 : (penalty * v.selfBond) / exposure;
        uint256 fromQueue = penalty - fromSelf;

        v.selfBond -= fromSelf;
        if (v.selfBond < MIN_BOND) v.active = false;
        totalBonded -= fromSelf; // queued amounts already left totalBonded

        if (fromQueue > 0) {
            Unbond[] storage q = unbonds[validator];
            uint256 remaining = fromQueue;
            for (uint256 i = 0; i < q.length && remaining > 0; i++) {
                if (
                    q[i].validator == validator && q[i].amount > 0
                        && block.timestamp < q[i].releaseAt
                ) {
                    uint256 cut = q[i].amount < remaining ? q[i].amount : remaining;
                    q[i].amount -= cut;
                    remaining -= cut;
                }
            }
            penalty -= remaining; // dust safety; remaining is 0 in practice
        }

        uint256 toChallenger = penalty / 2;
        token.burn(penalty - toChallenger); // 50% burned
        if (toChallenger > 0) token.transfer(challenger, toChallenger);

        emit Slashed(validator, penalty, reason, challenger);
    }

    // NOTE (v1): reward distribution (60/30 split, commission, pro-rata by
    // work performed) lives in a RewardDistributor module fed by the
    // Emission contract — kept separate so the accounting can be upgraded
    // without touching bonded principal. Stub omitted here for audit scope.
}
