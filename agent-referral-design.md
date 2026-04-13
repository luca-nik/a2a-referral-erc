# Agent Referral — Design (single‑job v1)

---

## 1. Problem

Agents in the open agent economy have no standardized way refer clients to one another. Imagine agent A
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
economic parties (A, B, C), and the payout enforcement rides on ERC-8183 with a hook that
handles just the referral leg. It is token-agnostic (any ERC-20 supported by the underlying
ERC-8183 instance) and uses a single evaluator (E) named in the terms, but E does not sign
the coordination.

Multi-job bundles, multi-level chains, and split payouts inside core ERC-8183 are
intentionally deferred to keep the first version simple and auditable.

---

## 3. Roles

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

`referralRateBps` expresses the fee as basis points — a standard
financial convention where 10 000 = 100%. So a 5% referral fee is 500 bps. The `hook`
field is the address of the ReferralHook smart contract; all parties must agree on this
address in the signed terms, which means A explicitly consents to the hook holding and
distributing the referral fee. The `evaluator` is named here rather than left open, so
everyone knows upfront who will judge the job.

`ReferralCoordination` MUST verify that `terms.provider`, `terms.referrer`, and
`terms.client` are exactly the three addresses in `intent.participants`. Any of the three
may be the proposer (`intent.agentId`); the referrer is always identified by `terms.referrer`
regardless of who initiates the coordination. B's consent is proven by their acceptance
signature as a named participant, not by being the proposer.

---

## 5. High-level flow (single job)

### Walkthrough

B has introduced a client to A. All three — A (provider), B (referrer), and C (client) —
agree off-chain on the referral rate and who will evaluate the job. They then each sign a shared
on-chain agreement that records exactly who gets what and who will judge the outcome. No
money moves at this stage; the signatures are simply proof that everyone consented to the
same terms.

Once all three signatures are collected, anyone can submit them to the blockchain. This
creates the job in an open state, and both A and C can still negotiate the final price. When
they settle, C approves the full job price to the escrow, and A approves the referral fee to
the hook. C then calls fund: in a single transaction, the escrow pulls C's payment and the
hook pulls A's referral fee. If either transfer fails, neither happens — the job stays open
and no money moves. Once both transfers succeed, the job is funded and the price is locked.

A does the work and submits it. The evaluator — agreed upfront, and which could be C
themselves or a neutral third party — reviews the submission and decides:

- **Approved:** the escrow pays A the full job price; the hook pays B the referral fee. A's
  net is the job price minus the commission they pre-committed.
- **Rejected:** the escrow refunds C; the hook refunds A.
- **Expired:** if no decision is made in time, C can reclaim their payment from the escrow,
  and A can reclaim their referral fee from the hook.

### Step-by-step

1. **(Optional)** A advertises their default referral rate in their ERC-8004 agent profile
   using the metadata key `"referralRateBps"` — a new convention proposed by this ERC
   (see §6.2).
2. Any of A, B, or C proposes an ERC-8001 coordination with `coordinationType =
   AGENT_REFERRAL_V1_TYPE` and the encoded `ReferralTerms` as payload. Participants are
   {A, B, C} sorted ascending by address (required by ERC-8001 for canonical ordering).
   The proposer sets `intent.agentId` to their own address; the referrer is identified
   by `terms.referrer`, not by who proposes.
3. A, B and C sign acceptances (ERC-8001). All
   three signatures are now on-chain or available off-chain for submission.
4. Anyone calls `ReferralCoordination.executeCoordination(...)`, which verifies all
   signatures and checks that `terms.provider`, `terms.referrer`, and `terms.client` match
   the participants list exactly, then calls `createJob` on ERC-8183 with `provider=A`,
   `evaluator=E`, `hook=ReferralHook`. Because ERC-8183's
   `createJob` sets `client = msg.sender`, **`ReferralCoordination` becomes the ERC-8183
   client** and acts as a proxy for C from this point (see §6.4). The mapping
   `intentHash → jobId` is stored so the hook can later verify terms.
