// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TeamVesting — 4-year linear vesting, 1-year cliff
/// @notice Holds the 5% team allocation (1,050,000 VOLT). Nothing claimable
///         before the cliff; then linear release until month 48.
contract TeamVesting {
    IERC20 public immutable token;
    address public immutable beneficiary;
    uint256 public immutable start;
    uint256 public constant CLIFF = 365 days;
    uint256 public constant DURATION = 1461 days; // 4 years

    uint256 public released;

    event Released(uint256 amount);

    constructor(IERC20 _token, address _beneficiary) {
        token = _token;
        beneficiary = _beneficiary;
        start = block.timestamp;
    }

    function vestedAmount() public view returns (uint256) {
        uint256 total = token.balanceOf(address(this)) + released;
        if (block.timestamp < start + CLIFF) return 0;
        if (block.timestamp >= start + DURATION) return total;
        return (total * (block.timestamp - start)) / DURATION;
    }

    function release() external {
        uint256 amount = vestedAmount() - released;
        require(amount > 0, "nothing vested");
        released += amount;
        token.transfer(beneficiary, amount);
        emit Released(amount);
    }
}
