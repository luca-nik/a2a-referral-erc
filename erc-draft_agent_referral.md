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

This ERC defines a credential standard for referral fee agreements between autonomous agents. A provider (P) and a referrer (R) co-sign a `ReferralTerms` structure on-chain via [ERC-8001](https://eips.ethereum.org/EIPS/eip-8001), producing a 32-byte referral key (`intentHash`). Anyone can verify the terms of an active agreement by calling `referralInfo(intentHash)`, which returns the provider address, referrer address, agreed fee rate, validity status, and expiry timestamp. Referral fee payment is voluntary; this ERC defines only the credential format and query interface, leaving payment mechanics to implementers and market incentives — directly following the design philosophy of [ERC-2981](https://eips.ethereum.org/EIPS/eip-2981) for NFT royalties.

## Motivation

Agents in agentic commerce have no standardized way to refer clients to one another. When R introduces a client (C) to P and P is subsequently paid for the work, P owes R a referral commission. Today there is no on-chain primitive to record such an arrangement, verify that it was made, or produce evidence that it was not honoured.

Without a standard, referral agreements exist only off-chain. Neither party can prove the terms to a third party, an indexer cannot track compliance, and a reputation system cannot distinguish providers who honour referrals from those who do not.

ERC-2981 took the same approach for NFT royalties: it defines a query interface without any enforcement mechanism, leaving compliance to market and social incentives. This ERC applies the same model to agent referrals: the credential makes the agreement unforgeable and publicly auditable, while enforcement is left to the application layer.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Constants

```solidity
bytes32 constant AGENT_REFERRAL_TYPE = keccak256("AGENT_REFERRAL");
```

`AgentIntent` is the struct defined by [ERC-8001](https://eips.ethereum.org/EIPS/eip-8001) that the proposer signs when initiating a coordination. It contains a `coordinationType` field — a `bytes32` slot that ERC-8001 reserves explicitly for downstream ERCs to identify what kind of coordination they are registering.

`AGENT_REFERRAL_TYPE` is the value this ERC assigns to that field. The proposer MUST set `intent.coordinationType = AGENT_REFERRAL_TYPE` when calling `proposeCoordination` on `ReferralRegistry`. This serves two purposes:

- **Identification.** Any contract or indexer can inspect `coordinationType` and immediately know the coordination is a referral agreement, without parsing the opaque `coordinationData`.
- **Commitment.** Because `coordinationType` is part of the struct the proposer signs, its value is cryptographically bound to their signature. The proposer cannot later claim they signed a different kind of coordination.

### Data types

```solidity
struct ReferralTerms {
    address provider;     // P — the agent performing the work
    address referrer;     // R — the agent who made the introduction
    uint16  referralRate; // agreed fee as a fraction of type(uint16).max
                          // fee fraction = referralRate / 65535
                          // 0 = 0%, 65535 = 100%; all values are valid
}
```

`ReferralTerms` is ABI-encoded and placed in `CoordinationPayload.coordinationData`. All `uint16` values for `referralRate` are valid; there is no invalid range.

### Interface

The types `AgentIntent`, `CoordinationPayload`, `AcceptanceAttestation`, and `Status` are defined in [ERC-8001](https://eips.ethereum.org/EIPS/eip-8001) and used here as imported.

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
    /// @dev Either party (P or R) may cancel at any time before expiry.
    ///  This overrides ERC-8001's default proposer-only cancellation rule;
    ///  see the Rationale section for justification.
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
    /// @return rate       Agreed referral fee as a fraction of type(uint16).max.
    ///                    Fee fraction = rate / 65535. All values 0–65535 are valid.
    /// @return valid      True if the key is in Ready state and has not expired.
    /// @return validUntil Unix timestamp at which the key expires.
    function referralInfo(bytes32 intentHash)
        external view
        returns (
            address  provider,
            address  referrer,
            uint16   rate,
            bool     valid,
            uint64   validUntil
        );
}
```

### Validation on `proposeCoordination`

In addition to the base ERC-8001 requirements, `ReferralRegistry` MUST revert if:

- `intent.coordinationType != AGENT_REFERRAL_TYPE`;
- `payload.coordinationData` does not decode to a valid `ReferralTerms`;
- `terms.provider` or `terms.referrer` is the zero address, or they are equal;
- `intent.participants` does not equal `[terms.provider, terms.referrer]` sorted ascending — the two participants are derived from the terms fields, making any other participant count unrepresentable;
- `intent.agentId` is not equal to `terms.provider` or `terms.referrer`.

These checks ensure the registered terms faithfully reflect the actual signers and that no party can forge a credential on behalf of another.

### `referralInfo` semantics

`referralInfo(intentHash)` MUST behave as follows:

- If `intentHash` does not exist or was not registered with `coordinationType == AGENT_REFERRAL_TYPE`, all return values MUST be zero or `false`.
- `valid` MUST be `true` if and only if the coordination is in `Ready` state and `block.timestamp < validUntil`.
- `valid` MUST be `false` if the coordination is `Cancelled` or `Expired`.
- `validUntil` MUST equal `AgentIntent.expiry` as submitted at proposal time.
- `provider`, `referrer`, and `rate` MUST be decoded from the `coordinationData` committed at proposal time.

### Key lifecycle

**Creation.** Either P or R MAY act as proposer. The proposer calls `proposeCoordination`; the other party calls `acceptCoordination`. The key becomes active — `valid = true` — as soon as the coordination reaches `Ready` state. There is no activation delay.

**Active state.** The coordination MUST remain in `Ready` state for its entire active life. It MUST NOT be transitioned to `Executed`. A referral agreement is a standing arrangement used across multiple client interactions, not a one-time action.

**Cancellation.** This ERC overrides [ERC-8001](https://eips.ethereum.org/EIPS/eip-8001)'s default cancellation rule. Either P or R MUST be permitted to call `cancelCoordination` before expiry, regardless of who acted as proposer. `ReferralRegistry` MUST revert if the caller is not `terms.provider` or `terms.referrer`. After expiry, any caller MAY cancel, consistent with ERC-8001.

**Rate changes.** There is no update mechanism. To modify the agreed rate, the existing key MUST be cancelled and a new one created with updated `ReferralTerms`.

**Expiry.** After `validUntil`, `referralInfo` returns `valid = false`. A fresh key MAY be created if the arrangement continues.

### ERC-165 support

Compliant contracts SHOULD implement [ERC-165](https://eips.ethereum.org/EIPS/eip-165). The `interfaceId` for this ERC is `bytes4(keccak256("referralInfo(bytes32)"))`. A contract returning `true` for this `interfaceId` declares full compliance with this ERC, including the symmetric `cancelCoordination` rule defined in the Key lifecycle section above.

---

## Rationale

### Credential-only design

**Why no enforcement.** Any on-chain enforcement mechanism requires a specific payment interface — e.g. an ERC-20 amount to split, an ERC-8183 job ID to hook into, a particular escrow structure to intercept. Baking enforcement into this ERC would couple it to one payment ecosystem and exclude every other.

Separating the credential from enforcement means a single `referralInfo` call serves all of them. A provider running an ERC-8183 hook, a provider splitting payments manually, and a provider using a payment mechanism not yet designed all read from the same credential. Enforcement, compliance, and non-adversarial behaviour are left entirely to the application layer — to hooks, wrapper contracts, reputation systems, and economic incentives that can be built on top of this primitive without being constrained by it.

**Why public.** Publicity is not a compromise — it is what makes the credential useful as an enforcement substrate. A public credential makes non-compliance provable and attributable: R can produce the signed key, the job completion record, and the absence of any transfer to R. Any reputation system or dispute mechanism built on top can index this evidence without needing privileged access.

**ERC-2981 precedent.** ERC-2981 for NFT royalties follows exactly this pattern: royalty terms are public, payment is voluntary, and no on-chain enforcement exists. This ERC applies the same model to agent referrals.

### ERC-8001 as the coordination layer

ERC-8001 provides exactly the primitives needed: EIP-712 typed signatures from both parties, monotonic nonces for replay prevention, and a deterministic `intentHash` that serves as the referral key. Using ERC-8001 avoids reinventing bilateral signing and gives the key a well-defined lifecycle.

### Symmetric cancellation

[ERC-8001](https://eips.ethereum.org/EIPS/eip-8001) grants only the proposer the right to cancel before expiry. This ERC deliberately overrides that rule to allow either P or R to cancel at any time.

The justification is grounded in the nature of the agreement. ERC-8001 is a general multi-party coordination framework; its proposer-only cancellation rule makes sense where the proposer is the natural owner of the coordination. A referral arrangement is different: it is a bilateral agreement between equals, and either party may have a legitimate reason to exit — P may wish to stop accepting referrals from R, and R may wish to stop sending clients to a non-paying P. Tying the exit right to who happened to propose introduces friction that is irrelevant to the business relationship and creates practical problems in the adversarial case.

The implementation overhead is minimal: `ReferralRegistry` checks `msg.sender == terms.provider || msg.sender == terms.referrer` in `cancelCoordination`, using the already-stored `ReferralTerms`. This is a scoped, principled deviation from ERC-8001, limited to the cancellation check.

### `validUntil` in `referralInfo`

Surfacing the expiry timestamp directly in `referralInfo` allows any querier — wallet, hook contract, indexer, auditor — to determine whether a given job was created within the agreement's active window. Without this, a provider could dispute a referral claim by asserting the key had already expired.

### `AGENT_REFERRAL_TYPE` constant

Placing a typed label in `AgentIntent.coordinationType` — a field explicitly reserved for this purpose in ERC-8001 — allows any contract to distinguish a referral coordination from other ERC-8001 uses without parsing `coordinationData`. The constant is part of the signed data, so it cannot be altered after the fact.

---

## Backwards Compatibility

This ERC introduces a new contract interface and does not modify any existing standard.

---

## Reference Implementation

A reference implementation is provided in [`assets/contracts/ReferralRegistry.sol`](../assets/contracts/ReferralRegistry.sol).

`ReferralRegistry` inherits from the ERC-8001 reference implementation (`AgentCoordination`, [ethereum/ERCs — assets/erc-8001/contracts](https://github.com/ethereum/ERCs/tree/master/assets/erc-8001/contracts)) and adds approximately 110 lines of referral-specific logic:

- `proposeCoordination` override — decodes `ReferralTerms` from `coordinationData` and enforces the six validation rules before delegating to the base.
- `cancelCoordination` override — replaces proposer-only cancellation with a check against `terms.provider` and `terms.referrer`.
- `referralInfo` — reads `CoordinationState` and the stored `ReferralTerms` and returns the five values defined by this ERC.

The ERC-8001 base handles EIP-712 domain binding, struct hashing, nonce tracking, signature verification, and the `Proposed → Ready` state transition. None of that logic is duplicated in `ReferralRegistry`.

**Term storage.** `ReferralTerms` are decoded from `coordinationData` inside `proposeCoordination` and stored in a `mapping(bytes32 => ReferralTerms) _referralTerms` keyed by `intentHash`. The write happens in the same transaction as the base's `states[intentHash]` write, so the two mappings are always consistent: if the base reverts (bad signature, duplicate nonce, etc.) the whole transaction reverts and `_referralTerms` is never touched. `referralInfo` then performs two storage reads — one from `_referralTerms`, one from the base's `states` — with no decoding overhead at query time. The `coordinationData` bytes are not retained; only the decoded struct and the `payloadHash` commitment (stored by the base) are kept.

**Required change to ERC-8001 reference.** `AgentCoordination.proposeCoordination` and `AgentCoordination.cancelCoordination` must be marked `virtual` for `ReferralRegistry` to override them. This is a two-character change to the base and is proposed as a suggested improvement to ERC-8001 (see section 7 of the design document).

---

## Security Considerations

**Signature requirements.** A referral key requires EIP-712 signatures from both P and R. Neither party can construct a valid key unilaterally.

**Replay protection.** ERC-8001 uses an EIP-712 domain bound to `verifyingContract = ReferralRegistry`. Signatures produced for one deployment cannot be replayed against a different `ReferralRegistry` instance.

**Voluntary payment.** This ERC does not enforce payment. A provider can receive a job carrying a valid referral key and choose not to honour it. The credential makes non-compliance auditable and attributable, but does not prevent it. Parties relying on this standard for fee settlement must be aware that payment is not guaranteed on-chain.

**Stale key checks.** Callers that use `referralInfo` to gate payment logic should verify both `valid == true` and that `validUntil` was in the future at the time the job was created. Checking only `valid` at settlement time is insufficient if the key expired between job creation and completion.

**Rate encoding.** `referralRate` uses the full `uint16` range: `0` = 0%, `65535` = 100%. Any registered key is guaranteed to carry a valid rate — no cap check is possible or necessary. Downstream implementations compute the fee as `amount * referralRate / 65535`.

**Proposer identity.** The validation rules ensure `intent.agentId` matches either `terms.provider` or `terms.referrer`. Without this check, a third party could register an agreement on behalf of two agents who never interacted with `ReferralRegistry`.

---

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