5. While the job is **Open**, `setBudget(jobId, amount, optParams)` may be called by A or C
   through `ReferralCoordination`, which validates `msg.sender` before forwarding:
   - `optParams = abi.encode(referrer, rateBps)` carries the referral terms to the hook.
   - The hook's `beforeAction(setBudget)` decodes these, cross-checks them against the
     signed ERC-8001 intent, and stores the per-job referral config. If they don't match
     the signed terms it reverts. Config may be overwritten by subsequent `setBudget` calls
     during price negotiation — this is intentional, as A and C may take several rounds to
     agree on a price.
   - The hook SHOULD emit an event with the computed `referralAmount = amount * rateBps /
     10_000` so A knows the exact token allowance to grant the hook before `fund` is called.
6. C calls `fund(jobId, expectedBudget)` through `ReferralCoordination`. In the same
   transaction, atomically:
   - The hook's `beforeAction(fund)` reverts if no referral config is stored (i.e. no valid
     `setBudget` was ever called), keeping the job Open.
   - ERC-8183 pulls `job.budget` (= `total`) from C into escrow.
   - The hook's `afterAction(fund)` pulls `referralAmount` from A into the hook's custody.
   - If either transfer fails (missing or insufficient allowance), the entire transaction
     reverts and no funds move. Once `fund` succeeds the job is Funded; `setBudget` is no
     longer callable and the referral config is frozen.
7. A grants ERC-20 allowance to ReferralHook for `referralAmount` at any point after
   `setBudget` is agreed and before C calls `fund` (see §8).
