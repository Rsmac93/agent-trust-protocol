// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IProofVerifier} from "./IProofVerifier.sol";

/// @title StubVerifier — v1 stand-in for a ZK proof verifier
/// @notice A single designated `attestor` address signs
///         keccak256(claimType, publicInputs) off-chain; `verify()` checks
///         that signature. This is a deliberate, disclosed centralization
///         point for v1 — it lets PerformancePassport ship before the Noir
///         circuits exist. Swap this contract out for a real verifier later
///         via PerformancePassport.setVerifier(); the interface (and the
///         public-inputs encoding) does not change.
contract StubVerifier is Ownable2Step, IProofVerifier {
    /// @notice off-chain signer standing in for a ZK proof
    address public attestor;

    event AttestorUpdated(address indexed attestor);

    constructor(address _attestor) Ownable(msg.sender) {
        attestor = _attestor;
        emit AttestorUpdated(_attestor);
    }

    function setAttestor(address _attestor) external onlyOwner {
        attestor = _attestor;
        emit AttestorUpdated(_attestor);
    }

    /// @dev proof = 65-byte ECDSA signature over
    ///      MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(claimType, publicInputs)))
    function verify(uint8 claimType, uint256[] calldata publicInputs, bytes calldata proof)
        external
        view
        override
        returns (bool)
    {
        if (proof.length != 65) return false;
        bytes32 digest =
            MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(claimType, publicInputs)));
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, proof);
        if (err != ECDSA.RecoverError.NoError) return false;
        return recovered == attestor;
    }
}
