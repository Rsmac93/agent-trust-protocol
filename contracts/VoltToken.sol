// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title VOLT — VoltPass token
/// @notice Fixed 21,000,000 supply. 10% premined at genesis to vesting/treasury/
///         liquidity addresses; remaining 90% mintable ONLY by the Emission
///         contract, which enforces the halving schedule.
contract VoltToken is ERC20, ERC20Burnable, Ownable2Step {
    uint256 public constant MAX_SUPPLY = 21_000_000e18;
    uint256 public constant PREMINE = 2_100_000e18; // 10%

    /// @notice The only address allowed to mint after genesis (Emission contract).
    address public minter;
    bool public minterLocked;

    error MaxSupplyExceeded();
    error NotMinter();
    error MinterIsLocked();

    event MinterSet(address indexed minter, bool locked);

    /// @param teamVesting   vesting contract for team (5% = 1,050,000)
    /// @param treasury      treasury multisig (4% = 840,000)
    /// @param liquidity     audits + initial liquidity wallet (1% = 210,000)
    constructor(
        address teamVesting,
        address treasury,
        address liquidity
    ) ERC20("VoltPass Token", "VOLT") Ownable(msg.sender) {
        _mint(teamVesting, 1_050_000e18);
        _mint(treasury, 840_000e18);
        _mint(liquidity, 210_000e18);
        assert(totalSupply() == PREMINE);
    }

    /// @notice One-time wiring of the Emission contract, then lock forever.
    function setMinter(address _minter, bool lock) external onlyOwner {
        if (minterLocked) revert MinterIsLocked();
        minter = _minter;
        minterLocked = lock;
        emit MinterSet(_minter, lock);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (totalSupply() + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        _mint(to, amount);
    }
}
