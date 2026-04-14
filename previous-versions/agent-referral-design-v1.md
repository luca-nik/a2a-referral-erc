# Agent Referral — Design (single‑job v1)

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

**Goal:** a single job where the referral fee split is agreed upfront by all parties,
enforced automatically by smart contracts, and publicly auditable.

---

## 2. Scope

This v1 standardises a **single-hop, single-job referral** between two agents (A: provider,
B: referrer) for one client (C), enforced by existing primitives only — no new token or
custom escrow. The on-chain proof of agreement is an ERC-8001 coordination signed by the
economic parties (A, B, C), and the payout enforcement rides on ERC-8183 with a dedicated
contract that serves as both the job's provider and hook, handling the payment split on
completion. It is token-agnostic (any ERC-20 supported by the underlying ERC-8183 instance)
and uses a single evaluator (E) named in the terms, but E does not sign the coordination.

Multi-job bundles, multi-level chains, and split payouts inside core ERC-8183 are
intentionally deferred to keep the first version simple and auditable.

---

## 3. Roles and components

### 3.1 Roles

There are four roles. Three of them (A, B, C) are economic parties who all sign the
agreement before any money moves. The fourth (E) is named in the agreement but does not
sign it — their role begins only once the job is running.

| Role | Label | Description |
|------|-------|-------------|
| Provider | A | Performs the job; receives payment minus their referral commission |
| Referrer | B | Introduced the client to the provider; receives the referral fee |
| Client | C | Hires the provider; pays the full job price into escrow |
| Evaluator | E | Attests whether the job was completed or should be rejected; may be C or a neutral third party |

The evaluator role is important: payment only flows when E says the job is complete. If E
says it failed, everyone is refunded. This separates the judgement of "was the work good
enough?" from the financial parties who have obvious incentives.

### 3.2 Components at a glance

Five smart contracts are involved. Three are existing standards used unmodified; two are
new and defined by this ERC.

**Existing standards (used unmodified):**

- **ERC-8001** — the multi-party coordination standard. Provides the on-chain agreement
  that A, B, and C all sign before any job is created. Think of it as a countersigned
  contract: once all signatures are collected, the terms are locked and anyone can submit
  them to trigger job creation.

- **ERC-8183** — the job escrow standard. Manages the job lifecycle (Open → Funded →
  Submitted → Terminal), holds C's payment, and releases it on completion or refunds it on
  rejection. It also provides an optional hook mechanism and explicit provider and client
  roles that this ERC builds on.

- **ERC-8004** — the agent identity and reputation standard. Used optionally: A can
  advertise their referral rate in their on-chain profile, and both parties can record
  referral reputation feedback after the job.

**New contracts (defined by this ERC):**

- **ReferralCoordination** — the orchestrator. It verifies all three signatures from
  ERC-8001 and creates the ERC-8183 job. Because ERC-8183's `createJob` sets `client =
  msg.sender`, `ReferralCoordination` — not C — becomes the recorded ERC-8183 client. This
  means C cannot interact with the job directly; instead, `ReferralCoordination` exposes
  `fund` and `reject` functions that validate C's identity and then forward the call to
  ERC-8183 on C's behalf. It also handles the token flow: when C calls `fund`,
  `ReferralCoordination` pulls C's tokens to itself first, then the escrow pulls from
  `ReferralCoordination`. This means **C approves `ReferralCoordination`**, not the escrow
  directly.

- **ReferralHook** — the provider proxy and split contract. It is set as both `job.provider`
  and `job.hook` at creation. As the ERC-8183 provider, it proxies `setBudget` and `submit`
  calls from A, validating A's identity before forwarding them to the escrow. As the
  ERC-8183 hook, it enforces referral terms and handles the payment split: on completion the
  escrow releases the full budget to `ReferralHook`, which then atomically pays the provider
  share to A and the referral fee to B. No separate vault or pre-approval from A is
  required.

---

## 4. Data structures

### What gets signed

All three economic parties (A, B, C) sign a single on-chain agreement before the job
starts. This agreement is formatted as an ERC-8001 coordination — a standard way for
multiple agents to co-sign a shared intent using cryptographic signatures, with replay
protection built in.

The referral-specific terms are embedded in that coordination as a `ReferralTerms` struct:

```solidity
struct ReferralTerms {
    address provider;        // A — the agent doing the work
    address referrer;        // B — the agent who made the introduction
    address client;          // C — the agent paying for the work
    address evaluator;       // E — who decides if the job succeeded
    address hook;            // the ReferralHook contract all parties trust
    uint16  referralRateBps; // referral fee as basis points (100 bps = 1%; max 10 000 = 100%)
}

