# Agent Referral — Design (referral-key model)

---

## 1. Problem

Agents in the open agent economy increasingly refer clients to one another. Imagine agent A
offers a data-analysis service. Agent B, while helping a client with a different task,
recognises that the client needs exactly what A offers and refers them. A benefits from the
new business. But today there is no automatic, enforceable way for A to pay B a commission
for that introduction — either a third party has to hold the money, or A just promises to
pay later. Neither is trustless.

Three specific gaps exist:

- Referrer (B) lacks a trustless guarantee that provider (A) will share revenue.
- Provider (A) cannot prove a claimed referral was real.
- Reputation systems have no standard on-chain record of referral behaviour.

**Goal:** a mechanism where A and B agree on a referral rate once, producing a reusable
on-chain credential. Any client B introduces can present that credential to create a job
where the payment split is automatic and trustless — without B needing to be involved at
job creation time.

---

## 2. Core idea

A and B agree on a referral rate and co-sign it on-chain. The result is a 32-byte
`intentHash` — a referral key. B gives this key to clients they introduce. When a client
creates a job using the key, the split is configured automatically: on completion, the
escrow pays a split contract that distributes the provider share to A and the referral fee
to B in the same transaction. The key can be used for any number of client introductions
until it expires or A revokes it.

This ERC's core primitive is the `createJobWithReferral` function: the entry point a client
calls to create a properly configured job from a referral key.

---

## 3. Scope

This ERC standardises a **single-hop, single-job referral** between two agents (A: provider,
B: referrer) for one client (C), enforced by existing primitives only. The referral
arrangement is established once between A and B using ERC-8001 multi-party coordination;
the resulting key is reusable across many client introductions. The payout enforcement uses
ERC-8183 with a split contract set as the recorded provider. It is token-agnostic (any
ERC-20 supported by the underlying ERC-8183 instance).

Multi-job bundles, multi-level referral chains, and per-job rate negotiation are
intentionally deferred.

---

## 4. Roles and components

### 4.1 Roles

| Role | Label | Description |
|------|-------|-------------|
| Provider | A | Performs the job; receives the job price minus the referral commission |
| Referrer | B | Introduced the client to the provider; receives the referral fee |
| Client | C | Hires the provider; pays the full job price into escrow |
| Evaluator | E | Attests whether the job was completed or should be rejected; specified by C at job creation; may be C themselves |

### 4.2 Components

Four smart contracts are involved. Three are existing standards used unmodified; two are
new and defined by this ERC.

**Existing standards (used unmodified):**

- **ERC-8001** — the multi-party coordination standard. Provides EIP-712 typed data,
  per-agent nonces, expiry, and signature verification for multi-party agreements.
  `ReferralCoordination` implements this standard natively: A and B call
  `proposeCoordination` and `acceptCoordination` on it to co-sign the referral arrangement.
  The resulting `intentHash` is the referral key.

- **ERC-8183** — the job escrow standard. Manages the job lifecycle (Open → Funded →
  Submitted → Terminal), holds C's payment, and releases it on completion or refunds it on
  rejection. Supports an optional hook contract called before and after each lifecycle
  action, and explicit `client` and `provider` roles enforced by `msg.sender` checks.

