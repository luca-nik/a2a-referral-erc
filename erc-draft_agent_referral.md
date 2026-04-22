---
eip: TBD
title: Agent Referral
description: A credential standard for referral fee agreements between autonomous agents, built on ERC-8001.
author: CryptoEconLab
discussions-to: TBD
status: Draft
type: Standards Track
category: ERC
created: 2026-04-15
requires: 165, 8001
---

## Abstract

This ERC defines a referral credential standard built on ERC-8001. ERC-8001 is used as the coordination substrate for proposal, countersignature, replay protection, and deterministic key derivation. For `AGENT_REFERRAL_TYPE`, successful execution of the ERC-8001 coordination issues a referral credential identified by the same `intentHash`.

A provider (P) and a referrer (R) co-sign a `ReferralTerms` structure through the ERC-8001 coordination flow. The coordination reaches `Ready` once both parties have signed. Any caller may then execute the coordination; execution issues the referral credential. The issued credential is identified by the same `intentHash` and carries its own validity window defined by `ReferralTerms.validUntil`. Anyone can verify the state of an issued credential by calling `referralInfo(intentHash)`. Either party may call `revokeReferral(intentHash, reason)` to invalidate an issued credential.

Referral fee payment is voluntary; this ERC defines only the credential format, the issuance flow, and the query and revocation interface, leaving payment mechanics to implementers and market incentives — directly following the design philosophy of [ERC-2981](https://eips.ethereum.org/EIPS/eip-2981) for NFT royalties.

## Motivation

Agents in agentic commerce have no standardized way to refer clients to one another. When R introduces a client (C) to P and P is subsequently paid for the work, P owes R a referral commission. Today there is no on-chain primitive to record such an arrangement, verify that it was made, or produce evidence that it was not honoured.

Without a standard, referral agreements exist only off-chain. Neither party can prove the terms to a third party, an indexer cannot track compliance, and a reputation system cannot distinguish providers who honour referrals from those who do not.

ERC-2981 took the same approach for NFT royalties: it defines a query interface without any enforcement mechanism, leaving compliance to market and social incentives.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Constants

```solidity
bytes32 constant AGENT_REFERRAL_TYPE = keccak256("AGENT_REFERRAL");
```

`AgentIntent` is the struct defined by [ERC-8001](https://eips.ethereum.org/EIPS/eip-8001) that the proposer signs when initiating a coordination. It contains a `coordinationType` field — a `bytes32` slot that ERC-8001 reserves explicitly for downstream ERCs to identify what kind of coordination they are registering.

`AGENT_REFERRAL_TYPE` is the value this ERC assigns to that field. The proposer MUST set `intent.coordinationType = AGENT_REFERRAL_TYPE` when calling `proposeCoordination` on a compliant contract. This serves two purposes:

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
    uint64  validUntil;   // expiry of the issued referral credential
}
```

`ReferralTerms` is ABI-encoded and placed in `CoordinationPayload.coordinationData`. All `uint16` values for `referralRate` are valid; there is no invalid range.

`ReferralTerms.validUntil` is the expiry of the **issued referral credential**. It is distinct from `AgentIntent.expiry`, which is the coordination deadline under ERC-8001 — the deadline by which the agreement must be accepted and executed. There is no required relationship between the two values; the parties may choose any `validUntil` they agree on.

```solidity
struct IssuedReferral {
    address provider;
    address referrer;
    uint16  referralRate;
    uint64  validFrom;    // block.timestamp at the time of executeCoordination
    uint64  validUntil;   // credential expiry, from ReferralTerms
    bool    revoked;
}
```

`IssuedReferral` records the state of an issued referral credential. No issued credential exists before successful execution of the underlying ERC-8001 coordination. After execution, credential validity is derived solely from `revoked`, `validFrom`, and `validUntil`.

### Interface

A compliant contract MUST implement [ERC-8001](https://eips.ethereum.org/EIPS/eip-8001) and additionally implement the referral extension defined by this ERC.

The referral extension interface is:

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;

/// @title IReferralCredential
/// @dev Referral credential extension for ERC-8001 compliant contracts.
///  The ERC-165 interfaceId for this extension is:
///  bytes4(keccak256("referralInfo(bytes32)")) ^ bytes4(keccak256("revokeReferral(bytes32,string)"))
interface IReferralCredential /* is IERC165 */ {

    /// @notice Return the referral terms and validity of an issued referral credential.
    /// @param intentHash  The 32-byte coordination identifier produced by proposeCoordination.
    /// @return provider   Address of the agent performing the work (P).
    /// @return referrer   Address of the agent who made the introduction (R).
    /// @return rate       Agreed referral fee as a fraction of type(uint16).max.
    ///                    Fee fraction = rate / 65535. All values 0–65535 are valid.
    /// @return valid      True if the credential has been issued, is not revoked,
    ///                    and validFrom <= block.timestamp < validUntil.
    /// @return validFrom  block.timestamp at the time executeCoordination was called.
    ///                    Zero if the credential has not been issued.
    /// @return validUntil Credential expiry timestamp from ReferralTerms.
    function referralInfo(bytes32 intentHash)
        external view
        returns (
            address  provider,
            address  referrer,
            uint16   rate,
            bool     valid,
            uint64   validFrom,
            uint64   validUntil
        );

    /// @notice Revoke an issued referral credential.
    /// @dev May only be called after the credential has been issued via executeCoordination.
    ///  Either provider or referrer may revoke at any time after issuance.
    ///  Revocation does not alter the ERC-8001 coordination status.
    /// @param intentHash  The referral credential to revoke.
    /// @param reason      Human-readable reason for revocation.
    function revokeReferral(bytes32 intentHash, string calldata reason) external;
}
```

### Events

```solidity
/// @notice Emitted when a referral credential is issued via executeCoordination.
event ReferralIssued(
    bytes32 indexed intentHash,
    address indexed provider,
    address indexed referrer,
    uint16  referralRate,
    uint64  validFrom,
    uint64  validUntil
);

/// @notice Emitted when a referral credential is revoked via revokeReferral.
event ReferralRevoked(
    bytes32 indexed intentHash,
    address indexed revokedBy,
    string  reason
);
```

Compliant contracts MUST emit `ReferralIssued` on successful execution and `ReferralRevoked` on successful revocation.

### Validation on `proposeCoordination`

In addition to the base ERC-8001 requirements, a compliant contract MUST revert on `proposeCoordination` if:

- `intent.coordinationType != AGENT_REFERRAL_TYPE`;
- `payload.coordinationData` does not decode to a valid `ReferralTerms`;
- `terms.provider` or `terms.referrer` is the zero address, or they are equal;
- `intent.participants` does not equal `[terms.provider, terms.referrer]` sorted ascending;
- `intent.agentId` is neither `terms.provider` nor `terms.referrer`;
- `terms.validUntil == 0`.

In this ERC, `intent.agentId` identifies whichever of the two bilateral parties is acting as proposer for the ERC-8001 proposal transaction.

These checks ensure the registered terms faithfully reflect the actual signers and that no party can forge a credential on behalf of another. No constraint is placed on the relationship between `terms.validUntil` and `intent.expiry`, nor on whether `terms.validUntil` lies in the future at proposal time.

### Execution semantics

A compliant contract MUST specialize `executeCoordination` for `AGENT_REFERRAL_TYPE`. On successful execution of a referral coordination, the contract MUST create the issued referral record, emit `ReferralIssued`, and cause the underlying ERC-8001 coordination to transition to `Executed`. If the ERC-8001 execution reverts, no referral credential is issued.

A compliant implementation MUST ensure that, upon successful execution, the committed `ReferralTerms` are used to create the `IssuedReferral` record with `validFrom = uint64(block.timestamp)`, `ReferralIssued` is emitted, and the underlying ERC-8001 coordination is transitioned to `Executed`. If execution reverts, none of these effects persist.

The `intentHash` is not created by execution — it already exists as the coordination identifier. Execution activates that identifier as an issued referral credential.

Any caller MAY call `executeCoordination` once the coordination is in `Ready` state. Execution does not change the agreed terms; it only finalizes and issues the referral credential that P and R already signed. Permissionless execution ensures liveness and prevents either party from blocking issuance after both have already consented. Execution timing is not itself part of the agreed referral terms. Parties that require tighter control over activation timing SHOULD delay acceptance rather than rely on restricting execution.

> For this ERC, execution does not represent completion of referred work. It represents finalization and issuance of the referral credential agreed by the parties.

A referral credential for a given `intentHash` can be issued at most once. Subsequent execution attempts MUST fail because the underlying ERC-8001 coordination is no longer in `Ready` state after successful execution.

### `referralInfo` semantics

`referralInfo(intentHash)` reports the state of the issued referral credential associated with `intentHash`.

- If no referral credential has been issued for `intentHash` — including when the underlying coordination is in `Proposed` or `Ready` state — all return values MUST be zero or `false`.
- If a credential has been issued:
  - `provider`, `referrer`, and `rate` are the values from the issued `IssuedReferral` record;
  - `valid` MUST be `true` if and only if the credential has been issued, has not been revoked, and `validFrom <= block.timestamp < validUntil`;
  - `validFrom` MUST equal the `block.timestamp` recorded at the time `executeCoordination` was called;
  - `validUntil` is the credential expiry recorded from `ReferralTerms`.

An `intentHash` is treated as having an issued credential if and only if its `IssuedReferral` record has `validFrom != 0`. An uninitialized record has all fields zero, so `validFrom == 0` is the reliable sentinel for "not yet issued". `valid` is not tied to the ERC-8001 coordination status. A coordination in `Proposed` or `Ready` state has no issued credential; `referralInfo` returns zero values and `false` for those states. After execution, credential validity is determined solely by revocation status and the active window `[validFrom, validUntil)`. A credential whose `validUntil` is already in the past at issuance time will immediately return `valid = false`.

### `revokeReferral` semantics

`revokeReferral(intentHash, reason)` invalidates an issued referral credential.

A compliant contract MUST revert if:

- no referral credential has been issued for `intentHash`;
- `msg.sender` is neither the stored `provider` nor the stored `referrer` of the issued credential associated with `intentHash`;
- the issued credential identified by `intentHash` is already revoked.

A compliant contract MUST:

- mark the issued credential as revoked;
- emit `ReferralRevoked`.

A compliant contract MUST NOT alter the ERC-8001 coordination status. After revocation, `referralInfo(intentHash).valid` returns `false`.

### Credential lifecycle

A referral agreement is created through the ERC-8001 coordination flow and becomes an issued referral credential only upon successful execution. Either the provider or the referrer MAY act as proposer. After all required acceptances are recorded, the coordination enters `Ready` state. Any caller MAY then execute the coordination. For `AGENT_REFERRAL_TYPE`, execution finalizes the bilateral agreement and issues a referral credential identified by `intentHash`; it does not represent completion of any referred work. The credential's validity window begins at execution time (`validFrom`) and ends at `ReferralTerms.validUntil`, unless revoked earlier.

**Creation.** Either P or R MAY act as proposer. The proposer calls `proposeCoordination`, submitting `ReferralTerms` encoded in `coordinationData` and signing the `AgentIntent`. The counterparty calls `acceptCoordination` to countersign. Once all required acceptances are present, the coordination enters `Ready` state.

**Issuance.** Any caller MAY call `executeCoordination`. Successful execution issues the referral credential for `intentHash`, recording `validFrom = block.timestamp`.

**Pre-execution cancellation.** Before execution, cancellation follows the normal ERC-8001 coordination rules without modification by this ERC.

**Post-execution revocation.** After issuance, either `provider` or `referrer` MAY call `revokeReferral(intentHash, reason)` to invalidate the credential. Revocation is a credential-layer action and does not alter the ERC-8001 coordination status, which remains `Executed`.

**Re-issuance.** A referral credential for a given `intentHash` can be issued at most once. Subsequent execution attempts MUST fail because the underlying ERC-8001 coordination is no longer in `Ready` state after successful execution. To create a new credential, the parties must create a new ERC-8001 coordination with updated or repeated `ReferralTerms`.

**Expiry — two kinds.** If the coordination is not accepted and executed before `intent.expiry`, it expires under ERC-8001 and no referral credential is issued. If the credential has been issued, it remains valid until `ReferralTerms.validUntil` unless revoked earlier.

### ERC-165 support

Contracts MAY implement [ERC-165](https://eips.ethereum.org/EIPS/eip-165) to signal support for the referral extension interface defined by this ERC. The `interfaceId` for this extension is:

```solidity
bytes4(keccak256("referralInfo(bytes32)")) ^ bytes4(keccak256("revokeReferral(bytes32,string)"))
```

ERC-165 only signals that the interface surface exists. It does not prove that the behavioral rules of this ERC are followed.

---

## Rationale

### Credential-only design

**Why no enforcement.** Any on-chain enforcement mechanism requires a specific payment interface — e.g. an ERC-20 amount to split, an ERC-8183 job ID to hook into, a particular escrow structure to intercept. Baking enforcement into this ERC would couple it to one payment ecosystem and exclude every other.

Separating the credential from enforcement means a single `referralInfo` call serves all of them. A provider running an ERC-8183 hook, a provider splitting payments manually, and a provider using a payment mechanism not yet designed all read from the same credential. Enforcement, compliance, and non-adversarial behaviour are left entirely to the application layer — to hooks, wrapper contracts, reputation systems, and economic incentives that can be built on top of this primitive without being constrained by it.

**Why public.** Publicity is not a compromise — it is what makes the credential useful as an enforcement substrate. A public credential makes non-compliance provable and attributable: R can produce the issued credential, the job completion record, and the absence of any transfer to R. Any reputation system or dispute mechanism built on top can index this evidence without needing privileged access.

**ERC-2981 precedent.** ERC-2981 for NFT royalties follows exactly this pattern: royalty terms are public, payment is voluntary, and no on-chain enforcement exists. This ERC applies the same model to agent referrals.

### ERC-8001 as the coordination layer

ERC-8001 provides exactly the primitives needed: EIP-712 typed signatures from both parties, monotonic nonces for replay prevention, and a deterministic `intentHash`. Using ERC-8001 avoids reinventing bilateral signing and gives the credential a well-defined issuance path.

This ERC defines a referral credential standard built on ERC-8001. ERC-8001 is used as the coordination substrate for proposal, countersignature, replay protection, and deterministic key derivation. For `AGENT_REFERRAL_TYPE`, successful execution of the ERC-8001 coordination issues a referral credential identified by the same `intentHash`.

### Two-phase model: coordination and credential

ERC-8001 defines the coordination lifecycle (`Proposed → Ready → Executed`). This ERC maps that lifecycle onto a two-phase model:

- **Coordination phase** (`Proposed → Ready`): The parties sign and commit to the `ReferralTerms`. The referral credential does not yet exist.
- **Issuance phase** (`Ready → Executed`): `executeCoordination` is called. The credential is issued and becomes queryable via `referralInfo`.

This separation has two important consequences. First, the credential cannot be queried before execution, preventing premature use of an agreement that was proposed but never finalised. Second, the ERC-8001 coordination transitions through its complete natural lifecycle, including `Executed`, rather than being held artificially in `Ready`.

### Permissionless execution

Restricting who may call `executeCoordination` would give either party a unilateral veto over issuance after both have already signed. Since execution does not change the agreed terms, such a veto would serve no legitimate purpose and would only introduce liveness risk. Any caller may execute once the coordination is in `Ready`.

Parties that wish to control the activation moment have a natural mechanism: the accepting party may delay its call to `acceptCoordination`. Once both parties have accepted, both have expressed unconditional consent to the terms, and issuance by any caller is consistent with that consent.

### Separate coordination and credential expiries

`AgentIntent.expiry` (the coordination deadline) and `ReferralTerms.validUntil` (the credential validity window) are independent. A short coordination window paired with a long-lived credential is entirely reasonable, as is the reverse. There is no imposed relationship between the two; the parties agree on both independently.

This ERC does not require `validUntil` to be in the future at proposal or execution time. A credential whose `validUntil` is already in the past will simply never be valid. Parties are responsible for choosing economically meaningful terms.

### `validFrom` in `referralInfo`

The credential's active window begins at execution time, not at proposal or acceptance time. Downstream consumers — particularly systems that need to determine whether a job or event occurred during the credential's active window — require both bounds. Surfacing `validFrom` directly from `referralInfo` removes the need for consumers to separately reconstruct this information from block timestamps or indexer data.

### Pre-execution cancellation follows ERC-8001

Before execution, cancellation follows the normal ERC-8001 rules without modification by this ERC. The previous version of this ERC overrode ERC-8001's proposer-only cancellation rule to allow symmetric pre-expiry cancellation by either party. That override is removed. Before issuance, the coordination has not yet become a credential; the ERC-8001 cancellation rules are appropriate for that phase.

### Post-execution revocation

After issuance, the ERC-8001 coordination is `Executed` and cannot be cancelled. This ERC defines `revokeReferral` as the post-execution invalidation mechanism for the issued credential. Either party may revoke because the referral arrangement is bilateral and either party may have a legitimate reason to exit — P may wish to stop honouring referrals from R, and R may wish to stop sending clients to a non-paying P.

Revocation is a credential-layer action. It marks the issued credential as invalid without altering the ERC-8001 coordination record, preserving the integrity of the on-chain coordination history.

### `AGENT_REFERRAL_TYPE` constant

Placing a typed label in `AgentIntent.coordinationType` — a field explicitly reserved for this purpose in ERC-8001 — allows any contract to distinguish a referral coordination from other ERC-8001 uses without parsing `coordinationData`. The constant is part of the signed data, so it cannot be altered after the fact.

### Events

ERC-8001 emits generic lifecycle events (`CoordinationProposed`, `CoordinationAccepted`, `CoordinationExecuted`). These are useful for tracking the coordination lifecycle but are too generic for referral-native indexing. `ReferralIssued` and `ReferralRevoked` make the credential layer directly discoverable to indexers, wallets, auditors, and reputation systems without requiring interpretation of ERC-8001 coordination events.

---

## Backwards Compatibility

This ERC introduces a new contract interface and does not modify any existing standard.

---

## Reference Implementation

A reference implementation (`ReferralRegistry`) inherits from the ERC-8001 reference implementation (`AgentCoordination`) and adds referral-specific logic across four functions:

**`proposeCoordination` override.** Decodes `ReferralTerms` from `coordinationData` and enforces the validation rules defined in this ERC before delegating to the ERC-8001 base. The decoded terms are stored under `intentHash` to avoid re-decoding at execution time.

**`executeCoordination` override.** Retrieves the committed `ReferralTerms`, creates an `IssuedReferral` record with `validFrom = uint64(block.timestamp)` and `validUntil` from `ReferralTerms`, emits `ReferralIssued`, and delegates to the ERC-8001 base to transition the coordination to `Executed`.

**`revokeReferral`.** Requires that an issued, non-revoked credential exists for `intentHash`. Requires `msg.sender` to be the stored `provider` or `referrer` of that issued credential. Sets `revoked = true`. Emits `ReferralRevoked`.

**`referralInfo`.** Detects issuance by checking `validFrom != 0` on the stored `IssuedReferral` record. Returns zero values if the record is uninitialized. Otherwise returns the stored terms and current validity derived from `revoked`, `validFrom`, and `validUntil`.

The ERC-8001 base handles EIP-712 domain binding, struct hashing, nonce tracking, signature verification, and the coordination state machine. None of that logic is duplicated in `ReferralRegistry`.

**Storage.** `_issuedReferrals` maps `intentHash → IssuedReferral`. The write happens inside the `executeCoordination` override in the same transaction as the ERC-8001 base state transition to `Executed`. If the base reverts, `_issuedReferrals` is never touched. `referralInfo` performs a single storage read from `_issuedReferrals` with no decoding overhead at query time.

**Required change to ERC-8001 reference.** `AgentCoordination.proposeCoordination`, `AgentCoordination.cancelCoordination`, and `AgentCoordination.executeCoordination` must be marked `virtual` for `ReferralRegistry` to override them. This is a minimal change to the base and is proposed as a suggested improvement to ERC-8001.

---

## Security Considerations

**Signature requirements.** A referral credential requires EIP-712 signatures from both P and R. Neither party can construct a valid credential unilaterally.

**Replay protection.** ERC-8001 uses an EIP-712 domain bound to `verifyingContract`. Signatures produced for one deployment cannot be replayed against a different deployment.

**No credential before execution.** The credential does not exist until `executeCoordination` succeeds. `referralInfo` returns zero values for coordinations in `Proposed` or `Ready` state. Downstream consumers MUST check `referralInfo` and MUST NOT infer credential existence from ERC-8001 coordination status alone.

**Two distinct expiries.** Coordination expiry (`intent.expiry`) and credential expiry (`ReferralTerms.validUntil`) are independent. Consumers MUST use `referralInfo(...).validUntil` for credential validity checks and MUST NOT treat coordination expiry as a proxy for credential expiry.

**Credential active window.** Consumers that need to verify whether an event occurred during the credential's active window MUST check against both `validFrom` and `validUntil` returned by `referralInfo`. Checking only `validUntil` is insufficient; a credential may have been issued after the event in question.

**Expired-at-issuance credentials.** This ERC does not require `validUntil` to be in the future at proposal or execution time. A credential whose `validUntil` is already in the past will simply never be valid. Parties are responsible for choosing economically meaningful terms.

**Revocation.** Consumers that use `referralInfo` to gate payment logic MUST check `valid`, which accounts for both expiry and revocation. Checking only `validUntil` is insufficient if the credential has been revoked.

**Active window checks.** Callers that use `referralInfo` to gate payment logic for a job or other event SHOULD verify that the relevant timestamp fell within the credential's active window `[validFrom, validUntil)`, and SHOULD NOT rely solely on whether the credential is valid at settlement time.

**Voluntary payment.** This ERC does not enforce payment. A provider can receive a job carrying a valid referral credential and choose not to honour it. The credential makes non-compliance auditable and attributable, but does not prevent it.

**Rate encoding.** `referralRate` uses the full `uint16` range: `0` = 0%, `65535` = 100%. Any issued credential is guaranteed to carry a valid rate. Downstream implementations compute the fee as `amount * referralRate / 65535`.

**Proposer identity.** The validation rules ensure `intent.agentId` matches either `terms.provider` or `terms.referrer`. Without this check, a third party could register an agreement on behalf of two agents who never interacted with the registry.

**Re-execution prevention.** A referral credential for a given `intentHash` can be issued at most once. Re-execution is prevented by the ERC-8001 lifecycle: only a coordination in `Ready` state can be executed, and a coordination transitions to `Executed` exactly once.

---

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
