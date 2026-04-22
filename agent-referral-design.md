# Agent Referral — Design

---

## 1. Problem

When referrer (R) introduces client (C) to provider (P) and P gets paid, P owes R a commission — but today
there is no on-chain primitive to record that agreement, verify it was made, or prove it
was not honoured.

---

## 2. What this ERC defines

This ERC is a **credential standard** built on ERC-8001. ERC-8001 is used as the coordination substrate for proposal, countersignature, replay protection, and deterministic key derivation. For `AGENT_REFERRAL_TYPE`, successful execution of the ERC-8001 coordination issues a referral credential identified by the same `intentHash`.

The design is directly inspired by [ERC-2981](https://eips.ethereum.org/EIPS/eip-2981), the NFT royalty standard. ERC-2981 does not enforce that marketplaces pay royalties — it only defines a standard function that anyone can call to ask: "for this token, who should be paid and how much?" Enforcement is left to market incentives. The same principle applies here. This ERC defines a standard function that anyone can call to ask: "for this referral credential, who is owed a fee and at what rate?" Whether and how the provider honours that is their own business — but the credential is on-chain, signed, and publicly auditable.

It does **not** define how the agreement is enforced. Enforcement is the provider's implementation choice. Social and economic mechanisms — for example on-chain reputation systems such as ERC-8004 — provide the natural incentive layer. The credential makes non-compliance provable, not impossible.

### The agreement format

When P and R decide to enter a referral arrangement, they need to agree on four things: who is the provider, who is the referrer, what the fee rate is, and how long the issued credential should remain valid. This ERC defines a standard structure — `ReferralTerms` — to hold exactly those fields:

```solidity
struct ReferralTerms {
    address provider;     // P — the agent doing the work
    address referrer;     // R — the agent who made the introduction
    uint16  referralRate; // agreed fee as a fraction of type(uint16).max
                          // fee fraction = referralRate / 65535; all values valid
    uint64  validUntil;   // expiry of the issued referral credential
}
```

`ReferralTerms.validUntil` is the expiry of the **issued referral credential**. It is distinct from `AgentIntent.expiry`, which is the deadline under ERC-8001 by which the coordination must be accepted and executed. There is no required relationship between the two; the parties agree on them independently.

ERC-8001's `AgentIntent` struct contains a field called `coordinationType` — a `bytes32` slot explicitly reserved for downstream ERCs to identify what kind of coordination they are registering. This ERC defines that field's value as:

```solidity
bytes32 constant AGENT_REFERRAL_TYPE = keccak256("AGENT_REFERRAL");
```

When the coordination is proposed, the proposer sets `intent.coordinationType = AGENT_REFERRAL_TYPE`. Because `coordinationType` is part of the struct that the proposer signs, its value is cryptographically committed — the proposer cannot later claim they signed something else. Any contract receiving the intent can check this field and immediately know it is a referral agreement rather than some other kind of ERC-8001 coordination.

### The coordination contract

`ReferralRegistry` is a smart contract defined by this ERC. It has three responsibilities: managing the signing process between P and R, issuing the referral credential on execution, and answering queries about issued credentials.

**Managing the signing process.** `ReferralRegistry` implements ERC-8001. The proposer (P or R) calls `proposeCoordination` to submit the terms and their signature. The other party calls `acceptCoordination` to countersign. Once both have signed, the coordination is in `Ready` state.

**Issuing the credential.** Any caller may call `executeCoordination`. Successful execution issues the referral credential for `intentHash`, recording `validFrom = block.timestamp`. Execution does not represent completion of any referred work — it represents finalization and issuance of the credential the parties already agreed to. From this point, the credential is queryable via `referralInfo`.

**Answering queries.** Once a credential is issued, anyone can call `referralInfo` to look up its terms and validity.

`ReferralRegistry` MUST verify that `terms.provider` and `terms.referrer` exactly match the two addresses in `intent.participants`, and that `intent.agentId` is one of them. This ensures neither party can register terms that do not reflect the actual signers.

The referral extension interface exposed by `ReferralRegistry` is:

```solidity
interface IReferralCredential {

    // ── Defined by this ERC ──────────────────────────────────────────────────

    // Given a referral intentHash, returns the issued credential terms and validity
    function referralInfo(bytes32 intentHash)
        external view
        returns (
            address provider,
            address referrer,
            uint16  rate,
            bool    valid,
            uint64  validFrom,
            uint64  validUntil
        );

    // Either P or R may call this to revoke an issued credential
    function revokeReferral(bytes32 intentHash, string calldata reason) external;
}
```

The EIP-712 `verifyingContract` in the signing domain is `ReferralRegistry` itself. This means P's and R's signatures are cryptographically bound to this specific contract address — the same signatures cannot be replayed against a different deployment.

### The query interface

After the credential is issued, the `intentHash` is the handle to look it up. Anyone — a wallet showing referral details to a user, a hook contract enforcing a payment split, an indexer building a reputation score, or an auditor checking whether P honoured an agreement — calls `referralInfo(intentHash)`.

`valid` is `true` if and only if the credential has been issued, has not been revoked, and `validFrom <= block.timestamp < validUntil`. `validFrom` is the unix timestamp at which the credential was issued — recorded at execution time. `validUntil` is the unix timestamp at which the credential expires — taken from `ReferralTerms`. Both bounds are surfaced directly so that consumers can determine whether any given job was created during the credential's active window. This matters for evidence: R cannot claim P failed to honour a referral if the credential was not yet active, or had already expired, when the job was created.

---

## 3. The referral credential

Once both P and R have signed and `executeCoordination` is called, a referral credential is issued. The `intentHash` — a 32-byte value — identifies it.

The issued credential:
- Cryptographically proves both parties committed to the terms (both EIP-712 signatures are inside the underlying coordination)
- Can be verified by anyone via `referralInfo`
- Is active within `[validFrom, validUntil)`, unless revoked earlier by either party via `revokeReferral`

R shares this `intentHash` with any client they introduce to P.

### Credential lifecycle

**Creation.** Either P or R may initiate the arrangement. The proposer calls `proposeCoordination` on `ReferralRegistry`, submitting the `ReferralTerms` and signing the `AgentIntent`. The other party calls `acceptCoordination` to countersign. The coordination enters `Ready` state once both signatures are recorded.

**Issuance.** Any caller may call `executeCoordination` once the coordination is in `Ready` state. Successful execution issues the referral credential, setting `validFrom = block.timestamp`. Execution timing is not itself part of the agreed referral terms. Parties that require tighter control over activation timing SHOULD delay acceptance rather than rely on restricting execution.

**Rate changes.** There is no update mechanism. To change the agreed rate, a new coordination must be created with updated `ReferralTerms`.

**Expiry — two kinds.** If the coordination is not executed before `intent.expiry`, it expires under ERC-8001 and no credential is issued. If the credential has been issued, it remains valid until `ReferralTerms.validUntil` unless revoked earlier.

**Revocation.** Either P or R may call `revokeReferral` at any time after issuance, provided the credential has not already been revoked. Calling `revokeReferral` on an already-revoked credential reverts. Revocation is permanent; a revoked credential cannot be restored. Revocation invalidates the credential (causes `valid` to return `false`) without altering the underlying ERC-8001 coordination record. P may wish to stop honouring referrals from R; R may wish to stop sending clients to a non-paying P.

**Pre-execution cancellation.** Before execution, cancellation follows the normal ERC-8001 coordination rules.

**Re-issuance.** A referral credential for a given `intentHash` can be issued at most once. To issue a new credential, the parties must create a new ERC-8001 coordination.

---

## 4. Properties

- **Cryptographically unforgeable.** The credential is backed by both parties' EIP-712 signatures via ERC-8001. Neither can deny having agreed to the terms.

- **Universally queryable.** `referralInfo(intentHash)` is a standard read call. Any tool, wallet, contract, or indexer can verify a referral arrangement without custom integration.

- **Socially enforced.** If P receives payment for a job introduced by R and does not pay R, R has irrefutable on-chain evidence: the issued credential (P committed), the job completion event (P was paid), and the absence of any transfer to R. Social and economic mechanisms — e.g. on-chain reputation systems — are the stick.

- **Implementation-agnostic.** How P accepts and honours the credential is P's own choice. Providers who honour referrals attract more business from referrers; this is the market incentive that replaces on-chain enforcement.

---

## 5. How a provider can use this (non-normative)

The standard defines the credential. What P does with it is their implementation. Three examples of increasing commitment:

**Vanilla convention.** P instructs clients to include the referral key in the ERC-8183 job description as `referral:0x<intentHash>`. P monitors completed jobs and pays R manually. Simple, no extra contracts, fully compatible with any ERC-8183 deployment.

**Hooked ERC-8183.** P deploys an ERC-8183 hook that extracts the `intentHash` from `optParams` on `fund`, calls `referralInfo` to verify the credential and read the rate, and splits the payment automatically on `complete`. C passes the key as `optParams`. Fully trustless; the split is atomic. P advertises the hook address so clients know to use it.

**Custom wrapper.** P builds a `createJobWithReferral(intentHash, ...)` entry point that wires up the split at job creation time. C makes one call. More friction to deploy but the cleanest client experience.

P advertises their mechanism in their ERC-8004 profile (e.g. metadata key `"referralEndpoint"` or `"referralInstructions"`). R reads it before introducing clients so C knows exactly how to submit the key.

---

## 6. ERC-8004 integration (optional)

Two conventions proposed by this ERC, using ERC-8004's existing `setMetadata` / `getMetadata` mechanism:

- **`"referralRate"`** — P's default referral rate, encoded as `abi.encode(uint16)`. The value is a fraction of `type(uint16).max` (65535 = 100%). Lets R discover P's rate before creating the key. *This key is not part of the ERC-8004 specification; it is proposed here as a standard convention.*

- **`tag1 = "referral"`** — for post-job feedback entries in ERC-8004's reputation registry, allowing on-chain tracking of referral behaviour over time. *Also proposed by this ERC.*

---

## 7. Suggested improvements to base ERCs (non-normative)

### 7.1 `referralCode` field in ERC-8183 `createJob`

An optional `bytes32 referralCode` parameter on `createJob`, emitted in the `JobCreated` event, would give every ERC-8183 implementation a standard place to carry the referral key. C passes it in a single call; indexers and hooks pick it up automatically with no convention parsing required. This is a small, backwards-compatible change to ERC-8183.

### 7.2 `createJobFor` in ERC-8183

Today `createJob` sets `client = msg.sender`, forcing any wrapper contract to become a proxy for all client-role actions. An explicit client address parameter would let orchestrating contracts create jobs on behalf of users without taking on the client role themselves.
