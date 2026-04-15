---
eip: TBD
title: Agent Referral
description: A way to record and retrieve referral fee agreement information between agents to enable universal referral fee support in agentic commerce.
author: CryptoEconLab
discussions-to: TBD
status: Draft
type: Standards Track
category: ERC
created: 2026-04-15
requires: 165, 8001
---

## Abstract

This ERC defines a credential standard for referral fee agreements between autonomous agents. A provider (P) and a referrer (R) co-sign a `ReferralTerms` structure on-chain via [ERC-8001](./erc-8001.md), producing a 32-byte referral key (`intentHash`). Anyone can verify the terms of an active agreement by calling `referralInfo(intentHash)`, which returns the provider address, referrer address, agreed fee rate in basis points, validity status, and expiry timestamp. Referral fee payment is voluntary; this ERC defines only the credential format and query interface, leaving payment mechanics to implementers and market incentives — directly following the design philosophy of [ERC-2981](./erc-2981.md) for NFT royalties.

## Motivation

Agents in agentic commerce have no standardized way to refer clients to one another. When R introduces a client (C) to P and P is subsequently paid for the work, P owes R a referral commission. Today there is no on-chain primitive to record such an arrangement, verify that it was made, or produce evidence that it was not honoured.

Without a standard, referral agreements exist only off-chain. Neither party can prove the terms to a third party, an indexer cannot track compliance, and a reputation system cannot distinguish providers who honour referrals from those who do not.

ERC-2981 demonstrated that defining a credential and a query interface — without any enforcement mechanism — is sufficient to create a functional standard. Marketplaces that skip NFT royalties lose creator communities; the credential makes non-compliance visible and costly. The same principle applies to agent referrals: the credential makes the agreement unforgeable and publicly auditable, while market and social mechanisms supply the enforcement.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Constants

```solidity
bytes32 constant AGENT_REFERRAL_TYPE = keccak256("AGENT_REFERRAL");
```

This value MUST be placed in `AgentIntent.coordinationType` when proposing a referral coordination on `ReferralRegistry`. Because `coordinationType` is part of the signed struct, its value is cryptographically committed at proposal time.

### Data types

```solidity
struct ReferralTerms {
    address provider;        // P — the agent performing the work
    address referrer;        // R — the agent who made the introduction
    uint16  referralRateBps; // agreed fee in basis points (0–10 000)
}
```

`referralRateBps` MUST NOT exceed `10_000` (100%). `ReferralTerms` is ABI-encoded and placed in `CoordinationPayload.coordinationData`.

### Interface

Compliant contracts MUST implement `IReferralRegistry`:

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;

/// @title IReferralRegistry
/// @dev Interface for the agent referral credential registry.
///  Inherits the coordination lifecycle from ERC-8001.
///  The ERC-165 interfaceId for the referralInfo extension is
///  bytes4(keccak256("referralInfo(bytes32)")).
interface IReferralRegistry {

    // ── Inherited from ERC-8001 ──────────────────────────────────────────────

    /// @notice Propose a new referral agreement and submit the proposer's signature.
    /// @dev See ERC-8001 for full semantics. Additional constraints defined by this
    ///  ERC apply (see Validation section below).
    function proposeCoordination(
        AgentIntent calldata intent,
        bytes calldata signature,
        CoordinationPayload calldata payload
    ) external returns (bytes32 intentHash);

    /// @notice Countersign a proposed referral agreement to activate the key.
    function acceptCoordination(
        bytes32 intentHash,
        AcceptanceAttestation calldata attestation
    ) external returns (bool allAccepted);

    /// @notice Revoke an active referral key.
    /// @dev Per ERC-8001 semantics, only the proposer may cancel before expiry.
    function cancelCoordination(bytes32 intentHash, string calldata reason) external;

    /// @notice Return the current lifecycle state of a coordination.
    function getCoordinationStatus(bytes32 intentHash)
        external view
        returns (
            Status status,
            address proposer,
            address[] memory participants,
            address[] memory acceptedBy,
            uint256 expiry
        );

    // ── Defined by this ERC ──────────────────────────────────────────────────

