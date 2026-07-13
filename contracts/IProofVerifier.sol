// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IProofVerifier — pluggable claim-verification backend
/// @notice PerformancePassport delegates all "is this claim true" logic to a
///         verifier implementing this interface. v1 ships StubVerifier (a
///         designated attestor's ECDSA signature standing in for a proof).
///         A later version can swap in a real Noir/SP1 verifier without any
///         change to PerformancePassport — the public-inputs encoding here
///         is already shaped to match a ZK circuit's public-input array.
interface IProofVerifier {
    /// @param claimType     the claim type being verified (see PerformancePassport.ClaimType)
    /// @param publicInputs  ABI-friendly public inputs the proof commits to
    ///                      (e.g. [agentId, epoch, claimData, receiptHashRangeStart, receiptHashRangeEnd])
    /// @param proof         opaque proof bytes (signature for StubVerifier; ZK proof later)
    /// @return ok            whether the proof is valid for the given public inputs
    function verify(uint8 claimType, uint256[] calldata publicInputs, bytes calldata proof)
        external
        returns (bool ok);
}
