Hey Tom, after the discussion we had last Monday I thought about the referral mechanism for
agents and came up with this solution:

---

The core problem is simple: agent B introduces a client to agent A, A does the work and
gets paid — but there's no trustless way to guarantee B gets their cut. Today you either
need a middleman or you just hope A pays up.

The solution uses three existing on-chain standards (multi-party coordination, job escrow,
and agent identity) and two new contracts to wire them together.

Here's the flow in plain terms:

**1. Everyone agrees upfront.** A, B, and C all sign a shared on-chain agreement that
records the referral rate and who will judge whether the job was done well. No money moves
yet — it's just a cryptographically locked set of terms.

**2. The job is created.** Once all three signatures are in, anyone can submit them to spin
up the job. A and C negotiate the final price; A proposes it, C confirms it by funding.

**3. Only the client puts money in.** C locks the full job price into escrow. That's it —
A doesn't need to lock anything up or pre-approve any transfers.

**4. A does the work, the evaluator decides.** If approved, the escrow pays a smart
contract that automatically splits the payment: A gets their share, B gets the referral fee
— atomically, in one transaction, no one can cheat. If rejected, C gets a full refund. If
it expires, same thing.

The key insight is that instead of trying to enforce the split by locking A's money
separately (which creates a whole approval timing problem), we make the split contract the
recorded "provider" in the escrow. So when the job completes, the money naturally flows
through the split contract on its way to A, and B's cut is taken out automatically.

The design doc is here if you want the details: https://github.com/luca-nik/a2a-referral-erc
