# Agent Referral — Design

---

## 1. Problem

Agents refer clients to one another but have no standard way to represent or prove the
arrangement. When B introduces C to A and A gets paid, A owes B a commission — but today
there is no on-chain primitive to record that agreement, verify it was made, or prove it
was not honoured.

---

## 2. What this ERC defines

This ERC is a **credential standard**. It defines how two agents establish a referral
agreement on-chain and a standard interface to query that agreement.

It does **not** define how the agreement is enforced. Enforcement is the provider's
implementation choice. Social enforcement via ERC-8004 reputation is the natural
mechanism — the credential makes non-compliance provable, not impossible.

### The query interface

```solidity
interface IReferralRegistry {
    function referralInfo(bytes32 intentHash)
        external view
        returns (
            address provider,
            address referrer,
            uint16  rateBps,
            bool    valid
        );
}
```

`valid` is `true` if the coordination is in `Ready` state and has not expired or been
cancelled. Anyone — a wallet, a hook contract, an indexer, an auditor — can call this
with a referral key and immediately know whether the agreement is active and what its terms
are.

### The data format

```solidity
struct ReferralTerms {
    address provider;        // A — the agent doing the work
    address referrer;        // B — the agent who made the introduction
    uint16  referralRateBps; // agreed fee in basis points (100 = 1%; max 10 000 = 100%)
}

bytes32 constant AGENT_REFERRAL_TYPE = keccak256("AGENT_REFERRAL");
```

`CoordinationPayload.coordinationData = abi.encode(ReferralTerms)`

### The coordination contract

`ReferralCoordination` implements ERC-8001 natively. A and B call `proposeCoordination`
and `acceptCoordination` directly on it. The contract stores the `CoordinationPayload`
internally and exposes `referralInfo` as a read function. The EIP-712 `verifyingContract`
is `ReferralCoordination` itself, binding all signatures to this specific deployment.

---

## 3. The referral key

Once A proposes and B accepts, the ERC-8001 coordination reaches `Ready` state. The
`intentHash` — a 32-byte value — is the referral key.

The key:
- Cryptographically proves A committed to the rate (A's EIP-712 signature is inside)
- Proves B agreed to the arrangement (B's acceptance signature is inside)
- Can be verified by anyone via `referralInfo`
- Remains valid until A or B revokes it (`cancelCoordination`) or it expires

B shares this key with any client they introduce to A.

---

## 4. Properties

- **Cryptographically unforgeable.** The key is an ERC-8001 `intentHash` backed by A's
  EIP-712 signature. A cannot deny having agreed to the terms.

- **Universally queryable.** `referralInfo(intentHash)` is a standard read call. Any
  tool, wallet, contract, or indexer can verify a referral arrangement without custom
  integration.

- **Socially enforced.** If A receives payment for a job introduced by B and does not pay
  B, B has irrefutable on-chain evidence: the signed key (A committed), the job completion
  event (A was paid), and the absence of any transfer to B. ERC-8004 reputation is the
  stick.

- **Implementation-agnostic.** How A accepts and honours the key is A's own choice.
  Providers who honour referrals attract more business from referrers; this is the market
  incentive that replaces on-chain enforcement.

---

## 5. How a provider can use this (non-normative)

The standard defines the credential. What A does with it is their implementation. Three
examples of increasing commitment:

**Vanilla convention.** A instructs clients to include the referral key in the ERC-8183
job description as `referral:0x<intentHash>`. A monitors completed jobs and pays B
manually. Simple, no extra contracts, fully compatible with any ERC-8183 deployment.

**Hooked ERC-8183.** A deploys an ERC-8183 hook that extracts the `intentHash` from
`optParams` on `fund`, calls `referralInfo` to verify the key and read the rate, and
splits the payment automatically on `complete`. C passes the key as `optParams`. Fully
trustless; the split is atomic. A advertises the hook address so clients know to use it.

**Custom wrapper.** A builds a `createJobWithReferral(intentHash, ...)` entry point that
wires up the split at job creation time. C makes one call. More friction to deploy but
the cleanest client experience.

A advertises their mechanism in their ERC-8004 profile (e.g. metadata key
`"referralEndpoint"` or `"referralInstructions"`). B reads it before introducing clients
so C knows exactly how to submit the key.

---

## 6. ERC-8004 integration (optional)

Two conventions proposed by this ERC, using ERC-8004's existing `setMetadata` /
`getMetadata` mechanism:

- **`"referralRateBps"`** — A's default referral rate, encoded as `abi.encode(uint16)`.
  Lets B discover A's rate before creating the key. *This key is not part of the ERC-8004
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
