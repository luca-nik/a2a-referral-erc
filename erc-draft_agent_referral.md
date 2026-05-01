---
eip: TBD
title: Agent Referral
description: A credential standard for referral fee agreements between autonomous agents, built on ERC-8001.
author: CryptoEconLab (@CELtd)
discussions-to: TBD
status: Draft
type: Standards Track
category: ERC
created: 2026-05-01
requires: 165, 8001
---

## Abstract

This ERC defines a referral credential standard for autonomous agents, built on ERC-8001. A provider (P) and a referrer (R) co-sign a `ReferralTerms` structure through the ERC-8001 coordination flow. Any caller may execute the coordination; execution issues the referral credential, identified by the same `intentHash` and carrying its own validity window. Anyone can verify an issued credential by calling `referralInfo(intentHash)`. Either party may revoke it via `revokeReferral(intentHash, reason)`. Referral fee payment is voluntary; this ERC defines only the credential format, the issuance flow, and the query and revocation interface — following the design philosophy of [ERC-2981](https://eips.ethereum.org/EIPS/eip-2981).

## Motivation

Agents in agentic commerce have no standardized way to refer clients to one another. When R introduces a client (C) to P and P is subsequently paid for the work, P owes R a referral commission. Today there is no on-chain primitive to record such an arrangement, verify that it was made, or produce evidence that it was not honoured.

Agent-to-agent commerce is moving from prototype to production. Standards for agent identity (ERC-8004), agent-mediated payments (x402, MPP), and job coordination (ERC-8183) are converging on the assumption that agents will discover and transact with each other autonomously. When agent R discovers a client need that agent P is better suited to serve, R has no protocol-level mechanism to capture value from the introduction: so the introduction either does not happen or happens off-chain, outside any reputation or settlement system.

Without a standard, referral agreements exist only off-chain. Neither party can prove the terms to a third party, an indexer cannot track compliance, and a reputation system cannot distinguish providers who honour referrals from those who do not.

ERC-2981 took the same approach for NFT royalties: it defines a query interface without any enforcement mechanism, leaving compliance to market and social incentives.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Lifecycle overview

A referral agreement follows the ERC-8001 coordination lifecycle. Either the provider (P) or the referrer (R) acts as proposer, calling `proposeCoordination` with `ReferralTerms` encoded in `coordinationData` and signing the `AgentIntent`. The counterparty calls `acceptCoordination` to countersign. Once all required acceptances are recorded, the coordination enters `Ready` state. Any caller may then call `executeCoordination`, which issues the referral credential for `intentHash` and transitions the coordination to `Executed`.

After issuance, the credential is queryable via `referralInfo(intentHash)`. The credential is active within the window `[validFrom, validUntil)`, where `validFrom` is the execution timestamp and `validUntil` is the expiry agreed in `ReferralTerms`. Either P or R may call `revokeReferral(intentHash, reason)` to invalidate the credential at any time after issuance. Revocation is permanent.

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
    uint64  validFrom;    // block.timestamp at successful execution (issuance time)
    uint64  validUntil;   // credential expiry, from ReferralTerms
    bool    revoked;
}
```

`IssuedReferral` records the state of an issued referral credential. An issued credential exists if and only if the underlying coordination has been successfully executed. After execution, credential validity is derived solely from `revoked`, `validFrom`, and `validUntil`.

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

    /// @notice Return the referral terms and revocation status of an issued referral credential.
    /// @param intentHash  The 32-byte coordination identifier produced by proposeCoordination.
    /// @return provider   Address of the agent performing the work (P).
    /// @return referrer   Address of the agent who made the introduction (R).
    /// @return rate       Agreed referral fee as a fraction of type(uint16).max.
    ///                    Fee fraction = rate / 65535. All values 0–65535 are valid.
    /// @return validFrom  block.timestamp at the time executeCoordination was called.
    ///                    Zero if the credential has not been issued.
    /// @return validUntil Credential expiry timestamp from ReferralTerms.
    ///                    Zero if the credential has not been issued.
    /// @return revoked    True if revokeReferral has been called on this credential.
    ///                    Consumers determine current validity by checking:
    ///                    validFrom != 0 && !revoked && validFrom <= block.timestamp < validUntil.
    function referralInfo(bytes32 intentHash)
        external view
        returns (
            address  provider,
            address  referrer,
            uint16   rate,
            uint64   validFrom,
            uint64   validUntil,
            bool     revoked
        );

    /// @notice Revoke an issued referral credential.
    /// @dev May only be called after the credential has been issued via executeCoordination.
    ///  Either provider or referrer may revoke at any time after issuance.
    ///  Revocation does not alter the ERC-8001 coordination status.
    /// @param intentHash  The referral credential to revoke.
    /// @param reason      Human-readable reason for revocation (max 256 bytes).
    function revokeReferral(bytes32 intentHash, string calldata reason) external;
}
```

