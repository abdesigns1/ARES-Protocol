# ARES Protocol — Security Analysis

## Major Attack Surfaces

### 1. Signature Replay Attacks

**The threat:** An attacker intercepts a valid signature from an authorized signer and reuses it to approve a different or future proposal.

**How we prevent it:**
We use EIP-712 structured signatures. Every approval signature covers three things: the proposal ID, the signer's current nonce, and a deadline. After a signer approves a proposal, their nonce increases by one. So the same signature can never be used again — the nonce won't match.

The domain separator includes the chain ID and the contract address. This means a signature from Ethereum mainnet cannot be replayed on Arbitrum, and a signature meant for one deployment cannot be used on another.

**Remaining risk:** If a signer's private key is leaked, an attacker can produce fresh valid signatures. This is a key management risk, not a protocol risk. The threshold requirement (2-of-3) means a single key leak does not immediately compromise the treasury.

---

### 2. Reentrancy Attacks

**The threat:** A malicious contract is called during execution and calls back into our contract before the first call finishes — potentially executing the same operation twice or corrupting state.

**How we prevent it:**
TimelockEngine has a manual reentrancy guard using a `uint256 _lock` variable. When `execute()` starts, it sets `_lock = 2`. Any re-entrant call will find `_lock == 2` and revert. After execution finishes, `_lock` is reset to 1.

More importantly, we delete the operation from the queue *before* making the external call. This is the "checks-effects-interactions" pattern. Even if the reentrancy guard weren't there, the operation ID would already be gone, so a re-entrant execute would fail with "not queued."

**Remaining risk:** The external call itself (`target.call`) can execute arbitrary code. We can't prevent the target from doing bad things — we can only prevent it from affecting our own state.

---

### 3. Flash Loan Governance Manipulation

**The threat:** An attacker borrows a huge amount of tokens in a flash loan, uses them to pass a governance vote, then repays the loan — all in one transaction.

**How we prevent it:**
The ARES proposal system uses explicit signer addresses rather than token voting. Signers are fixed at deployment time. Flash loans cannot give an attacker signer status because signer status is not purchased — it is assigned.

Additionally, GovernanceGuard enforces a 1-hour cooldown between proposals from the same signer. Even if an attacker somehow gained signer rights, they couldn't push through multiple proposals in a single block.

**Remaining risk:** If the governance model is extended to include token-weighted voting in the future, the current guard would need to be updated to require a minimum holding period (e.g., balance snapshot from N blocks ago).

---

### 4. Large Treasury Drain

**The threat:** A compromised or malicious proposal attempts to drain most or all of the treasury in one transaction.

**How we prevent it:**
GovernanceGuard enforces two limits:
- **Single transaction cap:** No single transfer can exceed 10% of the current treasury balance (1000 basis points out of 10,000).
- **Daily drain limit:** Total outflows across all proposals are tracked and capped at a configurable daily maximum. The window resets every 24 hours.

If an attacker somehow controlled enough signers to pass a malicious proposal, they could drain at most 10% per day. This limits the damage and gives the community time to respond.

**Remaining risk:** If the daily limit is set too high by governance, the protection is weakened. The initial limit must be set conservatively.

---

### 5. Double Claim in Reward Distribution

**The threat:** A contributor claims their reward, then claims again using the same proof to receive double payout.

**How we prevent it:**
RewardDistributor maintains a `mapping(uint256 epoch => mapping(address => bool))` that marks each address as claimed per epoch. The claim function checks this flag first and reverts if already set. The flag is set *before* the token transfer, so even if the token had a malicious hook, the claim would already be marked.

---

### 6. Merkle Root Manipulation

**The threat:** Someone submits a fake Merkle root that lets them claim more tokens than they're entitled to.

**How we prevent it:**
Only the governance address can call `updateRoot()`. The root itself is just a 32-byte hash — it has no value unless you have a corresponding proof. The off-chain Merkle tree generation needs to be done carefully and the root verified before submission.

We also use double hashing for leaf construction (`keccak256(keccak256(...))`) to prevent second preimage attacks where an internal tree node could be mistaken for a leaf.

**Remaining risk:** If the off-chain tree generation is wrong, some users get incorrect amounts. There's no on-chain verification that the tree is well-formed. This is an operational risk.

---

### 7. Timelock Bypass

**The threat:** Someone finds a way to execute a transaction without waiting for the timelock delay.

**How we prevent it:**
TimelockEngine uses `block.timestamp` for timing. The minimum delay is 2 days. Ethereum validators can only manipulate timestamps by a few seconds, not days. The operation ID must be queued before it can be executed — you can't skip the queue step.

The operation ID is computed from the target address, call data, and proposal ID. You can't substitute different parameters at execution time.

**Remaining risk:** A miner with extreme hash rate could try to manipulate timestamps slightly, but a 2-day window is far too large for this to matter in practice.

---

### 8. Proposal Griefing

**The threat:** An attacker (or rogue signer) spams the system with fake proposals, filling the queue and preventing legitimate proposals from being seen or processed.

**How we prevent it:**
GovernanceGuard enforces a 1-hour cooldown per proposer address. A signer can only submit one proposal per hour. This limits griefing to one proposal per hour per key, which is manageable.

Additionally, any signer can cancel a pending or approved proposal. So legitimate signers can clean up spam quickly.

---

## Summary of Remaining Risks

| Risk | Severity | Notes |
|------|----------|-------|
| Signer key compromise | High | Mitigated by threshold (2-of-3), but key hygiene is critical |
| Off-chain Merkle tree error | Medium | Operational risk, needs careful tooling |
| Governance capture (long term) | Medium | If token voting is added later, flash loan protections must be added |
| Timestamp manipulation | Low | 2-day delay makes this impractical |
