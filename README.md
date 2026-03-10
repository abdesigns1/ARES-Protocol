# ARES Protocol — Treasury Execution System

A modular, secure treasury management system for decentralized protocols.

## Quick Start

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install foundry-rs/forge-std

# Run tests
forge test -v

# Deploy (set env vars first)
export SIGNER1=0x...
export SIGNER2=0x...
export SIGNER3=0x...
export REWARD_TOKEN=0x...
forge script script/Deploy.s.sol --broadcast --rpc-url $RPC_URL
```

## File Structure

```
src/
  interfaces/
    IProposalManager.sol      # Proposal system interface
    IRewardDistributor.sol    # Reward distribution interface
  libraries/
    SignatureLib.sol           # EIP-712 signature logic
    MerkleLib.sol              # Merkle proof verification
  modules/
    TimelockEngine.sol         # Delayed execution queue
    RewardDistributor.sol      # Merkle-based reward claims
    GovernanceGuard.sol        # Economic attack protections
  core/
    ProposalManager.sol        # Main governance entry point

test/
  AresProtocol.t.sol           # Full test suite (functional + exploit)

script/
  Deploy.s.sol                 # Deployment script
```

---

## Protocol Specification

### Actors

- **Signers** — a fixed set of authorized addresses (e.g. a 3-person council). They can propose and approve treasury actions.
- **Contributors** — any address that has earned rewards. They claim tokens using Merkle proofs.
- **Governance address** — set at deploy time. Controls GovernanceGuard limits and RewardDistributor roots.

---

### Proposal Lifecycle

#### 1. Proposal Creation

A signer calls `ProposalManager.propose(actionType, token, target, amount, callData)`.

The proposal is stored on-chain with state `Pending`. A `ProposalCreated` event is emitted.

Preconditions:

- Caller must be an authorized signer
- Caller must not be in the proposal cooldown window (1 hour since last proposal)
- Target address must not be zero
- For Transfer proposals, amount must be > 0

The proposal gets a unique auto-incrementing `id`.

---

#### 2. Approval (Signature Collection)

Each authorized signer who wants to approve calls `ProposalManager.approve(proposalId, signature)`.

The signature must be an EIP-712 structured signature over:

```
ApproveProposal(uint256 proposalId, uint256 nonce, uint256 deadline)
```

The contract:

1. Checks the signer is authorized
2. Checks the signer has not already approved this proposal
3. Reconstructs the digest using the signer's current nonce
4. Recovers the signer address via ecrecover
5. Verifies the recovered address matches the caller
6. Increments the signer's nonce
7. Increments the proposal's approval count
8. If approvalCount >= threshold, advances state to `Approved`

Signers must submit their own signature (the caller must be the signer). Off-chain signatures are collected and submitted by each signer individually.

---

#### 3. Queueing

Once a proposal reaches `Approved` state, anyone can call `ProposalManager.queue(proposalId)`.

This:

1. Computes the operation ID: `keccak256(target, value, calldata, proposalId)`
2. Calls `TimelockEngine.queue(opId)` which records `readyTime = block.timestamp + 2 days`
3. Advances proposal state to `Queued`
4. Emits `ProposalQueued`

The operation ID uniquely identifies this specific execution — the same proposal content queued twice would have the same ID and be rejected.

---

#### 4. Execution

After the timelock delay has passed (minimum 2 days, maximum 2 days + 7 day grace period), anyone can call `ProposalManager.execute(proposalId)`.

This:

1. Checks proposal is in `Queued` state
2. For Transfer proposals: checks single-tx drain limit and daily drain limit via GovernanceGuard
3. Advances state to `Executed`
4. Calls `TimelockEngine.execute(opId, target, 0, calldata)` which:
   - Verifies the delay has passed and grace period hasn't expired
   - Deletes the operation from the queue (preventing replay)
   - Calls the target with the calldata
   - Reverts the entire transaction if the call fails

---

#### 5. Cancellation

Any signer or the original proposer can call `ProposalManager.cancel(proposalId)` while the proposal is in `Pending` or `Approved` state.

This advances the state to `Cancelled`. A cancelled proposal cannot be re-activated.

If the proposal was already `Queued`, the cancellation must also remove it from the timelock — in the current implementation, only pre-queue cancellation is supported for simplicity.

---

### Reward Distribution Lifecycle

#### 1. Root Update

Governance calls `RewardDistributor.updateRoot(merkleRoot)`. This increments the epoch counter and stores the root. Emits `RootUpdated`.

#### 2. Claiming

A contributor calls `RewardDistributor.claim(epoch, amount, proof)`.

The contract:

1. Checks the epoch is valid
2. Checks the caller has not already claimed for this epoch
3. Computes the leaf: `keccak256(keccak256(abi.encodePacked(user, amount, epoch)))`
4. Verifies the Merkle proof against the stored root
5. Marks the claim as done (before transfer)
6. Transfers `amount` tokens to the caller

---

## Attack Prevention Summary

| Attack                 | Prevention                                                    |
| ---------------------- | ------------------------------------------------------------- |
| Reentrancy             | NonReentrant modifier + delete-before-call pattern            |
| Signature replay       | Per-signer nonces                                             |
| Signature malleability | High-s value check in SignatureLib                            |
| Cross-chain replay     | chainId in EIP-712 domain separator                           |
| Domain collision       | Contract address in domain separator                          |
| Double claim           | Per-epoch claimed bitmap                                      |
| Unauthorized execution | Only ProposalManager can call TimelockEngine                  |
| Timelock bypass        | Delay enforced by block.timestamp, checked before execution   |
| Large treasury drain   | 10% single-tx cap + daily limit in GovernanceGuard            |
| Proposal griefing      | 1-hour cooldown per proposer                                  |
| Proposal replay        | Operation ID derived from content; duplicate queuing rejected |

This system was designed from scratch. While it borrows well-established patterns (EIP-712, Merkle proofs, timelocks), no existing contract was copied or modified. Key departures include: per-signer on-chain nonces instead of per-transaction nonces, multi-epoch Merkle roots with persistent claim history, a standalone GovernanceGuard rate-limiter, and a unified grace period + drain cap not found in standard timelock implementations.
