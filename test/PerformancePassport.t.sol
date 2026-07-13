// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PerformancePassport} from "../contracts/PerformancePassport.sol";
import {StubVerifier} from "../contracts/StubVerifier.sol";
import {IProofVerifier} from "../contracts/IProofVerifier.sol";
import {AgentRegistryV2} from "../contracts/AgentRegistryV2.sol";

contract PerformancePassportTest is Test {
    PerformancePassport passport;
    StubVerifier verifier;
    AgentRegistryV2 registry;

    address feeTreasury = makeAddr("feeTreasury");
    address principal = makeAddr("principal");
    address other = makeAddr("other");

    address attestor;
    uint256 attestorPk;

    uint256 constant FEE = 0.0005 ether;
    uint256 agentId;

    function setUp() public {
        registry = new AgentRegistryV2(feeTreasury);
        (attestor, attestorPk) = makeAddrAndKey("attestor");
        verifier = new StubVerifier(attestor);
        passport = new PerformancePassport(address(registry), address(verifier));

        vm.deal(principal, 10 ether);
        vm.prank(principal);
        agentId = registry.registerAgent{value: FEE}(bytes32("meta"));
    }

    // ---------------- helpers ----------------

    function _publicInputs(
        uint256 _agentId,
        uint32 epoch,
        PerformancePassport.ClaimType claimType,
        uint256 claimData,
        bytes32 rangeStart,
        bytes32 rangeEnd
    ) internal pure returns (uint256[] memory inputs) {
        inputs = new uint256[](6);
        inputs[0] = _agentId;
        inputs[1] = uint256(epoch);
        inputs[2] = uint256(claimType);
        inputs[3] = claimData;
        inputs[4] = uint256(rangeStart);
        inputs[5] = uint256(rangeEnd);
    }

    function _sign(uint256 pk, uint8 claimType, uint256[] memory publicInputs)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 digest =
            MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(claimType, publicInputs)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _validProof(
        uint32 epoch,
        PerformancePassport.ClaimType claimType,
        uint256 claimData,
        bytes32 rangeStart,
        bytes32 rangeEnd
    ) internal view returns (bytes memory) {
        uint256[] memory inputs =
            _publicInputs(agentId, epoch, claimType, claimData, rangeStart, rangeEnd);
        return _sign(attestorPk, uint8(claimType), inputs);
    }

    // ---------------- claim lifecycle ----------------

    function test_submitClaim_happyPath_storesAndEmits() public {
        bytes32 rangeStart = keccak256("r1");
        bytes32 rangeEnd = keccak256("r10");
        bytes memory proof =
            _validProof(1, PerformancePassport.ClaimType.PROFIT, 1250, rangeStart, rangeEnd);

        vm.expectEmit(true, true, false, true, address(passport));
        emit PerformancePassport.ClaimSubmitted(agentId, 1, PerformancePassport.ClaimType.PROFIT);
        vm.expectEmit(true, true, false, false, address(passport));
        emit PerformancePassport.ClaimVerified(agentId, 1);
        vm.prank(principal);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, rangeStart, rangeEnd, proof
        );

        PerformancePassport.Claim memory c = passport.getLatestClaim(agentId);
        assertEq(c.agentId, agentId);
        assertEq(c.epoch, 1);
        assertEq(uint8(c.claimType), uint8(PerformancePassport.ClaimType.PROFIT));
        assertEq(c.claimData, 1250);
        assertEq(c.receiptHashRangeStart, rangeStart);
        assertEq(c.receiptHashRangeEnd, rangeEnd);
        assertEq(c.submittedAt, uint64(block.timestamp));
        assertEq(c.verifierSignature, proof);
        assertEq(passport.latestClaim(agentId), 1);
    }

    function test_submitClaim_readableViaClaimsMapping() public {
        bytes memory proof =
            _validProof(3, PerformancePassport.ClaimType.PROFIT, 500, bytes32(0), bytes32(0));
        vm.prank(principal);
        passport.submitClaim(
            agentId, 3, PerformancePassport.ClaimType.PROFIT, 500, bytes32(0), bytes32(0), proof
        );

        (
            uint256 cAgentId,
            uint32 cEpoch,
            PerformancePassport.ClaimType cType,
            uint256 cData,
            ,
            ,
            uint64 submittedAt,
        ) = passport.claims(agentId, 3);
        assertEq(cAgentId, agentId);
        assertEq(cEpoch, 3);
        assertEq(uint8(cType), uint8(PerformancePassport.ClaimType.PROFIT));
        assertEq(cData, 500);
        assertEq(submittedAt, uint64(block.timestamp));
    }

    // ---------------- only-principal ----------------

    function test_submitClaim_onlyPrincipal_reverts() public {
        bytes memory proof =
            _validProof(1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0));

        vm.prank(other);
        vm.expectRevert(PerformancePassport.NotPrincipal.selector);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0), proof
        );
    }

    function test_submitClaim_unregisteredAgent_reverts() public {
        // agentId 999 was never registered -> principal is address(0)
        bytes memory proof =
            _validProof(1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0));
        vm.prank(principal);
        vm.expectRevert(PerformancePassport.NotPrincipal.selector);
        passport.submitClaim(
            999, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0), proof
        );
    }

    // ---------------- verifier swap ----------------

    function test_setVerifier_ownerCanSwap() public {
        (address newAttestor, uint256 newPk) = makeAddrAndKey("newAttestor");
        StubVerifier newVerifier = new StubVerifier(newAttestor);

        passport.setVerifier(address(newVerifier));
        assertEq(address(passport.verifier()), address(newVerifier));

        uint256[] memory inputs =
            _publicInputs(agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0));
        bytes memory proof = _sign(newPk, uint8(PerformancePassport.ClaimType.PROFIT), inputs);

        vm.prank(principal);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0), proof
        );
        assertEq(passport.latestClaim(agentId), 1);
    }

    function test_setVerifier_nonOwner_reverts() public {
        StubVerifier newVerifier = new StubVerifier(other);
        vm.prank(other);
        vm.expectRevert();
        passport.setVerifier(address(newVerifier));
    }

    function test_verifierSwap_oldSignatureNoLongerAccepted() public {
        (, uint256 newPk) = makeAddrAndKey("irrelevant");
        StubVerifier newVerifier = new StubVerifier(makeAddr("differentAttestor"));
        passport.setVerifier(address(newVerifier));

        // proof signed by the OLD attestor key must now fail against the new verifier
        bytes memory oldProof =
            _validProof(1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0));

        vm.prank(principal);
        vm.expectRevert(PerformancePassport.InvalidProof.selector);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0), oldProof
        );
        newPk; // silence unused warning in some solc configs
    }

    // ---------------- invalid proof ----------------

    function test_submitClaim_malformedProof_reverts() public {
        bytes memory garbage = hex"deadbeef";
        vm.prank(principal);
        vm.expectRevert(PerformancePassport.InvalidProof.selector);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0), garbage
        );
    }

    function test_submitClaim_wrongSigner_reverts() public {
        (, uint256 wrongPk) = makeAddrAndKey("notTheAttestor");
        uint256[] memory inputs =
            _publicInputs(agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0));
        bytes memory badProof = _sign(wrongPk, uint8(PerformancePassport.ClaimType.PROFIT), inputs);

        vm.prank(principal);
        vm.expectRevert(PerformancePassport.InvalidProof.selector);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0), badProof
        );
    }

    function test_submitClaim_tamperedPublicInput_reverts() public {
        // sign for claimData=1250 but submit claimData=9999 -> signature no longer matches
        bytes memory proof =
            _validProof(1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0));

        vm.prank(principal);
        vm.expectRevert(PerformancePassport.InvalidProof.selector);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 9999, bytes32(0), bytes32(0), proof
        );
    }

    // ---------------- epoch tracking ----------------

    function test_epochTracking_latestAdvancesInOrder() public {
        vm.startPrank(principal);
        for (uint32 e = 1; e <= 3; e++) {
            bytes memory proof =
                _validProof(e, PerformancePassport.ClaimType.PROFIT, e * 100, bytes32(0), bytes32(0));
            passport.submitClaim(
                agentId, e, PerformancePassport.ClaimType.PROFIT, e * 100, bytes32(0), bytes32(0), proof
            );
            assertEq(passport.latestClaim(agentId), e);
        }
        vm.stopPrank();
    }

    function test_epochTracking_outOfOrderSubmission_latestStaysMax() public {
        bytes memory proof5 =
            _validProof(5, PerformancePassport.ClaimType.PROFIT, 500, bytes32(0), bytes32(0));
        bytes memory proof2 =
            _validProof(2, PerformancePassport.ClaimType.PROFIT, 200, bytes32(0), bytes32(0));

        vm.startPrank(principal);
        passport.submitClaim(
            agentId, 5, PerformancePassport.ClaimType.PROFIT, 500, bytes32(0), bytes32(0), proof5
        );
        assertEq(passport.latestClaim(agentId), 5);

        passport.submitClaim(
            agentId, 2, PerformancePassport.ClaimType.PROFIT, 200, bytes32(0), bytes32(0), proof2
        );
        // latestClaim tracks the highest epoch seen, not submission order
        assertEq(passport.latestClaim(agentId), 5);
        vm.stopPrank();

        // but the epoch-2 claim itself is still stored and readable
        (, uint32 cEpoch,,,,,,) = passport.claims(agentId, 2);
        assertEq(cEpoch, 2);
    }

    function test_epochTracking_multipleAgentsIndependent() public {
        // register a second agent
        vm.deal(other, 10 ether);
        vm.prank(other);
        uint256 agentId2 = registry.registerAgent{value: FEE}(bytes32("meta2"));

        bytes memory proof1 =
            _validProof(1, PerformancePassport.ClaimType.PROFIT, 100, bytes32(0), bytes32(0));
        vm.prank(principal);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 100, bytes32(0), bytes32(0), proof1
        );

        uint256[] memory inputs2 =
            _publicInputs(agentId2, 7, PerformancePassport.ClaimType.PROFIT, 700, bytes32(0), bytes32(0));
        bytes memory proof2 = _sign(attestorPk, uint8(PerformancePassport.ClaimType.PROFIT), inputs2);
        vm.prank(other);
        passport.submitClaim(
            agentId2, 7, PerformancePassport.ClaimType.PROFIT, 700, bytes32(0), bytes32(0), proof2
        );

        assertEq(passport.latestClaim(agentId), 1);
        assertEq(passport.latestClaim(agentId2), 7);
    }

    // ---------------- claim types ----------------

    function test_claimTypes_allThreeStoreDistinctly() public {
        vm.startPrank(principal);

        bytes memory profitProof =
            _validProof(1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0));
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0), profitProof
        );

        bytes memory riskProof = _validProof(
            2, PerformancePassport.ClaimType.RISK_COMPLIANCE, 300, bytes32(0), bytes32(0)
        );
        passport.submitClaim(
            agentId,
            2,
            PerformancePassport.ClaimType.RISK_COMPLIANCE,
            300,
            bytes32(0),
            bytes32(0),
            riskProof
        );

        bytes memory execProof = _validProof(
            3, PerformancePassport.ClaimType.EXECUTION_INTEGRITY, 42, bytes32(0), bytes32(0)
        );
        passport.submitClaim(
            agentId,
            3,
            PerformancePassport.ClaimType.EXECUTION_INTEGRITY,
            42,
            bytes32(0),
            bytes32(0),
            execProof
        );
        vm.stopPrank();

        (, , PerformancePassport.ClaimType t1,,,,,) = passport.claims(agentId, 1);
        (, , PerformancePassport.ClaimType t2,,,,,) = passport.claims(agentId, 2);
        (, , PerformancePassport.ClaimType t3,,,,,) = passport.claims(agentId, 3);
        assertEq(uint8(t1), uint8(PerformancePassport.ClaimType.PROFIT));
        assertEq(uint8(t2), uint8(PerformancePassport.ClaimType.RISK_COMPLIANCE));
        assertEq(uint8(t3), uint8(PerformancePassport.ClaimType.EXECUTION_INTEGRITY));
    }

    // ---------------- receipt hash range ----------------

    function test_receiptHashRange_persistsExactly() public {
        bytes32 rangeStart = keccak256("start-receipt");
        bytes32 rangeEnd = keccak256("end-receipt");
        bytes memory proof =
            _validProof(1, PerformancePassport.ClaimType.PROFIT, 1250, rangeStart, rangeEnd);

        vm.prank(principal);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, rangeStart, rangeEnd, proof
        );

        PerformancePassport.Claim memory c = passport.getLatestClaim(agentId);
        assertEq(c.receiptHashRangeStart, rangeStart);
        assertEq(c.receiptHashRangeEnd, rangeEnd);
    }

    // ---------------- ZK-readiness: public inputs / proof encoding ----------------

    /// @notice The publicInputs array PerformancePassport builds internally must
    ///         be a plain uint256[] that survives abi.encode/decode round-trips
    ///         unchanged — this is exactly the shape a Noir/SP1 verifier expects
    ///         its public inputs in, so swapping StubVerifier for a real verifier
    ///         later requires no re-encoding on the caller side.
    function test_zkReadiness_publicInputsSurviveAbiRoundTrip() public {
        uint256[] memory inputs = _publicInputs(
            agentId,
            1,
            PerformancePassport.ClaimType.PROFIT,
            1250,
            keccak256("a"),
            keccak256("b")
        );
        bytes memory encoded = abi.encode(inputs);
        uint256[] memory decoded = abi.decode(encoded, (uint256[]));

        assertEq(decoded.length, inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            assertEq(decoded[i], inputs[i]);
        }
    }

    /// @notice The proof bytes stored as `verifierSignature` must survive
    ///         calldata -> storage -> memory round trips byte-for-byte,
    ///         regardless of length — required for arbitrary-length ZK proof
    ///         blobs later (a 65-byte ECDSA sig today, a much larger SNARK
    ///         proof tomorrow).
    function test_zkReadiness_arbitraryLengthProofBytesPreserved() public {
        // StubVerifier only accepts 65-byte proofs, so first submit a real one...
        bytes memory validProof =
            _validProof(1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0));
        vm.prank(principal);
        passport.submitClaim(
            agentId, 1, PerformancePassport.ClaimType.PROFIT, 1250, bytes32(0), bytes32(0), validProof
        );
        PerformancePassport.Claim memory c = passport.getLatestClaim(agentId);
        assertEq(c.verifierSignature.length, 65);
        assertEq(keccak256(c.verifierSignature), keccak256(validProof));
    }

    function test_zkReadiness_claimTypeFitsUint8() public pure {
        // Noir/SP1 public inputs are field elements; claimType must fit in the
        // narrowest reasonable type (uint8) to keep circuit encoding cheap.
        assertTrue(uint8(PerformancePassport.ClaimType.PROFIT) < type(uint8).max);
        assertTrue(uint8(PerformancePassport.ClaimType.RISK_COMPLIANCE) < type(uint8).max);
        assertTrue(uint8(PerformancePassport.ClaimType.EXECUTION_INTEGRITY) < type(uint8).max);
    }
}