8. Provider submits work → Evaluator decides:
   - **Complete:** escrow pays A `total`; hook pays B `referralAmount` (using B's
     `agentWallet` from ERC-8004 if set, otherwise B's registered address). A's net
     receipt is `total − referralAmount`.
   - **Reject:** escrow refunds C `total`; hook refunds A `referralAmount`.
   - **Expiry:** `claimRefund` on ERC-8183 (not hookable; called directly, not through
     `ReferralCoordination`) refunds C `total`; A calls `recoverReferralFee(jobId)` on the
     hook to reclaim `referralAmount`.

### Payment split

```
referralAmount  = (total × rateBps) / 10_000   // A's commission to B; truncated
providerAmount  = total − referralAmount        // A's net receipt on completion
job.budget      = total                         // C's full payment into escrow
```

**Worked example:** C agrees to pay 1 000 USDC for a job; `referralRateBps = 500` (5%).
`referralAmount = 50 USDC` (paid by A into the hook at fund time).
`providerAmount = 950 USDC` (A's net on completion).
C pays 1 000 USDC to escrow. A pre-commits 50 USDC to the hook. On completion: escrow
releases 1 000 USDC to A, hook releases 50 USDC to B — A nets 950 USDC. On rejection:
escrow returns 1 000 USDC to C, hook returns 50 USDC to A.

---

## 6. Components

This ERC introduces two new smart contracts (`ReferralCoordination` and `ReferralHook`)
and uses three existing ones unmodified. Here is how they relate:

- **ERC-8001** handles the multi-party signature and agreement phase (off-chain signing,
  on-chain verification).
- **ERC-8183** handles the job lifecycle and the main escrow (C's payment to A).
- **ERC-8004** provides agent identity and the optional reputation record.
- **ReferralCoordination** is the bridge: it verifies the signed agreement and creates the
  ERC-8183 job, then acts as a proxy so C can interact with the job through it.
- **ReferralHook** is the enforcement mechanism for the referral leg: it holds A's
  pre-committed fee and distributes it based on the job outcome.

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

This ERC uses ERC-8183 **unmodified**. The hook field (an optional extension point in
ERC-8183) is set to `ReferralHook` at job creation. The standard lifecycle is:
`createJob` → Open → `fund` → Funded → `submit` → Submitted → `complete` / `reject`.
`claimRefund` is deliberately non-hookable in ERC-8183, which is why expiry recovery
requires a separate `recoverReferralFee` call on the hook.

### 6.4 ReferralCoordination (new)

`ReferralCoordination` serves two roles:

**As an ERC-8001 executor:** it implements the `executeCoordination` entry point, verifies
all three signatures, checks that `terms.provider`, `terms.referrer`, and `terms.client`
match the participant set exactly, and ensures single execution. Any of the three may be the
proposer. It then calls `createJob` on ERC-8183 and stores the `intentHash → jobId` mapping
so the hook can later cross-check terms.

**As a proxy client for ERC-8183:** because ERC-8183's `createJob` sets `client =
msg.sender`, `ReferralCoordination` becomes the ERC-8183 client for every job it creates.
To allow C to exercise client-role functions (`setBudget`, `fund`, `reject`), the contract
exposes proxied versions of these functions that check `msg.sender == terms.client` before
forwarding the call to ERC-8183. This pattern keeps ERC-8183 fully unmodified while
enforcing C's consent at the coordination layer.

Note: `claimRefund` is permissionless in ERC-8183, so C (or anyone) can call it directly
on ERC-8183 without going through `ReferralCoordination`.

### 6.5 ReferralHook (new)

`ReferralHook` is a shared singleton smart contract implementing the ERC-8183 `IACPHook`
interface. It acts as a small, purpose-built vault for the referral fee: A deposits into it
when the job is funded, and it pays out (or refunds) based on the job outcome.

**Per-job storage:** `referralConfig[jobId] = { referrer, rateBps }`

**Hook callbacks and their purpose:**

- `beforeAction(setBudget)` — Validates incoming `optParams = abi.encode(referrer, rateBps)`
  against the signed ERC-8001 terms for this job (via `intentHash → jobId`). Stores or
  overwrites the referral config. Multiple calls are allowed during Open (price
  negotiation). Emits an event with the computed `referralAmount` so A knows what allowance
  to approve before `fund`.

- `beforeAction(fund)` — Acts as a gate: MUST revert if no referral config has been stored.
  This is the last check before money moves; after `fund` succeeds the config is frozen and
  cannot change.

- `afterAction(fund)` — Pulls `referralAmount` from A (the provider) via `transferFrom`.
  This runs in the same transaction as C's escrow deposit: either both transfers succeed, or
  both revert and no money moves.

- `afterAction(complete)` — Pays `referralAmount` to B. Resolves B's payment address: if B
  has set an `agentWallet` in the ERC-8004 Identity Registry, that address is used;
  otherwise B's registered referrer address is used directly.

- `afterAction(reject)` — Refunds `referralAmount` to A (who deposited it), since the job
  did not complete.

- `recoverReferralFee(jobId)` — A public function (not a hook callback) that A calls after
  expiry to reclaim `referralAmount` from the hook. Necessary because `claimRefund` in
  ERC-8183 is not hookable, so the hook's funds are not automatically returned on expiry.

In summary: the hook enforces the referral leg independently of the main escrow. C pays the
standard job price; A pre-commits the commission; the outcome (complete / reject / expire)
determines where the fee goes. Tampering is prevented because the hook cross-checks every
configuration call against what all three parties signed in ERC-8001.

---

## 7. What this ERC defines

The normative outputs of this specification are:

| Item | Description |
|------|-------------|
| `AGENT_REFERRAL_V1_TYPE` | Coordination type identifier: `keccak256("AGENT_REFERRAL_V1")` |
| `ReferralTerms` | Struct encoding the referral agreement (see §4) |
| `IReferralCoordination` | Interface for the ERC-8001 executor and ERC-8183 proxy client |
| `IReferralHook` | Interface for the referral fee vault and payout logic |
| `"referralRateBps"` | Proposed ERC-8004 metadata key; value encoded as `abi.encode(uint16)` |
| `tag1 = "referral"` | Proposed ERC-8004 feedback tag for referral reputation signals |

---

## 8. Payments and approvals

Before `fund` is called, each party must grant the correct token allowance to the correct
contract. ERC-20 tokens (the token standard used here) require the owner to explicitly
authorise a smart contract to spend on their behalf before any transfer can occur.

- **C (client)** grants one allowance: to the ERC-8183 job contract for `total` (the
  full agreed job price). C has no direct interaction with the hook contract at any point.

- **A (provider)** grants one allowance: to `ReferralHook` for `referralAmount`. The hook
  emits this exact amount when `setBudget` is called, so A knows precisely what to approve.
  A must do this before C calls `fund`; if the allowance is missing when `fund` is called,
  the transaction reverts and C's funds are not moved (the two transfers are atomic).

- C interacts with `ReferralCoordination` for all client-role actions (`setBudget`, `fund`,
  `reject`). Direct calls to ERC-8183 for those functions will revert because
  `ReferralCoordination` is the recorded ERC-8183 client. The one exception is `claimRefund`,
  which is permissionless and can be called directly on ERC-8183 by anyone after expiry.

---

## 9. Failure cases and liveness

A robust system must be safe even when things go wrong. Here are the cases and remedies:

- **A's allowance missing or too small** — The hook's `afterAction(fund)` reverts when
  trying to pull `referralAmount` from A. The whole `fund` transaction reverts; the job
  stays Open; C's funds are not moved. Remedy: A approves `referralAmount` to ReferralHook,
  then C retries `fund`.

- **C's escrow allowance missing** — `fund` reverts before the hook is even called. Remedy:
  C approves `total` to the ERC-8183 job contract, then retries `fund`.

- **`setBudget` never called with valid `optParams`** — The hook's `beforeAction(fund)`
  reverts because no referral config is stored. The job stays Open. Remedy: A or C calls
  `setBudget` through `ReferralCoordination` with the correct `optParams`.

- **Mismatched referral terms at `setBudget`** — The hook decodes `optParams` and compares
  against the signed ERC-8001 intent; if they differ it reverts. The job stays Open.
  Remedy: resubmit `setBudget` with terms that match the signed coordination.

- **Expiry without funding** — The job was never funded. Parties repropose a new ERC-8001
  coordination (the old intent is expired and cannot be re-executed).

- **Expiry after funding** — `claimRefund` on ERC-8183 (called directly, not through
  `ReferralCoordination`) refunds C `total` from escrow. A separately calls
  `recoverReferralFee(jobId)` on the hook to reclaim `referralAmount`.

- **B's payment address reverts on receive** — If B's address is a smart contract that
  rejects incoming transfers, `afterAction(complete)` reverts and the entire `complete`
  transaction is rolled back. B should use a standard EOA address or a well-behaved
  `agentWallet`. A bears this risk because they chose to accept B's referral.

---

## 10. Out of scope / future work

The following are deliberately excluded from v1 to keep the design simple and auditable.
They may be addressed in later revisions:

- Multi-job referrals from one signed intent (would require replay counters).
- Late-bound or rotating evaluator.
- Multi-level referral chains (B referred by a C, etc.).
- Alternate payout curves (non-linear splits, caps, vesting).

---

## 11. Constraints (v1 assumptions)

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

## 12. Generality of the approach

The pattern described here — an ERC-8001 coordination naming a hook and an evaluator, with
the hook holding and routing a side payment — is reusable beyond referrals. Any situation
where an auxiliary party (auditor, platform, affiliate) must be paid alongside the primary
job escrow can be handled with the same structure, by swapping the hook logic. The core
ERC-8183 and ERC-8001 contracts remain untouched in all such cases.

---

## 13. Suggested improvements to base ERCs (non-normative)

These are observations about limitations in the underlying standards that this ERC works
around. They are not required for this ERC to function, but addressing them would simplify
future designs.

- **Split payouts in ERC-8183.** Today ERC-8183 pays the full budget to the provider on
  completion. If ERC-8183 supported declaring multiple payees and weights at job creation,
  the referral fee could flow directly from the escrow — eliminating A's separate approval
  and the external hook vault entirely.

- **`createJobFor(address client, ...)` in ERC-8183.** Today `createJob` sets `client =
  msg.sender`. If ERC-8183 accepted an explicit client address, any party could execute the
  coordination and create the job while still recording C as the client — removing the need
  for the proxy-client pattern in `ReferralCoordination`.

- **Late-bound evaluator in ERC-8183.** A guarded `setEvaluator` function (callable only
  before funding) would allow the evaluator to be chosen after the job is created but before
  funds are locked. The current spec requires evaluator at creation; this ERC mirrors that.

- **Standardise `referralRateBps` and `tag1="referral"` in ERC-8004.** Formalising these
  conventions directly in ERC-8004 would make referral-rate discovery and reputation
  filtering composable across any ERC-8004 consumer, rather than each downstream ERC
  defining its own conventions.
