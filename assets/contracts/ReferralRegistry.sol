// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.26;

// ---------------------------------------------------------------------------
// Imports from the ERC-8001 reference implementation.
// Source: ethereum/ERCs — assets/erc-8001/contracts/AgentCoordination.sol
//   https://github.com/ethereum/ERCs/tree/master/assets/erc-8001/contracts
// In a real project these would be pulled from a package (e.g. npm/foundry).
// For standalone use, copy AgentCoordination.sol, IAgentCoordination.sol,
// interfaces/IERC1271.sol, and utils/ECDSA.sol alongside this file.
// ---------------------------------------------------------------------------
import {AgentCoordination} from "./AgentCoordination.sol";
import {IAgentCoordination, Status} from "./IAgentCoordination.sol";

// ---------------------------------------------------------------------------
// NOTE ON BASE CONTRACT VIRTUALITY
// AgentCoordination.proposeCoordination and AgentCoordination.cancelCoordination
// must be marked `virtual` for this contract to compile. That is a one-word
// change to the ERC-8001 reference implementation and is the recommended path
// for any ERC-8001 extension that needs to specialize either function.
// ---------------------------------------------------------------------------

/// @title IReferralRegistry
/// @notice Read-only interface for the referral credential query function.
/// @dev ERC-165 interfaceId: bytes4(keccak256("referralInfo(bytes32)"))
interface IReferralRegistry {
    /// @notice Return the referral terms and validity for a given referral key.
    /// @param intentHash  The 32-byte referral key produced by proposeCoordination.
    /// @return provider   Address of the agent performing the work (P).
    /// @return referrer   Address of the agent who made the introduction (R).
    /// @return rate       Agreed referral fee as a fraction of type(uint16).max.
    ///                    Fee fraction = rate / 65535. All values 0–65535 are valid.
    /// @return valid      True if the key is in Ready state and has not expired.
    /// @return validUntil Unix timestamp at which the key expires (== AgentIntent.expiry).
    function referralInfo(bytes32 intentHash)
        external
        view
        returns (
            address provider,
            address referrer,
            uint16  rate,
            bool    valid,
            uint64  validUntil
        );
}

