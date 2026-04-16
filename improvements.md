# Improvements

Open design improvements to address before finalising the ERC.

---

## 1. Replace `address[]` participants with explicit fields

ERC-8001 uses a generic `address[] participants` array. Our ERC narrows the coordination to exactly two parties, so the array length check (`participants.length == 2`) is a runtime guard on an otherwise representable invalid state.

**Fix:** derive the two participants directly from `ReferralTerms.provider` and `ReferralTerms.referrer`. Replace the length check with explicit field validation:
- `terms.provider != terms.referrer`
- `intent.agentId == terms.provider || intent.agentId == terms.referrer`
- `intent.participants` must equal `{terms.provider, terms.referrer}`

Invalid states (zero, one, or three participants) become unrepresentable by construction.

---

## 2. `referralRateBps` range check is a footgun

Capping `uint16 referralRateBps` at `10_000` via a runtime revert leaves the invalid range (10_001–65_535) representable. The check can be forgotten by downstream implementations.

**Options to consider:**
- Use the full `uint16` range (0–65_535) and redefine the unit so that `type(uint16).max` = 100% — no cap, no check, no invalid state
- Keep basis points but accept that the single validation in `proposeCoordination` is the only place it is ever checked, and document this guarantee explicitly so downstream never needs to re-check

---

## 3. Rate privacy

The rate (`referralRateBps`) is strategically sensitive information. A client who knows the rate could use it to negotiate directly with the provider, cutting out the referrer.

**Proposed approach:** store a hash commitment on the rate field instead of the plaintext value — `keccak256(abi.encode(rateBps, salt))`. The rate is revealed selectively: to the client off-chain, to a payment hook at execution time, or publicly at dispute. Participant addresses remain public (required by ERC-8001 for bilateral signing guarantee and liability).

This requires changes to:
- `ReferralTerms` struct (replace `referralRateBps` with `bytes32 rateCommit`)
- `referralInfo` return values (return `rateCommit` instead of `rateBps`)
- Validation in `proposeCoordination` (rate range check moves off-chain)
- A `revealRate(bytes32 intentHash, uint16 rateBps, bytes32 salt)` function for dispute disclosure

---

## 4. Further additions

_Space reserved for additional improvements raised during review._