### Validation on `proposeCoordination`

In addition to the base ERC-8001 requirements, a compliant contract MUST revert on `proposeCoordination` if:

- `intent.coordinationType != AGENT_REFERRAL_TYPE`;
- `payload.coordinationData` does not decode to a valid `ReferralTerms`;
- `terms.provider` or `terms.referrer` is the zero address, or they are equal;
- `intent.participants` does not equal `[terms.provider, terms.referrer]` sorted ascending;
- `intent.agentId` is neither `terms.provider` nor `terms.referrer`;
- `terms.validUntil == 0`.

In this ERC, `intent.agentId` identifies whichever of the two bilateral parties is acting as proposer for the ERC-8001 proposal transaction.

The canonical ascending ordering of `intent.participants` ensures a single hash for two distinct-but-equivalent intents and prevents proposer-controlled hash collision avoidance.

Each `intentHash` identifies a single issuance. It is not a stable identifier for the ongoing referral relationship between P and R; parties that require relationship-level tracking must perform that aggregation off-chain.

These checks ensure the registered terms faithfully reflect the actual signers and that no party can forge a credential on behalf of another. No constraint is placed on the relationship between `terms.validUntil` and `intent.expiry`, nor on whether `terms.validUntil` lies in the future at proposal time.

### Issuance via `executeCoordination`

A compliant contract MUST specialize `executeCoordination` for `AGENT_REFERRAL_TYPE`. On successful execution of a referral coordination, the contract MUST create the issued referral record, emit `ReferralIssued`, and cause the underlying ERC-8001 coordination to transition to `Executed`. If the ERC-8001 execution reverts, no referral credential is issued.

The `intentHash` is not created by execution — it already exists as the coordination identifier. Execution activates that identifier as an issued referral credential.

Any caller MAY call `executeCoordination` once the coordination is in `Ready` state. Execution does not change the agreed terms; it only finalizes and issues the referral credential that P and R already signed. Permissionless execution ensures liveness and prevents either party from blocking issuance after both have already consented. Execution timing is not itself part of the agreed referral terms. Parties that require tighter control over activation timing SHOULD delay acceptance rather than rely on restricting execution.

> For this ERC, execution does not represent completion of referred work. It represents finalization and issuance of the referral credential agreed by the parties.

A referral credential for a given `intentHash` can be issued at most once. Subsequent execution attempts MUST fail because the underlying ERC-8001 coordination is no longer in `Ready` state after successful execution. To create a new credential, the parties must create a new ERC-8001 coordination with updated or repeated `ReferralTerms`.

Before execution, cancellation follows the normal ERC-8001 coordination rules without modification by this ERC.

If the coordination is not accepted and executed before `intent.expiry`, it expires under ERC-8001 and no referral credential is issued. If the credential has been issued, it remains valid until `ReferralTerms.validUntil` unless revoked earlier.

### Query interface

`referralInfo(intentHash)` reports the state of the issued referral credential associated with `intentHash`.

- If no referral credential has been issued for `intentHash` — including when the underlying coordination is in `Proposed` or `Ready` state — all return values MUST be zero or `false`.
- If a credential has been issued:
  - `provider`, `referrer`, and `rate` are the values from the issued `IssuedReferral` record;
  - `validFrom` MUST equal the `block.timestamp` recorded at the time `executeCoordination` was called;
  - `validUntil` is the credential expiry recorded from `ReferralTerms`;
  - `revoked` MUST be `true` if and only if `revokeReferral` has been called on this credential.

An `intentHash` is treated as having an issued credential if and only if its `IssuedReferral` record has `validFrom != 0`. An uninitialized record has all fields zero, so `validFrom == 0` is the reliable sentinel for "not yet issued". Consumers determine current validity by checking `validFrom != 0 && !revoked && validFrom <= block.timestamp < validUntil`. Consumers that need to verify whether a credential was valid at a historical timestamp SHOULD also index `ReferralRevoked` events to determine whether revocation occurred before or after that timestamp.

### Revocation

`revokeReferral(intentHash, reason)` invalidates an issued referral credential.

A compliant contract MUST revert if:

- no referral credential has been issued for `intentHash`;
- `msg.sender` is neither the stored `provider` nor the stored `referrer` of the issued credential associated with `intentHash`;
- the issued credential identified by `intentHash` is already revoked;
- `bytes(reason).length > 256`.

A compliant contract MUST:

- mark the issued credential as revoked;
- emit `ReferralRevoked`.

Revocation MUST be permanent; a revoked credential cannot be restored.

A compliant contract MUST NOT alter the ERC-8001 coordination status. After revocation, the credential is no longer valid.

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

### ERC-8001 as the coordination layer