/// @title ReferralRegistry
/// @notice On-chain credential registry for bilateral agent referral agreements.
///         Inherits the full ERC-8001 coordination lifecycle and adds:
///           1. Referral-specific validation on proposeCoordination.
///           2. Symmetric cancellation — either party (P or R) may cancel.
///           3. The referralInfo query function.
/// @dev Reference implementation for the Agent Referral ERC.
///      Requires AgentCoordination.proposeCoordination and
///      AgentCoordination.cancelCoordination to be marked `virtual`.
contract ReferralRegistry is AgentCoordination, IReferralRegistry {

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice The coordinationType value that identifies a referral coordination.
    /// @dev Set in AgentIntent.coordinationType when calling proposeCoordination.
    ///      Because coordinationType is part of the signed struct, it is
    ///      cryptographically committed and cannot be changed after signing.
    bytes32 public constant AGENT_REFERRAL_TYPE = keccak256("AGENT_REFERRAL");

    /// @notice ERC-165 interfaceId for the referralInfo extension.
    bytes4 public constant REFERRAL_INFO_INTERFACE_ID =
        bytes4(keccak256("referralInfo(bytes32)"));

    // =========================================================================
    // Data types
    // =========================================================================

    /// @notice The agreed terms between provider and referrer.
    /// @dev ABI-encoded and placed in CoordinationPayload.coordinationData.
    struct ReferralTerms {
        address provider;     // P — the agent performing the work
        address referrer;     // R — the agent who made the introduction
        uint16  referralRate; // agreed fee as a fraction of type(uint16).max
                              // rate fraction = referralRate / 65535
                              // 0 = 0%, 65535 = 100%; all values are valid
    }

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev intentHash → decoded ReferralTerms, populated on proposeCoordination.
    mapping(bytes32 => ReferralTerms) private _referralTerms;

    // =========================================================================
    // ERC-165
    // =========================================================================

    /// @notice Returns true for the referralInfo interfaceId.
    /// @dev Returning true here declares full compliance with the Agent Referral
    ///      ERC, including the symmetric cancellation rule.
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == REFERRAL_INFO_INTERFACE_ID;
    }

    // =========================================================================
    // proposeCoordination — adds referral-specific validation
    // =========================================================================

    /// @inheritdoc IAgentCoordination
    /// @dev In addition to ERC-8001 base checks, reverts if:
    ///      - coordinationType != AGENT_REFERRAL_TYPE
    ///      - coordinationData does not decode to valid ReferralTerms
    ///      - provider or referrer is the zero address, or they are equal
    ///      - intent.participants != sort([terms.provider, terms.referrer])
    ///      - agentId is not terms.provider or terms.referrer
    function proposeCoordination(
        AgentIntent calldata intent,
        bytes calldata signature,
        CoordinationPayload calldata payload
    ) external override returns (bytes32 intentHash) {
        // ── Referral-specific checks ─────────────────────────────────────────

        require(
            intent.coordinationType == AGENT_REFERRAL_TYPE,
            "ReferralRegistry: not a referral coordination"
        );

        // Decode terms — reverts with ABI decode panic if data is malformed.
        ReferralTerms memory terms = abi.decode(payload.coordinationData, (ReferralTerms));

        require(terms.provider != address(0), "ReferralRegistry: zero provider");
        require(terms.referrer != address(0), "ReferralRegistry: zero referrer");
        require(terms.provider != terms.referrer, "ReferralRegistry: provider == referrer");

        // Derive the expected participants from the terms (sorted ascending,
        // as required by ERC-8001). The "exactly 2 participants" constraint
        // is implicit: there are exactly two parties in ReferralTerms.
        (address lo, address hi) = terms.provider < terms.referrer
            ? (terms.provider, terms.referrer)
            : (terms.referrer, terms.provider);
        require(
            intent.participants.length == 2 &&
            intent.participants[0] == lo &&
            intent.participants[1] == hi,
            "ReferralRegistry: participants must equal {provider, referrer} sorted ascending"
        );

        require(
            intent.agentId == terms.provider || intent.agentId == terms.referrer,
            "ReferralRegistry: proposer is not a party to the agreement"
        );

        // ── Delegate to ERC-8001 base ─────────────────────────────────────────
        // Base handles EIP-712 signature verification, nonce, state initialisation,
        // and the CoordinationProposed event.
        intentHash = super.proposeCoordination(intent, signature, payload);

        // ── Store terms ───────────────────────────────────────────────────────
        _referralTerms[intentHash] = terms;
    }

    // =========================================================================
    // cancelCoordination — symmetric: either P or R may cancel
    // =========================================================================

    /// @inheritdoc IAgentCoordination
    /// @dev Overrides ERC-8001's proposer-only cancellation rule. Either the
    ///      provider (P) or the referrer (R) may cancel before expiry, because
    ///      a referral agreement is a bilateral arrangement between equals and
    ///      either party may have a legitimate reason to exit. After expiry any
    ///      caller may cancel, consistent with ERC-8001.
    function cancelCoordination(
        bytes32 intentHash,
        string calldata reason
    ) external override {
        CoordinationState storage st = states[intentHash];

        require(st.proposer != address(0), "ReferralRegistry: unknown intent");
        require(st.status < Status.Executed, "ReferralRegistry: already executed");

        ReferralTerms memory terms = _referralTerms[intentHash];
        bool isParty = msg.sender == terms.provider || msg.sender == terms.referrer;

        require(
            isParty || block.timestamp > st.expiry,
            "ReferralRegistry: caller is not a party to this agreement"
        );

        Status finalStatus = block.timestamp > st.expiry ? Status.Expired : Status.Cancelled;
        st.status = finalStatus;

        emit CoordinationCancelled(intentHash, msg.sender, reason, uint8(finalStatus));
    }

    // =========================================================================
    // referralInfo — the public query function defined by this ERC
    // =========================================================================

    /// @inheritdoc IReferralRegistry
    function referralInfo(bytes32 intentHash)
        external
        view
        override
        returns (
            address provider,
            address referrer,
            uint16  rate,
            bool    valid,
            uint64  validUntil
        )
    {
        CoordinationState storage st = states[intentHash];

        // Return zero values for unknown or non-referral intentHashes.
        if (st.proposer == address(0)) {
            return (address(0), address(0), 0, false, 0);
        }

        ReferralTerms memory terms = _referralTerms[intentHash];

        provider   = terms.provider;
        referrer   = terms.referrer;
        rate       = terms.referralRate;
        validUntil = st.expiry;
        valid      = (st.status == Status.Ready) && (block.timestamp < st.expiry);
    }
}