- **ERC-8004** — the agent identity and reputation standard. Used optionally for payment
  address resolution (B's `agentWallet`) and post-job reputation signals.

**New contracts (defined by this ERC):**

- **ReferralCoordination** — serves two roles. First, it is the ERC-8001 coordination
  contract: A and B call `proposeCoordination` and `acceptCoordination` on it directly to
  establish their referral arrangement, and it stores the signed terms internally. Second,
  it exposes `createJobWithReferral` for clients and acts as the ERC-8183 proxy client
  because ERC-8183's `createJob` sets `client = msg.sender` (see §7.1).

- **ReferralHook** — serves two roles. It is set as both `job.provider` and `job.hook` in
  ERC-8183. As provider, it proxies `setBudget` and `submit` for A. As hook, it enforces
  referral terms and handles the payment split: on completion the escrow releases the full
  budget to `ReferralHook`, which distributes the provider share to A and the referral fee
  to B in the same transaction. No pre-approval or locked funds from A are required.

---

## 5. Data structures

### The referral key

A and B co-sign a referral arrangement using ERC-8001 multi-party coordination. The
referral-specific terms are encoded as:

```solidity
struct ReferralTerms {
    address provider;        // A — the agent doing the work
    address referrer;        // B — the agent who made the introduction
    address hook;            // the ReferralHook contract both parties trust
    uint16  referralRateBps; // referral fee in basis points (100 = 1%; max 10 000 = 100%)
}

bytes32 constant AGENT_REFERRAL_TYPE = keccak256("AGENT_REFERRAL");
```

`CoordinationPayload.coordinationData = abi.encode(ReferralTerms)`

There is no `client` or `evaluator` in these terms — those are specified per job by C at
job creation time.

**The key** is the `intentHash` produced by the ERC-8001 coordination: a 32-byte value
that cryptographically commits to the terms both parties signed. B shares this value with
clients they introduce.

### ERC-8001 usage

ERC-8001 is the multi-party coordination standard. It provides EIP-712 typed data,
per-agent nonces, expiry, and signature verification. This ERC uses the following
ERC-8001 fields:

- `verifyingContract = ReferralCoordination` — the EIP-712 domain binding. Signatures are
  bound to the specific `ReferralCoordination` deployment; they cannot be replayed against
  a different contract.
- `coordinationType = AGENT_REFERRAL_TYPE` — namespaces this coordination type so
  implementations can recognise and route referral arrangements.
- `coordinationData` — opaque bytes in ERC-8001; this ERC defines its contents as
  `abi.encode(ReferralTerms)`.
- `participants = [A, B]` sorted ascending — only two parties. C is not a participant.

`ReferralCoordination` implements ERC-8001 natively: A and B call `proposeCoordination`
and `acceptCoordination` directly on it. The contract stores the `CoordinationPayload`
internally so that `createJobWithReferral` can read the terms later without an external
call. The coordination reaches `Ready` state once both have signed and stays there
indefinitely — `executeCoordination` is never called. This is intentional: the key is
reusable across multiple client introductions.

**Revocation:** A or B may call `cancelCoordination(intentHash)` at any time. This marks
the key as `Cancelled`; new jobs cannot be created with it, but existing jobs in progress
are unaffected — their referral config is already stored in `ReferralHook`.

**Expiry:** The `AgentIntent.expiry` field in ERC-8001 sets a deadline on the key. After
expiry, `createJobWithReferral` reverts. A and B must create a new coordination to renew.

---

## 6. High-level flow

### Walkthrough

A and B agree on a referral rate off-chain, then formalise it by co-signing a coordination
on `ReferralCoordination`. This produces a referral key — a 32-byte hash — that B can give
to any client they introduce to A. No money moves and no client is involved at this stage.

When C, a client B introduced, wants to hire A, they call `createJobWithReferral` on
`ReferralCoordination` with the key. The contract verifies the key is valid, reads the
agreed terms, and creates an ERC-8183 job where `ReferralHook` is the recorded provider.
C is notified that the job is open; A is notified via an on-chain event. A proposes a
price by calling `setBudget` through `ReferralHook`. C approves the price by calling
`fund` through `ReferralCoordination`. Only C's payment moves at this point — A has
nothing to lock up.

A does the work and calls `submit` through `ReferralHook`. The evaluator — chosen by C at
job creation and which may be C themselves — reviews and decides:

- **Approved:** the escrow releases the full job price to `ReferralHook`, which immediately
  pays A the provider share and B the referral fee in the same transaction.
- **Rejected:** the escrow refunds C through `ReferralCoordination`, which forwards the
  payment to C. A has no locked funds to recover.
- **Expired:** anyone calls `claimRefund` directly on ERC-8183. The escrow returns funds to
  `ReferralCoordination`, which forwards them to C. A has nothing to reclaim.

### Step-by-step

1. **(Optional)** A advertises their default referral rate in their ERC-8004 agent profile
   using the metadata key `"referralRateBps"` (proposed by this ERC; see §7.2).

2. A proposes an ERC-8001 coordination on `ReferralCoordination` with
   `coordinationType = AGENT_REFERRAL_TYPE`, participants `[A, B]` sorted ascending,
   and `coordinationData = abi.encode(ReferralTerms)`. `ReferralCoordination` stores the
   payload and emits `CoordinationProposed`.

3. B calls `acceptCoordination` on `ReferralCoordination`. The coordination reaches `Ready`
   state. The `intentHash` is the referral key. B may now share it with clients.

4. C calls `ReferralCoordination.createJobWithReferral(intentHash, evaluator, expiredAt,
   description)`:
   - RC checks the coordination status is `Ready` and not expired.
   - RC reads the stored `ReferralTerms` for this `intentHash`.
   - RC calls `ESC.createJob(provider=terms.hook, evaluator, expiredAt, description,
     hook=terms.hook)`. Because ERC-8183's `createJob` sets `client = msg.sender`,
     `ReferralCoordination` becomes the ERC-8183 client (see §7.1).
   - RC calls `ReferralHook.configureJob(jobId, terms)` to register the referral
     parameters for this job.
   - RC emits `ReferralJobCreated(intentHash, jobId, client=C, provider=A, referrer=B)`
     so A learns about the new job.

5. While the job is **Open**, A calls `ReferralHook.setBudget(jobId, amount)` to propose a
   price. `ReferralHook` validates `msg.sender == referralConfig[jobId].provider` (i.e. A)
   and calls `ESC.setBudget` as the recorded ERC-8183 provider. The hook SHOULD emit an
   event with the computed `referralAmount = amount * rateBps / 10_000` so both parties
   know the exact split at the current price. Price negotiation may take multiple rounds.

6. C calls `ReferralCoordination.fund(jobId, expectedBudget)`:
   - RC validates `msg.sender == C` (the original caller of `createJobWithReferral`).
   - `ReferralHook`'s `beforeAction(fund)` reverts if no referral config is stored for
     this job, keeping it Open.
   - ERC-8183 pulls `job.budget` from C (via RC) into escrow. Only C's tokens move.
   - The job is now Funded; `setBudget` is no longer callable and the config is frozen.

7. A calls `ReferralHook.submit(jobId, deliverable)`. RH validates
   `msg.sender == referralConfig[jobId].provider` and calls `ESC.submit` as the recorded
   provider. The evaluator reviews and decides:
   - **Complete:** ESC transfers the full `job.budget` to `ReferralHook` (as provider).
     `ReferralHook`'s `afterAction(complete)` distributes: `providerAmount` to A and
     `referralAmount` to B (using B's `agentWallet` from ERC-8004 if set).
   - **Reject:** ESC refunds `job.budget` to `ReferralCoordination` (as client).
     RC forwards the refund to C. A has no locked funds.
   - **Expiry:** `claimRefund` on ERC-8183 (non-hookable, called directly by anyone)
     returns `job.budget` to RC. RC forwards to C.

### Payment split

```
referralAmount  = (total × rateBps) / 10_000   // B's fee; truncated
providerAmount  = total − referralAmount        // A's net receipt
job.budget      = total                         // C's full payment into escrow
```

**Worked example:** C agrees to pay 1 000 USDC; `referralRateBps = 500` (5%).
`referralAmount = 50 USDC`. `providerAmount = 950 USDC`.
C deposits 1 000 USDC into escrow. On completion: escrow releases 1 000 USDC to
`ReferralHook`; RH pays 950 USDC to A and 50 USDC to B atomically. On rejection: escrow
returns 1 000 USDC to RC; RC forwards to C. A's tokens were never locked.

---

## 7. Components in detail

### 7.1 ReferralCoordination (new)

`ReferralCoordination` is the central contract of this ERC. It has three responsibilities.

**As the ERC-8001 coordination contract:** A and B call `proposeCoordination` and
`acceptCoordination` directly on `ReferralCoordination`. It implements ERC-8001 natively —
verifying EIP-712 signatures, enforcing nonces and expiry, managing coordination status,
and emitting the required events. Critically, it stores the `CoordinationPayload` for each
intent so that `createJobWithReferral` can read the terms without an external call. The
EIP-712 `verifyingContract` is `ReferralCoordination` itself, so all signatures are bound
to this specific deployment.

**As the job factory:** `createJobWithReferral(intentHash, evaluator, expiredAt,
description)` is the primitive this ERC defines. It verifies the key, reads the stored
terms, creates the ERC-8183 job, configures `ReferralHook`, and emits `ReferralJobCreated`.
The coordination stays in `Ready` state after job creation — it is never executed — so the
same key can be used for multiple client introductions.

**As the ERC-8183 proxy client:** because `createJob` in ERC-8183 sets `client =
msg.sender`, `ReferralCoordination` becomes the recorded client for every job it creates.
C cannot interact with the job directly; instead, RC exposes `fund` and `reject` that
validate `msg.sender` is the original C before forwarding to ERC-8183. When the escrow
sends a refund to RC (on rejection or expiry), RC forwards those tokens to C. `setBudget`
is provider-only in ERC-8183 and is handled by `ReferralHook` on A's behalf.

Note: `claimRefund` in ERC-8183 is permissionless and non-hookable. Anyone may call it
directly on ERC-8183 after expiry; the refund goes to RC, which then forwards to C.

**Per-job storage in RC:** `jobConfig[jobId] = { client: C, intentHash }` so RC can
validate client identity and look up the original key for each job.

### 7.2 ReferralHook (new)

`ReferralHook` is a shared singleton that is set as both `job.provider` and `job.hook` for
every referral job. This dual role is what makes the payment split trustless: the escrow
sends the full budget to `ReferralHook` on completion (because it is the recorded
provider), and `ReferralHook` distributes it in the same transaction (because it is the
hook and has custody).

**Per-job storage:** `referralConfig[jobId] = { provider, referrer, rateBps }`  
Registered by `ReferralCoordination` via `configureJob(jobId, terms)` immediately after
`createJob`. Only `ReferralCoordination` may call `configureJob`.

**Provider proxy functions (called by A):**

- `setBudget(jobId, amount)` — validates `msg.sender == referralConfig[jobId].provider`,
  calls `ESC.setBudget` as the recorded ERC-8183 provider. SHOULD emit a `ReferralAmount`
  event so A and C know the exact split at the current price. May be called multiple times
  during price negotiation.

- `submit(jobId, deliverable)` — validates `msg.sender == referralConfig[jobId].provider`,
  calls `ESC.submit` as the recorded ERC-8183 provider.

**Hook callbacks:**

- `beforeAction(fund)` — lightweight guard. Reverts if `referralConfig[jobId]` has not
  been registered (i.e. the job was not created through `ReferralCoordination`). Prevents
  funding a misconfigured job.

- `afterAction(complete)` — the core distribution step. At this point the escrow has
  already transferred `job.budget` to `ReferralHook`. This callback computes
  `referralAmount` and `providerAmount`, pays `providerAmount` to A and `referralAmount`
  to B. Resolves B's address via ERC-8004 `agentWallet` if set.

All other callbacks are no-ops. On rejection or expiry, `ReferralHook` holds no funds.

### 7.3 ERC-8183 — job escrow

Used unmodified. The job is created with `provider = ReferralHook` and `hook =
ReferralHook`. The standard lifecycle applies: Open → Funded → Submitted → Terminal.
`claimRefund` is non-hookable by design in ERC-8183, which is why it can be called
directly without going through `ReferralCoordination`.

### 7.4 ERC-8004 — identity and reputation

Used optionally in two ways:

- **Payment routing:** when `afterAction(complete)` pays B, it resolves B's `agentWallet`
  from ERC-8004 if set; otherwise uses B's address directly.
- **Discovery:** A may advertise their default referral rate using metadata key
  `"referralRateBps"` encoded as `abi.encode(uint16)`. **This key is proposed by this ERC**
  and is not part of the ERC-8004 specification today.
- **Reputation:** after a job, either party may post feedback with `tag1 = "referral"` to
  build an on-chain referral reputation record. **This tag is also proposed by this ERC.**

---

## 8. What this ERC defines

| Item | Description |
|------|-------------|
| `AGENT_REFERRAL_TYPE` | Coordination type: `keccak256("AGENT_REFERRAL")` |
| `ReferralTerms` | Struct encoding the standing referral arrangement (see §5) |
| `createJobWithReferral` | The core primitive: referral-keyed job creation entry point |
| `IReferralCoordination` | Interface for the ERC-8001 coordinator, job factory, and ERC-8183 proxy client |
| `IReferralHook` | Interface for the provider proxy and payment split logic |
| `"referralRateBps"` | Proposed ERC-8004 metadata key; value encoded as `abi.encode(uint16)` |
| `tag1 = "referral"` | Proposed ERC-8004 feedback tag for referral reputation signals |

---

## 9. Payments and approvals

- **C (client)** grants one allowance: to `ReferralCoordination` for `total`. C does not
  approve the escrow directly — RC is the recorded ERC-8183 client and the escrow pulls
  from RC, which in turn pulls from C.

- **A (provider)** grants no token allowance at any point. The split is handled entirely
  on the output side: the escrow pays `ReferralHook` on completion, and `ReferralHook`
  distributes from there.

- C interacts with `ReferralCoordination` for `fund` and `reject`. Direct calls to
  ERC-8183 for those functions revert because RC is the recorded client.

- A interacts with `ReferralHook` for `setBudget` and `submit`. Direct calls to ERC-8183
  for those functions revert because RH is the recorded provider.

---

## 10. Failure cases and liveness

- **`setBudget` never called** — `beforeAction(fund)` reverts; the job stays Open.
  Remedy: A calls `RH.setBudget(jobId, amount)`.

- **C's allowance missing** — RC cannot pull `total` from C; `fund` reverts. Remedy: C
  approves `total` to RC, then retries.

- **Key expired** — `createJobWithReferral` reverts. A and B must create a new
  coordination with a new expiry.

- **Key cancelled** — `createJobWithReferral` reverts. A and B must create a new
  coordination if they still want to work together.

- **Expiry after funding** — Anyone calls `claimRefund` directly on ERC-8183. ESC refunds
  RC; RC forwards to C. A has no locked funds.

- **Rejection** — Evaluator calls `reject`. ESC refunds RC; RC forwards to C. A has no
  locked funds.

- **B's payment address reverts on receive** — `afterAction(complete)` reverts, rolling
  back the entire `complete` transaction including the escrow state change. The job remains
  Submitted; the evaluator may retry. B should use a standard EOA or a well-behaved
  `agentWallet`.

- **Key reuse after job creation** — A may cancel the key after a job is already in
  progress. Cancellation only blocks future job creation; the in-progress job's config is
  already stored in RH and is unaffected.

---

## 11. Constraints

- **One job per `createJobWithReferral` call.** Each call creates one ERC-8183 job. The
  key may be used for many calls.
- **Evaluator chosen by C.** The evaluator is specified by C at job creation. A does not
  pre-approve the evaluator; A's protection is economic (they can refuse to submit if they
  distrust the evaluator).
- **Rate fixed in the key.** A and C negotiate the job price via `setBudget`, but the
  referral rate is fixed when A and B created the key. A cannot change the rate per-job.
- **Hook consented by A and B.** The `ReferralHook` address is in `ReferralTerms` and
  signed by both A and B. C trusts it implicitly by using the key.

---

## 12. Suggested improvements to base ERCs (non-normative)

This ERC works within the constraints of existing standards. Two changes to ERC-8183 would
eliminate both proxy contracts entirely, reducing the design to a pure ERC-8001 credential
plus a native split:

### 12.1 `createJobFor(address client, ...)` in ERC-8183

Today `createJob` sets `client = msg.sender`, forcing any orchestrating contract to become
a proxy for all client-role actions. A `createJobFor` variant accepting an explicit client
address would let `ReferralCoordination` create the job while recording C as the client
directly. C would then interact with ERC-8183 without any intermediary, and the extra
token hop (C → RC → escrow) would disappear.

### 12.2 Native payment split on `complete` in ERC-8183

Today `complete` sends the full budget to `job.provider`. This ERC works around it by
setting `job.provider = ReferralHook` so the split can happen inside the hook. But this
forces A to interact with the escrow indirectly (through RH) for both `setBudget` and
`submit`. A native `payees` declaration at job creation — for example
`PayeeShare[] payees` with address and basis-point weight per entry — would let A be
recorded as `job.provider` directly while the split is declared upfront and executed by
the escrow on `complete`. RH would shrink to a pure policy hook with no token custody.

### 12.3 Combined effect

With both improvements: C is recorded as client and interacts directly; A is recorded as
provider and interacts directly. `ReferralCoordination` becomes a pure credential verifier
and job factory (no proxy functions, no token handling). `ReferralHook` becomes a pure
policy hook (term verification only). The proxy layer disappears entirely. This gain would
apply to any protocol layered on ERC-8183, not just referrals.

### 12.4 Standardise `referralRateBps` and `tag1="referral"` in ERC-8004

Formalising these conventions in ERC-8004 would make referral-rate discovery and
reputation filtering composable across all ERC-8004 consumers.
