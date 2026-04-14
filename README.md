# Agent-to-Agent Referral ERC

A credential standard for referral agreements between AI agents, built on top of
[ERC-8001](https://eips.ethereum.org/EIPS/eip-8001) (multi-party coordination) and
[ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) (agent identity and reputation).

> **Full design document:** [agent-referral-design.md](./agent-referral-design.md)

---

## The problem

Agents refer clients to one another but have no standard way to represent or prove the
arrangement. When B introduces C to A and A gets paid, A owes B a commission — but there
is no on-chain primitive to record that agreement, verify it was made, or prove it was
not honoured.

---

## What this ERC defines

A and B co-sign a referral arrangement on-chain using ERC-8001. The result is a
**referral key** — a 32-byte `intentHash` that anyone can query:

```solidity
referralInfo(intentHash) → (provider, referrer, rateBps, valid)
```

That is the standard. A single read function backed by a cryptographic commitment.

- **Unforgeable** — the key contains A's EIP-712 signature. A cannot deny the agreement.
- **Universally queryable** — any wallet, contract, or indexer can verify the terms.
- **Socially enforced** — if A is paid and does not pay B, the evidence is on-chain.
  ERC-8004 reputation is the stick.
- **Implementation-agnostic** — how A honours the key is their own choice. Providers
  who pay their referrers attract more referral business.

---

## Flow

```mermaid
sequenceDiagram
    participant A as A - Provider
    participant B as B - Referrer
    participant C as C - Client
    participant RC as ReferralCoordination

    note over A,RC: Phase 1 - A and B establish the referral credential

    A->>RC: propose coordination with referrer=B, rateBps
    B->>RC: sign acceptance
    note over RC: intentHash is the referral key - queryable via referralInfo

    note over A,RC: Phase 2 - B introduces C and shares the key

    B-->>C: share intentHash (off-chain)

    note over A,RC: Phase 3 - C works with A (implementation specific)

    C->>A: create job, passing intentHash per A's instructions
    note over A,C: A honours the referral per their advertised mechanism
    A->>B: pay referral fee (trustless via hook or manual)
```

---

## Previous designs

More complex enforcement-first designs are archived in
[previous-versions/](./previous-versions/).
