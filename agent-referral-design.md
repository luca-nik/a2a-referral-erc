# Agent Referral — Design

---

## 1. Problem

When referrer (R) introduces client (C) to provider (P) and P gets paid, P owes R a commission — but today
there is no on-chain primitive to record that agreement, verify it was made, or prove it
was not honoured.

---

## 2. What this ERC defines

This ERC is a **credential standard**. It defines how two agents establish a referral
agreement on-chain and a standard interface to query that agreement.

The design is directly inspired by [ERC-2981](https://eips.ethereum.org/EIPS/eip-2981), the NFT royalty standard. ERC-2981 does not
enforce that marketplaces pay royalties — it only defines a standard function that anyone
can call to ask: "for this token, who should be paid and how much?" Enforcement is left to
market incentives: marketplaces that skip royalties lose access to creators and
communities. The same principle applies here. This ERC defines a standard function that
anyone can call to ask: "for this referral key, who is owed a fee and at what rate?"
Whether and how the provider honours that is their own business — but the agreement is
on-chain, signed, and publicly auditable.

It does **not** define how the agreement is enforced. Enforcement is the provider's
implementation choice. Social and economic mechanisms — for example on-chain reputation
systems such as ERC-8004 — provide the natural incentive layer. The credential makes
non-compliance provable, not impossible.

### The agreement format

When P and R decide to enter a referral arrangement, they need to agree on three things:
who is the provider, who is the referrer, and what the fee rate is. This ERC defines
a standard structure — `ReferralTerms` — to hold exactly those three fields:

```solidity
struct ReferralTerms {
    address provider;        // P — the agent doing the work
    address referrer;        // R — the agent who made the introduction
    uint16  referralRateBps; // agreed fee in basis points (100 = 1%; max 10 000 = 100%)
}
```

This structure is what P and R sign. Encoding it in a standard format means any contract
or tool that understands this ERC can read and verify the terms without custom parsing.

ERC-8001's `AgentIntent` struct contains a field called `coordinationType` — a `bytes32`
slot explicitly reserved for downstream ERCs to identify what kind of coordination they
are registering. This ERC defines that field's value as:

```solidity
bytes32 constant AGENT_REFERRAL_TYPE = keccak256("AGENT_REFERRAL");
```

When the coordination is proposed, the proposer sets `intent.coordinationType = AGENT_REFERRAL_TYPE`.
Because `coordinationType` is part of the struct that the proposer signs, its value is
cryptographically committed — the proposer cannot later claim they signed something else. Any
contract receiving the intent can check this field and immediately know it is a referral
agreement rather than some other kind of ERC-8001 coordination.

### The coordination contract

`ReferralRegistry` is a new smart contract defined by this ERC. It has two
responsibilities: managing the signing process between P and R, and answering queries
about existing agreements.

**Managing the signing process.** `ReferralRegistry` implements ERC-8001, the
multi-party coordination standard. The proposer (P or R) calls `proposeCoordination` to
submit the terms and their signature. The other party calls `acceptCoordination` to
countersign. Once both have signed, the agreement is locked on-chain and neither party
can alter it. The contract stores the full agreement terms internally so they can be
retrieved later. The proposer can call `cancelCoordination` at any time to revoke the key
(see §3 for the lifecycle implications of who proposes).

`ReferralRegistry` MUST verify that `terms.provider` and `terms.referrer` exactly match
the two addresses in `intent.participants`, and that `intent.agentId` is one of them.
This ensures neither party can register terms that do not reflect the actual signers.

**Answering queries.** Once an agreement is registered, anyone can call `referralInfo`
to look up its terms.

The full interface exposed by `ReferralRegistry` is:

```solidity
interface IReferralRegistry {

    // ── Inherited from ERC-8001 ──────────────────────────────────────────────
    // Proposer (P or R) calls this to submit the terms and their signature
    function proposeCoordination(
        AgentIntent calldata intent,
        bytes calldata signature,
        CoordinationPayload calldata payload
    ) external returns (bytes32 intentHash);

    // Acceptor calls this to countersign and lock the agreement
    function acceptCoordination(
        bytes32 intentHash,
        AcceptanceAttestation calldata attestation
    ) external returns (bool allAccepted);

    // Proposer calls this to revoke the key (see §3)
    function cancelCoordination(bytes32 intentHash, string calldata reason) external;

    // Returns the current state of an agreement (Ready, Cancelled, Expired, ...)
    function getCoordinationStatus(bytes32 intentHash)
        external view
        returns (Status status, address proposer, address[] memory participants,
                 address[] memory acceptedBy, uint256 expiry);

    // ── New — defined by this ERC ────────────────────────────────────────────
    // Given a referral key, returns the agreed terms and whether the key is still active
    function referralInfo(bytes32 intentHash)
        external view
        returns (address provider, address referrer, uint16 rateBps, bool valid, uint64 validUntil);
}
```

The EIP-712 `verifyingContract` in the signing domain is `ReferralRegistry` itself.
This means P's and R's signatures are cryptographically bound to this specific contract
address — the same signatures cannot be replayed against a different deployment.

### The query interface

After the agreement is registered, the referral key (a 32-byte hash called `intentHash`)
is the handle to look it up. Anyone — a wallet showing referral details to a user, a
hook contract enforcing a payment split, an indexer building a reputation score, or an
auditor checking whether P honoured an agreement — calls:

```solidity
interface IReferralRegistry {
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

`valid` is `false` if the agreement has expired or been cancelled. `validUntil` is the
unix timestamp at which the key expires — surfaced directly from the ERC-8001 intent so
that anyone inspecting the on-chain record can see exactly when the agreement was active.
This matters for evidence: R cannot claim P failed to honour a referral if the key had
already expired when the job was created. This single read call is the entire public
interface of this ERC — there is no write path, no token transfer, no enforcement logic.
It is purely a lookup.

---

## 3. The referral key

Once P and R have both signed, the ERC-8001 coordination reaches `Ready` state. The
`intentHash` — a 32-byte value — is the referral key.

The key:
- Cryptographically proves both parties committed to the terms (both EIP-712 signatures are inside)
- Can be verified by anyone via `referralInfo`
- Expires at `validUntil` or is revoked by the proposer via `cancelCoordination`

R shares this key with any client they introduce to P.

>  Note: The ERC-8001 coordination exposed in this standard remains in `Ready` state for its entire active life, it is never moved to `Executed`
  because a referral agreement is a standing arrangement used repeatedly, not a one-time action

### Key lifecycle

**Creation.** Either P or R may initiate the arrangement. The proposer calls
`proposeCoordination` on `ReferralRegistry`, submitting the `ReferralTerms` and signing
the `AgentIntent`. The other party calls `acceptCoordination` to countersign. The key
becomes active the moment both signatures are recorded — there is no activation delay.

**Rate changes.** There is no update mechanism. To change the agreed rate, the existing
key must be cancelled and a new one created with the updated `ReferralTerms`.

**Expiry.** The key expires at `validUntil`. Both parties should agree on an appropriate
duration when creating the key. After expiry `referralInfo` returns `valid = false`. A
fresh key can be created if the arrangement continues.

**Cancellation.** Either P or R may cancel the key at any time before expiry. This is
a deliberate override of ERC-8001's default rule, which restricts cancellation to the
proposer. The override is justified because a referral arrangement is a bilateral
agreement between equals: both parties have symmetric standing and either may have a
legitimate reason to exit. `ReferralRegistry` checks that `msg.sender` is either
`terms.provider` or `terms.referrer` — the stored `ReferralTerms` make this a trivial
check. After expiry, any caller may cancel, consistent with ERC-8001.

---

## 4. Properties

- **Cryptographically unforgeable.** The key is an ERC-8001 `intentHash` backed by both
  parties' EIP-712 signatures. Neither can deny having agreed to the terms.

- **Universally queryable.** `referralInfo(intentHash)` is a standard read call. Any
  tool, wallet, contract, or indexer can verify a referral arrangement without custom
  integration.

- **Socially enforced.** If P receives payment for a job introduced by R and does not pay
  R, R has irrefutable on-chain evidence: the signed key (P committed), the job completion
  event (P was paid), and the absence of any transfer to R. Social and economic mechanisms — e.g. on-chain reputation systems — are the
  stick.

- **Implementation-agnostic.** How P accepts and honours the key is P's own choice.
  Providers who honour referrals attract more business from referrers; this is the market
  incentive that replaces on-chain enforcement.

---

## 5. How a provider can use this (non-normative)

The standard defines the credential. What P does with it is their implementation. Three
examples of increasing commitment:

**Vanilla convention.** P instructs clients to include the referral key in the ERC-8183
job description as `referral:0x<intentHash>`. P monitors completed jobs and pays R
manually. Simple, no extra contracts, fully compatible with any ERC-8183 deployment.

**Hooked ERC-8183.** P deploys an ERC-8183 hook that extracts the `intentHash` from
`optParams` on `fund`, calls `referralInfo` to verify the key and read the rate, and
splits the payment automatically on `complete`. C passes the key as `optParams`. Fully
trustless; the split is atomic. P advertises the hook address so clients know to use it.

**Custom wrapper.** P builds a `createJobWithReferral(intentHash, ...)` entry point that
wires up the split at job creation time. C makes one call. More friction to deploy but
the cleanest client experience.

P advertises their mechanism in their ERC-8004 profile (e.g. metadata key
`"referralEndpoint"` or `"referralInstructions"`). R reads it before introducing clients
so C knows exactly how to submit the key.

---

## 6. ERC-8004 integration (optional)

Two conventions proposed by this ERC, using ERC-8004's existing `setMetadata` /
`getMetadata` mechanism:

- **`"referralRateBps"`** — P's default referral rate, encoded as `abi.encode(uint16)`.
  Lets R discover P's rate before creating the key. *This key is not part of the ERC-8004
  specification; it is proposed here as a standard convention.*

- **`tag1 = "referral"`** — for post-job feedback entries in ERC-8004's reputation
  registry, allowing on-chain tracking of referral behaviour over time. *Also proposed
  by this ERC.*

---

## 7. Suggested improvements to base ERCs (non-normative)

### 7.1 `referralCode` field in ERC-8183 `createJob`

An optional `bytes32 referralCode` parameter on `createJob`, emitted in the `JobCreated`
event, would give every ERC-8183 implementation a standard place to carry the referral
key. C passes it in a single call; indexers and hooks pick it up automatically with no
convention parsing required. This is a small, backwards-compatible change to ERC-8183.

### 7.2 `createJobFor` in ERC-8183

Today `createJob` sets `client = msg.sender`, forcing any wrapper contract to become a
proxy for all client-role actions. An explicit client address parameter would let
orchestrating contracts create jobs on behalf of users without taking on the client role
themselves.