bytes32 constant AGENT_REFERRAL_V1_TYPE = keccak256("AGENT_REFERRAL_V1");
```

`CoordinationPayload.coordinationData = abi.encode(ReferralTerms)`

**Reading the fields:** `referralRateBps` expresses the fee as basis points — a standard
financial convention where 10 000 = 100%. So a 5% referral fee is 500 bps. The `hook`
field is the address of the ReferralHook smart contract; all parties must agree on this
address in the signed terms, which means C explicitly consents to the hook being the
recorded ERC-8183 provider and handling the split. The `evaluator` is named here rather
than left open, so everyone knows upfront who will judge the job.

`ReferralCoordination` MUST verify that `terms.provider`, `terms.referrer`, and
`terms.client` are exactly the three addresses in `intent.participants`. Any of the three
may be the proposer (`intent.agentId`); the referrer is always identified by `terms.referrer`
regardless of who initiates the coordination. B's consent is proven by their acceptance
signature as a named participant, not by being the proposer.

---

## 5. High-level flow (single job)

### Walkthrough

B has introduced a client to A. All three — A (provider), B (referrer), and C (client) —
agree off-chain on the referral rate and who will evaluate the job. They then each sign a
shared on-chain agreement that records exactly who gets what and who will judge the outcome.
No money moves at this stage; the signatures are simply proof that everyone consented to the
same terms.

Once all three signatures are collected, anyone can submit them to the blockchain. This
creates the job in an open state with `ReferralHook` recorded as the ERC-8183 provider. A
and C negotiate the final price: A calls `setBudget` through `ReferralHook`, which validates
A's identity and forwards the call to the escrow. When they agree, C approves the full job
price to `ReferralCoordination` and calls `fund` through it. In a single transaction, the
escrow pulls C's payment. No money from A is required at this stage.

A does the work and calls `submit` through `ReferralHook`. The evaluator — agreed upfront,
and which could be C themselves or a neutral third party — reviews the submission and decides:

- **Approved:** the escrow releases the full job price to `ReferralHook`, which immediately
  pays A the provider share and B the referral fee. A's net is the job price minus the
  commission they agreed upfront.
- **Rejected:** the escrow refunds C through `ReferralCoordination`, which forwards the
  payment to C. No separate action is needed for A.
- **Expired:** if no decision is made in time, anyone can call `claimRefund` directly on
  ERC-8183. The escrow returns the funds to `ReferralCoordination`, which forwards them to
  C. A has no locked funds to recover.

### Step-by-step

1. **(Optional)** A advertises their default referral rate in their ERC-8004 agent profile
   using the metadata key `"referralRateBps"` — a new convention proposed by this ERC
   (see §6.2).
2. Any of A, B, or C proposes an ERC-8001 coordination with `coordinationType =
   AGENT_REFERRAL_V1_TYPE` and the encoded `ReferralTerms` as payload. Participants are
   {A, B, C} sorted ascending by address (required by ERC-8001 for canonical ordering).
   The proposer sets `intent.agentId` to their own address; the referrer is identified
   by `terms.referrer`, not by who proposes.
3. A and C sign acceptances (ERC-8001). B already signed the intent at propose time. All
   three signatures are now on-chain or available off-chain for submission.
4. Anyone calls `ReferralCoordination.executeCoordination(...)`, which verifies all
   signatures and checks that `terms.provider`, `terms.referrer`, and `terms.client` match
   the participants list exactly, then calls `createJob` on ERC-8183 with
   `provider = terms.hook` (i.e. `ReferralHook`), `evaluator = E`, `hook = terms.hook`.
   Because ERC-8183's `createJob` sets `client = msg.sender`, **`ReferralCoordination`
   becomes the ERC-8183 client** and acts as a proxy for C from this point (see §6.4).
   RC then calls `ReferralHook.configureJob(jobId, terms)` to register the referral
   terms for this job. The mapping `intentHash → jobId` is also stored.
5. While the job is **Open**, A calls `ReferralHook.setBudget(jobId, amount)` to propose
   or adjust the price. `ReferralHook` validates `msg.sender == terms.provider` (i.e. A),
   then calls `ESC.setBudget(jobId, amount, optParams)` as the recorded ERC-8183 provider.
   The hook's `beforeAction(setBudget)` validates the call, cross-checks `optParams`
   against the stored referral config, and stores the per-job referral configuration. The
   config may be overwritten by subsequent calls during price negotiation. The hook SHOULD
   emit an event with the computed `referralAmount` so A and C know the exact split at the
   current price.
6. C calls `fund(jobId, expectedBudget)` through `ReferralCoordination`. In the same
   transaction:
   - The hook's `beforeAction(fund)` reverts if no referral config is stored (i.e. no
     valid `setBudget` was ever called), keeping the job Open.
   - ERC-8183 pulls `job.budget` (= `total`) from C (via `ReferralCoordination`) into
     escrow. Only C's tokens move at this point.
   - Once `fund` succeeds the job is Funded; `setBudget` is no longer callable and the
     referral config is frozen.
7. A calls `ReferralHook.submit(jobId, deliverable)`. `ReferralHook` validates
   `msg.sender == terms.provider`, then calls `ESC.submit(jobId, deliverable)` as the
   recorded ERC-8183 provider. The evaluator reviews and decides:
   - **Complete:** ESC releases `total` to `ReferralHook` (the recorded provider). In the
     same transaction, `ReferralHook`'s `afterAction(complete)` distributes: `providerAmount`
     to A and `referralAmount` to B (using B's `agentWallet` from ERC-8004 if set).
   - **Reject:** ESC refunds `total` to `ReferralCoordination` (the recorded client).
     `ReferralCoordination` forwards the refund to C. A has no locked funds to recover.
   - **Expiry:** `claimRefund` on ERC-8183 (non-hookable; called directly by anyone) refunds
     `total` to `ReferralCoordination`. `ReferralCoordination` forwards the refund to C.

### Payment split

```
referralAmount  = (total × rateBps) / 10_000   // B's referral fee; truncated
providerAmount  = total − referralAmount        // A's net receipt on completion
job.budget      = total                         // C's full payment into escrow
```

**Worked example:** C agrees to pay 1 000 USDC for a job; `referralRateBps = 500` (5%).
`referralAmount = 50 USDC`. `providerAmount = 950 USDC`.
C pays 1 000 USDC to escrow. On completion: escrow releases 1 000 USDC to `ReferralHook`;
`ReferralHook` pays 950 USDC to A and 50 USDC to B in the same transaction.
On rejection: escrow returns 1 000 USDC to `ReferralCoordination`; RC forwards 1 000 USDC
to C. A's tokens were never locked anywhere.

---

## 6. Components

This ERC introduces two new smart contracts (`ReferralCoordination` and `ReferralHook`)
and uses three existing ones unmodified. Here is how they relate:

- **ERC-8001** handles the multi-party signature and agreement phase (off-chain signing,
  on-chain verification).
- **ERC-8183** handles the job lifecycle and the main escrow (C's payment).
- **ERC-8004** provides agent identity and the optional reputation record.
- **ReferralCoordination** is the bridge: it verifies the signed agreement, creates the
  ERC-8183 job, and acts as a proxy so C can interact with the job through it.
- **ReferralHook** is the enforcement mechanism: it proxies provider actions for A, and
  on completion receives the full payment from the escrow and splits it between A and B.

### 6.1 ERC-8001 — coordination

ERC-8001 is a standard for multi-party coordination: one party proposes a typed,
cryptographically signed intent; the others each sign an acceptance; once all acceptances
are present the intent becomes executable by anyone. It provides replay protection (via
per-agent nonces and expiry) and wallet compatibility (via EIP-712 typed data, readable
by standard wallets).

This ERC uses ERC-8001 without any modification. ERC-8001 is designed with explicit
extension points — `coordinationType` and `coordinationData` — that downstream ERCs fill
in with their own values. Here is how this ERC uses each field:

- `verifyingContract = ReferralCoordination` — an existing EIP-712 domain field, standard
  in every ERC-8001 deployment. **This ERC defines `ReferralCoordination` as the contract
  that plays this role.** Binding signatures to a specific contract address means they
  cannot be replayed against a different deployment.
- `coordinationType = AGENT_REFERRAL_V1_TYPE` — an existing field in ERC-8001's
  `AgentIntent` struct, explicitly intended for domain-specific namespacing. **This ERC
  defines the value** `keccak256("AGENT_REFERRAL_V1")` so implementations can recognise
  and route referral coordinations.
- `coordinationData` — an existing `bytes` field in ERC-8001's `CoordinationPayload`,
  intentionally opaque to the core standard. **This ERC defines its contents** as
  `abi.encode(ReferralTerms)`.
- `intent.agentId` — an existing field in ERC-8001's `AgentIntent`. No new meaning; the
  referrer is identified by `terms.referrer`, not inferred from who proposes.

### 6.2 ERC-8004 — identity & reputation

ERC-8004 is the agent identity and reputation standard. Each agent has an on-chain profile
(an NFT with a metadata file) and can accumulate feedback from clients.

This ERC uses ERC-8004 in two ways:

- **Discovery:** A may advertise their default referral rate using the on-chain metadata key
  `"referralRateBps"`, encoded as `abi.encode(uint16)`. This lets B query A's rate before
  proposing a coordination. **This key is new and proposed by this ERC — it is not part of
  the ERC-8004 specification today.** ERC-8004 already provides the `setMetadata` /
  `getMetadata` mechanism; this ERC simply names a standard key to use within it.
- **Reputation:** After a job, either party may post feedback using `tag1 = "referral"` to
  build an on-chain record of referral behaviour. **This tag value is also new and proposed
  by this ERC**, using ERC-8004's existing feedback mechanism.
- **Payment routing:** ERC-8004 allows an agent to set an `agentWallet` — a separate
  payment address distinct from the owner address. When the hook pays B on completion, it
  resolves B's `agentWallet` from ERC-8004 if one is set; otherwise it pays B's registered
  address directly.

### 6.3 ERC-8183 — job escrow

ERC-8183 is the agentic commerce standard: a job escrow with four states (Open → Funded →
Submitted → Terminal), where a client locks funds, a provider submits work, and an
evaluator attests the outcome. Payment flows automatically on completion; the client is
refunded on rejection or expiry.

This ERC uses ERC-8183 **unmodified**. The job is created with `provider = ReferralHook`
and `hook = ReferralHook` — the same contract serves both roles. The standard lifecycle is:
`createJob` → Open → `setBudget` (called by ReferralHook as provider) → `fund` → Funded →
`submit` (called by ReferralHook as provider) → Submitted → `complete` / `reject`.
`claimRefund` is deliberately non-hookable in ERC-8183 and can be called directly by anyone
after expiry.

### 6.4 ReferralCoordination (new)

`ReferralCoordination` serves two roles:

**As an ERC-8001 executor:** it implements the `executeCoordination` entry point, verifies
all three signatures, checks that `terms.provider`, `terms.referrer`, and `terms.client`
match the participant set exactly, and ensures single execution. Any of the three may be the
proposer. It then calls `createJob` on ERC-8183 with `provider = terms.hook`,
`evaluator = terms.evaluator`, `hook = terms.hook`, and stores the `intentHash → jobId`
mapping. It also calls `ReferralHook.configureJob(jobId, terms)` to register the referral
parameters for that job.

**As a proxy client for ERC-8183:** because ERC-8183's `createJob` sets `client =
msg.sender`, `ReferralCoordination` becomes the ERC-8183 client for every job it creates.
To allow C to exercise client-role functions, the contract exposes proxied versions of
`fund` and `reject` that check `msg.sender == terms.client` before forwarding the call to
ERC-8183. `setBudget` is provider-only in ERC-8183 and is handled by `ReferralHook` on
A's behalf. When the escrow sends a refund to `ReferralCoordination` (on rejection or
expiry), `ReferralCoordination` MUST forward those tokens to `terms.client` (C).

Note: `claimRefund` is permissionless in ERC-8183, so anyone can trigger a refund after
expiry by calling it directly on ERC-8183. The refund goes to `ReferralCoordination` as
the recorded client; RC then forwards it to C.

### 6.5 ReferralHook (new)

`ReferralHook` is a shared singleton smart contract that serves a dual role: it is set as
both `job.provider` and `job.hook` for every referral job. This dual role is what makes
the payment split possible without any pre-approval from A: the escrow sends the full
budget to `ReferralHook` as provider on completion, and `ReferralHook` distributes it in
the same transaction.

**Per-job storage:** `referralConfig[jobId] = { provider, referrer, rateBps }`  
Registered by `ReferralCoordination` via `configureJob(jobId, terms)` immediately after
job creation. Only `ReferralCoordination` may call `configureJob`.

**Provider proxy functions (called by A):**

- `setBudget(jobId, amount)` — validates `msg.sender == referralConfig[jobId].provider`
  (i.e. A), then calls `ESC.setBudget(jobId, amount, optParams)` as the recorded ERC-8183
  provider. During the ERC-8183 call the hook's `beforeAction(setBudget)` is triggered,
  which validates the config. May be called multiple times during price negotiation.

- `submit(jobId, deliverable)` — validates `msg.sender == referralConfig[jobId].provider`,
  then calls `ESC.submit(jobId, deliverable)` as the recorded ERC-8183 provider.

**Hook callbacks and their purpose:**

- `beforeAction(fund)` — a lightweight guard: MUST revert if `referralConfig[jobId]` has
  not been registered (i.e. `configureJob` was never called, or the job was not created
  through `ReferralCoordination`). This is the only hook check needed before money moves;
  after `fund` succeeds the config is frozen and cannot change.

- `afterAction(complete)` — the core distribution step. At this point the escrow has
  already transferred the full `job.budget` to `ReferralHook` (as the recorded provider).
  This callback computes `referralAmount` and `providerAmount` from the stored config, then
  distributes: `providerAmount` to A and `referralAmount` to B. Resolves B's payment
  address: if B has set an `agentWallet` in the ERC-8004 Identity Registry, that address
  is used; otherwise B's registered referrer address is used directly.

All other callbacks (`beforeAction(setBudget)`, `afterAction(reject)`, etc.) are no-ops
and need not be implemented. The `setBudget` proxy function itself emits the
`referralAmount` event — no hook callback is needed for that. On rejection or expiry,
`ReferralHook` holds no funds, so no hook action is required.

No vault, no pre-approval from A, and no `recoverReferralFee` function are needed. On
expiry, `ReferralHook` holds no funds — only the main escrow held C's payment, and
`claimRefund` returns it to `ReferralCoordination` which forwards to C.

---

## 7. What this ERC defines

The normative outputs of this specification are:

| Item | Description |
|------|-------------|
| `AGENT_REFERRAL_V1_TYPE` | Coordination type identifier: `keccak256("AGENT_REFERRAL_V1")` |
| `ReferralTerms` | Struct encoding the referral agreement (see §4) |
| `IReferralCoordination` | Interface for the ERC-8001 executor and ERC-8183 proxy client |
| `IReferralHook` | Interface for the provider proxy, hook callbacks, and payment split logic |
| `"referralRateBps"` | Proposed ERC-8004 metadata key; value encoded as `abi.encode(uint16)` |
| `tag1 = "referral"` | Proposed ERC-8004 feedback tag for referral reputation signals |

---

## 8. Payments and approvals

Before `fund` is called, each party must grant the correct token allowance to the correct
contract. ERC-20 tokens require the owner to explicitly authorise a smart contract to spend
on their behalf before any transfer can occur.

- **C (client)** grants one allowance: to `ReferralCoordination` for `total` (the full
  agreed job price). C does not approve the ERC-8183 escrow directly — because
  `ReferralCoordination` is the recorded ERC-8183 client, the escrow pulls from
  `ReferralCoordination`, which in turn pulls from C. C has no direct interaction with
  `ReferralHook` at any point.

- **A (provider)** grants no token allowance at any point. The payment split is handled
  entirely on the output side: the escrow pays `ReferralHook` the full budget on completion,
  and `ReferralHook` distributes from there. A's only interactions are calling `setBudget`
  and `submit` through `ReferralHook`.

- C interacts with `ReferralCoordination` for all client-role actions (`fund`, `reject`).
  Direct calls to ERC-8183 for those functions will revert because `ReferralCoordination`
  is the recorded ERC-8183 client. The one exception is `claimRefund`, which is
  permissionless and can be called directly on ERC-8183 by anyone after expiry.

- A interacts with `ReferralHook` for all provider-role actions (`setBudget`, `submit`).
  Direct calls to ERC-8183 for those functions will revert because `ReferralHook` is the
  recorded ERC-8183 provider.

---

## 9. Failure cases and liveness

A robust system must be safe even when things go wrong. Here are the cases and remedies:

- **`setBudget` never called** — The hook's `beforeAction(fund)` reverts because no referral
  config is stored. The job stays Open. Remedy: A calls `ReferralHook.setBudget(jobId,
  amount)` with a valid price.

- **Mismatched referral terms at `setBudget`** — The hook's `beforeAction(setBudget)` cross-
  checks against the stored config and reverts if they differ. The job stays Open. Remedy:
  resubmit `setBudget` with terms that match the signed coordination.

- **C's allowance missing** — `ReferralCoordination` cannot pull `total` from C, so `fund`
  reverts immediately. Remedy: C approves `total` to `ReferralCoordination`, then retries
  `fund`.

- **Expiry without funding** — The job was never funded. Parties repropose a new ERC-8001
  coordination (the old intent is expired and cannot be re-executed).

- **Expiry after funding** — `claimRefund` on ERC-8183 (called directly, not through
  `ReferralCoordination`) returns `total` to `ReferralCoordination`, which then forwards
  it to C. A has no locked funds to recover — `ReferralHook` held nothing.

- **Rejection** — The evaluator calls `reject` on ERC-8183. The escrow refunds `total` to
  `ReferralCoordination`, which forwards it to C. A has no locked funds to recover.

- **B's payment address reverts on receive** — If B's address is a smart contract that
  rejects incoming transfers, `afterAction(complete)` reverts and the entire `complete`
  transaction is rolled back. B should use a standard EOA address or a well-behaved
  `agentWallet`. A bears this risk because they chose to accept B's referral.

- **`ReferralHook` distribution fails on complete** — If either the transfer to A or B
  reverts inside `afterAction(complete)`, the entire `complete` transaction rolls back
  (including the escrow's state change). The job remains Submitted and the evaluator may
  retry. This is the standard ERC-8183 atomicity guarantee for after-hooks.

---

## 10. Constraints

These are deliberate simplifications. Each could be relaxed in a later revision.

- **One job per intent.** ERC-8001 marks an intent Executed after a single execution, so
  each referral arrangement requires a fresh signed coordination.
- **Evaluator fixed up front.** ERC-8183 requires a non-zero evaluator at `createJob`, so
  the choice of evaluator must be agreed before any money moves.
- **Hook is consented.** The hook address is in the signed `ReferralTerms`, so C explicitly
  agrees to that specific contract at signature time.
- **Referral config is immutable once funded.** After `fund` succeeds and the job moves to
  Funded, the hook config cannot change — both because ERC-8183 no longer allows `setBudget`
  and because the hook enforces the freeze.

---

## 11. Generality of the approach

The pattern described here — an ERC-8001 coordination naming a hook and an evaluator, with
the hook serving as the ERC-8183 provider and routing a payment split on completion — is
reusable beyond referrals. Any situation where an auxiliary party (auditor, platform,
affiliate) must be paid alongside the primary job escrow can be handled with the same
structure, by swapping the hook logic. The core ERC-8183 and ERC-8001 contracts remain
untouched in all such cases.

---

## 12. Suggested improvements to base ERCs (non-normative)

These are observations about limitations in the underlying standards that this ERC works
around. They are not required for this ERC to function, but addressing them would simplify
future designs and reduce the need for proxy contracts. The current implementation requires
two proxy layers — one on the client side (`ReferralCoordination` for C) and one on the
provider side (`ReferralHook` for A) — both arising from the same root cause: ERC-8183
uses `msg.sender` to determine client and provider identity at key lifecycle points.

### 12.1 `createJobFor` in ERC-8183 (eliminates the client-side proxy)

Today `createJob` sets `client = msg.sender`, meaning the contract that calls `createJob`
is permanently recorded as the client. In any composable system where a third contract
(like `ReferralCoordination`) orchestrates job creation on behalf of an end user, this
forces that contract to become a proxy: it must intercept every client-role action (`fund`,
`reject`) and re-expose them, and it introduces an extra token hop (C approves the
orchestrator, the orchestrator approves the escrow) that would otherwise be unnecessary.

A simple `createJobFor(address client, ...)` variant — where the caller can specify who the
client is — would eliminate this entirely: the orchestrator creates the job, C is recorded
as the client, and C interacts with ERC-8183 directly from that point. This is a general
composability issue, not specific to referrals: any protocol that wraps ERC-8183 job
creation faces the same problem.

### 12.2 Native payment split on `complete` in ERC-8183 (eliminates the provider-side proxy)

Today `complete` pays the full budget to `job.provider`. In this ERC, we work around this
by setting `job.provider = ReferralHook` and having `ReferralHook` distribute the payment
in its `afterAction(complete)` callback. This works, but it requires A to interact with the
escrow indirectly through a proxy for both `setBudget` and `submit`, because ERC-8183
restricts those calls to `job.provider`.

A native `payees` field at job creation — for example,
`createJob(..., PayeeShare[] payees)` where each entry specifies an address and a share in
basis points — would allow the split to be declared upfront and executed atomically by the
escrow itself, with no proxy provider needed. A would be recorded as `job.provider` and
interact with the escrow directly; the referral fee would flow to B as part of the
`complete` distribution without any hook logic or intermediate contract.

### 12.3 Combined effect

If both improvements were adopted:

- `createJobFor` → C is recorded as the ERC-8183 client and interacts directly. No
  `ReferralCoordination` proxy functions needed for `fund` and `reject`.
- Native payees → A is recorded as the ERC-8183 provider and interacts directly. No
  `ReferralHook` proxy functions needed for `setBudget` and `submit`.

`ReferralCoordination` would shrink to a pure ERC-8001 executor (signature verification
and job creation only) and `ReferralHook` would shrink to a pure policy hook (term
verification only, no token custody). The composability gain would apply to any protocol
layered on top of ERC-8183, not just referrals.

