// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AGTToken} from "./AGTToken.sol";

/// @title Emission — halving drip for AGT
/// @notice Emits the 18,900,000 AGT network allocation over daily epochs.
///         Era = 1,461 epochs (~4 years). Daily emission halves each era.
///         Era 1: 9,450,000 / 1,461 ≈ 6,468.17 AGT per day.
///         Split: 60% validators, 30% delegators (both via StakingPool),
///                10% builder incentives (BuilderPool).
contract Emission {
    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant EPOCHS_PER_ERA = 1461; // ~4 years
    uint256 public constant ERA1_TOTAL = 9_450_000e18; // half of 18.9M

    uint256 public constant VALIDATOR_BPS = 6000;
    uint256 public constant DELEGATOR_BPS = 3000;
    uint256 public constant BUILDER_BPS = 1000;

    AGTToken public immutable token;
    address public immutable stakingPool;
    address public immutable builderPool;
    uint256 public immutable genesis;

    /// @notice number of epochs already minted
    uint256 public epochsMinted;

    event EpochsMinted(uint256 fromEpoch, uint256 toEpoch, uint256 amount);

    error NothingToMint();

    constructor(AGTToken _token, address _stakingPool, address _builderPool) {
        token = _token;
        stakingPool = _stakingPool;
        builderPool = _builderPool;
        genesis = block.timestamp;
    }

    /// @notice Emission for a single epoch, given its index (0-based).
    function emissionForEpoch(uint256 epochIndex) public pure returns (uint256) {
        uint256 era = epochIndex / EPOCHS_PER_ERA; // 0-based era
        if (era >= 64) return 0;
        uint256 eraTotal = ERA1_TOTAL >> era; // halve each era
        return eraTotal / EPOCHS_PER_ERA;
    }

    /// @notice Current epoch index based on wall time.
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / EPOCH_LENGTH;
    }

    /// @notice Permissionless: anyone can crank the drip. Mints all elapsed,
    ///         unminted epochs and routes 90/10 to staking and builder pools.
    ///         (The 90% staking share is split 60/30 validator/delegator
    ///         inside the StakingPool.)
    function mintPending() external {
        uint256 nowEpoch = currentEpoch();
        uint256 from = epochsMinted;
        if (nowEpoch <= from) revert NothingToMint();

        uint256 total;
        // cap loop to avoid gas blowups after long gaps
        uint256 to = nowEpoch > from + 365 ? from + 365 : nowEpoch;
        for (uint256 i = from; i < to; i++) {
            total += emissionForEpoch(i);
        }
        epochsMinted = to;

        if (total > 0) {
            uint256 builderShare = (total * BUILDER_BPS) / 10_000;
            uint256 stakingShare = total - builderShare; // 90%
            token.mint(stakingPool, stakingShare);
            token.mint(builderPool, builderShare);
        }
        emit EpochsMinted(from, to, total);
    }
}