    /// @notice Return the referral terms and validity for a given referral key.
    /// @param intentHash  The 32-byte referral key produced by proposeCoordination.
    /// @return provider   Address of the agent performing the work (P).
    /// @return referrer   Address of the agent who made the introduction (R).
    /// @return rateBps    Agreed referral fee in basis points (0–10 000).
    /// @return valid      True if the key is in Ready state and has not expired.
    /// @return validUntil Unix timestamp at which the key expires.
    function referralInfo(bytes32 intentHash)
        external view
        returns (
            address  provider,
            address  referrer,
            uint16   rateBps,
            bool     valid,
            uint64   validUntil
        );
}
```

### Validation on `proposeCoordination`

In addition to the base ERC-8001 requirements, `ReferralRegistry` MUST revert if:

- `intent.coordinationType != AGENT_REFERRAL_TYPE`;
- `payload.coordinationData` does not decode to a valid `ReferralTerms`;
- `terms.referralRateBps > 10_000`;
- `intent.participants` does not contain exactly two addresses;
- the set `{terms.provider, terms.referrer}` does not equal the set of addresses in `intent.participants`;
- `intent.agentId` is not equal to `terms.provider` or `terms.referrer`.

These checks ensure the registered terms faithfully reflect the actual signers and that no party can forge a credential on behalf of another.

### `referralInfo` semantics

`referralInfo(intentHash)` MUST behave as follows:

- If `intentHash` does not exist or was not registered with `coordinationType == AGENT_REFERRAL_TYPE`, all return values MUST be zero or `false`.
- `valid` MUST be `true` if and only if the coordination is in `Ready` state and `block.timestamp < validUntil`.
- `valid` MUST be `false` if the coordination is `Cancelled` or `Expired`.
- `validUntil` MUST equal `AgentIntent.expiry` as submitted at proposal time.
- `provider`, `referrer`, and `rateBps` MUST equal the values from the stored `ReferralTerms`.

### Key lifecycle

**Creation.** Either P or R MAY act as proposer. The proposer calls `proposeCoordination`; the other party calls `acceptCoordination`. The key becomes active — `valid = true` — as soon as the coordination reaches `Ready` state. There is no activation delay.

**Active state.** The coordination MUST remain in `Ready` state for its entire active life. It MUST NOT be transitioned to `Executed`. A referral agreement is a standing arrangement used across multiple client interactions, not a one-time action.

**Cancellation.** Per [ERC-8001](./erc-8001.md), only the proposer may cancel before expiry. Either P or R may act as proposer, so the choice of who proposes determines who holds the unilateral cancellation right. After expiry, any caller may cancel.

**Rate changes.** There is no update mechanism. To modify the agreed rate, the existing key MUST be cancelled and a new one created with updated `ReferralTerms`.

**Expiry.** After `validUntil`, `referralInfo` returns `valid = false`. A fresh key MAY be created if the arrangement continues.

### ERC-165 support

Compliant contracts SHOULD implement [ERC-165](./eip-165.md). The `interfaceId` for the `referralInfo` extension is `bytes4(keccak256("referralInfo(bytes32)"))`.

---

## Rationale

### Credential-only design

Requiring on-chain enforcement (e.g. automatic payment splits) would couple this ERC to a specific job or payment standard, limiting its applicability. ERC-2981 proved that a credential-only standard is sufficient: the combination of an unforgeable record and social/economic pressure achieves broad compliance without mandating a payment mechanism. Providers who honour referrals attract more referral traffic; those who do not face on-chain evidence of non-compliance and potential reputation damage.

### ERC-8001 as the coordination layer

ERC-8001 provides exactly the primitives needed: EIP-712 typed signatures from both parties, monotonic nonces for replay prevention, and a deterministic `intentHash` that serves as the referral key. Using ERC-8001 avoids reinventing bilateral signing and gives the key a well-defined lifecycle.

### Proposer asymmetry

ERC-8001 grants only the proposer the right to cancel before expiry. This ERC does not override that rule, because it is not a limitation in practice: either P or R can choose to be the proposer, so the cancellation right is negotiated at setup time. Overriding ERC-8001's cancellation semantics would constitute a deliberate spec deviation and should be discussed with the community before adoption.

### `validUntil` in `referralInfo`

Surfacing the expiry timestamp directly in `referralInfo` allows any querier — wallet, hook contract, indexer, auditor — to determine whether a given job was created within the agreement's active window. Without this, a provider could dispute a referral claim by asserting the key had already expired.

### `AGENT_REFERRAL_TYPE` constant

Placing a typed label in `AgentIntent.coordinationType` — a field explicitly reserved for this purpose in ERC-8001 — allows any contract to distinguish a referral coordination from other ERC-8001 uses without parsing `coordinationData`. The constant is part of the signed data, so it cannot be altered after the fact.

---

## Backwards Compatibility

No backward compatibility issues found. This ERC introduces a new contract interface and does not modify any existing standard.

---

## Security Considerations

**Signature requirements.** A referral key requires EIP-712 signatures from both P and R. Neither party can construct a valid key unilaterally.

**Replay protection.** ERC-8001 uses an EIP-712 domain bound to `verifyingContract = ReferralRegistry`. Signatures produced for one deployment cannot be replayed against a different `ReferralRegistry` instance.

**Voluntary payment.** This ERC does not enforce payment. A provider can receive a job carrying a valid referral key and choose not to honour it. The credential makes non-compliance auditable and attributable, but does not prevent it. Parties relying on this standard for fee settlement must be aware that payment is not guaranteed on-chain.

**Stale key checks.** Callers that use `referralInfo` to gate payment logic should verify both `valid == true` and that `validUntil` was in the future at the time the job was created. Checking only `valid` at settlement time is insufficient if the key expired between job creation and completion.

**Rate bounds.** `referralRateBps` is validated to not exceed `10_000` at registration. Downstream payment implementations should re-validate this bound before computing fee amounts to guard against any future upgrade paths that might bypass registration checks.

**Proposer identity.** The validation rules ensure `intent.agentId` matches either `terms.provider` or `terms.referrer`. Without this check, a third party could register an agreement on behalf of two agents who never interacted with `ReferralRegistry`.

---

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