ERC-8001 provides the primitives this ERC needs: EIP-712 typed signatures from both parties, monotonic nonces for replay prevention, and a deterministic `intentHash`. Using ERC-8001 avoids reinventing bilateral signing and gives the credential a well-defined issuance path.

Contract-agent signers are supported via [ERC-1271](https://eips.ethereum.org/EIPS/eip-1271). When ERC-8001 provides ERC-1271-compatible signature verification, this support is inherited automatically by compliant contracts.

### Two-phase model: coordination and credential

ERC-8001 defines the coordination lifecycle (`Proposed → Ready → Executed`). This ERC maps that lifecycle onto a two-phase model:

- **Coordination phase** (`Proposed → Ready`): The parties sign and commit to the `ReferralTerms`. The referral credential does not yet exist.
- **Issuance phase** (`Ready → Executed`): `executeCoordination` is called. The credential is issued and becomes queryable via `referralInfo`.

The credential is a derived artifact of the coordination, not the coordination itself. The credential cannot be queried before execution, preventing premature use of an agreement that was proposed but never finalised. The ERC-8001 coordination transitions through its complete natural lifecycle, including `Executed`, rather than being held artificially in `Ready`.

### Permissionless execution

Restricting who may call `executeCoordination` would give either party a unilateral veto over issuance after both have already signed. Since execution does not change the agreed terms, such a veto would serve no legitimate purpose and would only introduce liveness risk. Any caller may execute once the coordination is in `Ready`.

Parties that wish to control the activation moment have a natural mechanism: the accepting party may delay its call to `acceptCoordination`. Once both parties have accepted, both have expressed unconditional consent to the terms, and issuance by any caller is consistent with that consent.

### Separate coordination and credential expiries

`AgentIntent.expiry` (the coordination deadline) and `ReferralTerms.validUntil` (the credential validity window) are independent. A short coordination window paired with a long-lived credential is entirely reasonable, as is the reverse. There is no imposed relationship between the two; the parties agree on both independently.

This ERC does not require `validUntil` to be in the future at proposal or execution time. A credential whose `validUntil` is already in the past will simply never be valid. Parties are responsible for choosing economically meaningful terms.

### Rate encoding

Every `uint16` value for `referralRate` is valid: `0` = 0%, `65535` = 100%. The alternative is basis points (`10000 = 100%`), which is the DeFi convention but introduces a validation requirement (`referralRate <= 10000`) and a `require` revert path in `proposeCoordination`.

Full-range encoding eliminates a class of validation errors and simplifies the implementation. Granularity is 1/65535 ≈ 0.00153%, which on a 100 ETH payment represents ≈ 0.00153 ETH — sufficient for plausible referral economics.

### No revocation cooldown

A foreseeable failure mode is: P revokes after a referred job arrives but before settlement, denying R the fee for work already performed.

A cooldown or notice period would couple credential mechanics to settlement timing. The credential-only design explicitly rejects coupling to settlement — this is the same argument used to reject built-in payment. Cooldowns are an application-layer concern: a wrapper contract, hook, or escrow can enforce one without modification to the standard. The standard ships without a cooldown for the same reason it ships without payment: keep the credential layer minimal and let composition handle policy.

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

### Enumeration

`referralInfo` is keyed by `intentHash`. There is no standard mechanism to enumerate all credentials for a given provider or referrer. Consumers that need credential discovery track `ReferralIssued` and `ReferralRevoked` events from genesis. Enumeration is an indexer concern and is deliberately excluded from the on-chain interface to minimize gas costs and contract complexity.

### Provider usage patterns

The standard defines the credential. What P does with it is P's implementation. Three examples of increasing commitment:

**Vanilla convention.** P instructs clients to include the referral key in the job description as `referral:0x<intentHash>`. P monitors completed jobs and pays R manually. Simple, no extra contracts.

**Hooked job lifecycle.** P deploys a hook that extracts the `intentHash` from job parameters on funding, calls `referralInfo` to verify the credential and read the rate, and splits the payment automatically on completion. Fully trustless; the split is atomic.

**Custom wrapper.** P builds a `createJobWithReferral(intentHash, ...)` entry point that wires up the split at job creation time. More friction to deploy but the cleanest client experience.

P may advertise their mechanism — and their default referral rate — in their agent profile (e.g. an ERC-8004 metadata key `"referralRate"` encoded as `abi.encode(uint16)`). R reads it before introducing clients so C knows exactly how to submit the key.

---

## Backwards Compatibility

This ERC introduces a new contract interface and does not modify any existing standard. The reference implementation uses an override-based composition pattern that requires `AgentCoordination.proposeCoordination`, `cancelCoordination`, and `executeCoordination` to be marked `virtual` in the ERC-8001 reference implementation. Adding `virtual` is a non-breaking change to existing ERC-8001 deployments. The authors intend to coordinate this change with the ERC-8001 maintainers.

---

## Reference Implementation

A reference implementation (`ReferralRegistry`) inherits from the ERC-8001 reference implementation (`AgentCoordination`) and adds referral-specific logic across four functions:

**`proposeCoordination` override.** Decodes `ReferralTerms` from `coordinationData` and enforces the validation rules defined in this ERC before delegating to the ERC-8001 base. The decoded terms are stored under `intentHash` to avoid re-decoding at execution time.

**`executeCoordination` override.** Retrieves the committed `ReferralTerms`, creates an `IssuedReferral` record with `validFrom = uint64(block.timestamp)` and `validUntil` from `ReferralTerms`, emits `ReferralIssued`, and invokes the ERC-8001 base implementation to transition the coordination to `Executed`.

**`revokeReferral`.** Requires that an issued, non-revoked credential exists for `intentHash`. Requires `msg.sender` to be the stored `provider` or `referrer` of that issued credential. Requires `bytes(reason).length <= 256`. Sets `revoked = true`. Emits `ReferralRevoked`.

**`referralInfo`.** Detects issuance by checking `validFrom != 0` on the stored `IssuedReferral` record. Returns zero values if the record is uninitialized. Otherwise returns the stored terms and revocation status.

The ERC-8001 base handles EIP-712 domain binding, struct hashing, nonce tracking, signature verification, and the coordination state machine. None of that logic is duplicated in `ReferralRegistry`.

**Storage.** `_issuedReferrals` maps `intentHash → IssuedReferral`. The write happens inside the `executeCoordination` override in the same transaction as the ERC-8001 base state transition to `Executed`. If the base reverts, `_issuedReferrals` is never touched. `referralInfo` performs a single storage read from `_issuedReferrals` with no decoding overhead at query time.

**Required change to ERC-8001 reference.** If ERC-8001 does not mark the three coordination functions `virtual`, an alternative composition pattern exists: a wrapper contract that observes ERC-8001 events and mirrors the coordination state in its own storage. This path is viable but introduces event-ordering assumptions, requires two transactions where the override path requires one, and gives up atomic state consistency between the coordination and credential layers. The override path is strongly preferred.

---

## Security Considerations

**Signature requirements.** A referral credential requires EIP-712 signatures from both P and R. Neither party can construct a valid credential unilaterally.

**Replay protection.** ERC-8001 uses an EIP-712 domain bound to `verifyingContract`. Signatures produced for one deployment cannot be replayed against a different deployment.

**No credential before execution.** The credential does not exist until `executeCoordination` succeeds. `referralInfo` returns zero values for coordinations in `Proposed` or `Ready` state. Downstream consumers that rely on ERC-8001 coordination status instead of calling `referralInfo` risk treating a non-existent credential as valid.

**Two distinct expiries.** Coordination expiry (`intent.expiry`) and credential expiry (`ReferralTerms.validUntil`) are independent. Using coordination expiry as a proxy for credential expiry produces incorrect results; `referralInfo(...).validUntil` is the authoritative source for credential validity.

**Credential active window.** Checking only `validUntil` without also checking `validFrom` and `revoked` leads to false positives — the credential may not have been active, or may have been revoked, at the relevant time. A credential is currently active if and only if `validFrom != 0 && !revoked && validFrom <= block.timestamp < validUntil`.

**Expired-at-issuance credentials.** This ERC does not require `validUntil` to be in the future at proposal or execution time. A credential whose `validUntil` is already in the past will simply never be valid. Parties are responsible for choosing economically meaningful terms.

**Revocation.** Checking only the active window without checking `revoked` causes a revoked credential to be honoured. A revoked credential is invalid regardless of the active window.

**Active window checks.** Relying on credential validity at settlement time, rather than at the time the relevant job or event occurred, produces incorrect results when the credential was activated or revoked between the two timestamps.

**Voluntary payment.** This ERC does not enforce payment. A provider can receive a job carrying a valid referral credential and choose not to honour it. The credential makes non-compliance auditable and attributable, but does not prevent it.

**Rate encoding.** `referralRate` uses the full `uint16` range: `0` = 0%, `65535` = 100%. Any issued credential is guaranteed to carry a valid rate. Downstream implementations compute the fee as `amount * referralRate / 65535`.

**Proposer identity.** The validation rules ensure `intent.agentId` matches either `terms.provider` or `terms.referrer`. Without this check, a third party could register an agreement on behalf of two agents who never interacted with the registry.

**Re-execution prevention.** A referral credential for a given `intentHash` can be issued at most once. Re-execution is prevented by the ERC-8001 lifecycle: only a coordination in `Ready` state can be executed, and a coordination transitions to `Executed` exactly once.

---

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
