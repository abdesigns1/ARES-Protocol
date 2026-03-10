# ARES Protocol — Architecture Document

## Overview

ARES Protocol is a treasury execution system designed to manage $500M+ in assets on behalf of a decentralized community. The system consists of multiple small, specialized contracts, each responsible for a single task. This design is intentional if all functions were combined in one contract, a flaw in one section could compromise the entire system. By maintaining separate modules, we can analyze them individually.

## System Architecture

The system has four main layers:

### 1. Interfaces (`src/interfaces/`)

These are just Solidity `interface` files that describe what each module can do. Consider them as a contract linking different code components, if you understand the interface, you can engage with the module without needing to understand its internal workings. This simplifies testing and upgrading.

### 2. Libraries (`src/libraries/`)

Reusable code that has no state of its own. We have two:

- **SignatureLib** — handles all the EIP-712 signature logic. Any contract that needs to verify a signature imports this library.
- **MerkleLib** — handles Merkle proof verification. The RewardDistributor uses this to let users prove they are entitled to rewards.

Libraries keep the main contracts small and reduce duplication.

### 3. Modules (`src/modules/`)

Standalone contracts that do one specific job:

- **TimelockEngine** — holds queued transactions and enforces a minimum 2-day wait before they can be executed. It also has reentrancy protection built in.
- **RewardDistributor** — manages Merkle-based reward claims. Governance pushes a new root hash each epoch and contributors claim their own tokens using Merkle proofs.
- **GovernanceGuard** — enforces economic limits: max 10% of treasury in a single transaction, a daily outflow cap, and a cooldown between proposals from the same address.

### 4. Core (`src/core/`)

- **ProposalManager** — the main entry point. Coordinates the entire lifecycle: creates proposals, collects EIP-712 signatures from signers, moves approved proposals into the timelock queue, and calls execute after the delay. It is the only address allowed to talk to TimelockEngine and GovernanceGuard.

## Module Separation and Trust Boundaries

The key trust rule is simple: **only ProposalManager can trigger state changes in TimelockEngine and GovernanceGuard**. Anyone can read from these contracts, but only the governance address can write.

```
User/Signer
    │
    ▼
ProposalManager (core)
    ├── reads: SignatureLib, MerkleLib (libraries)
    ├── writes: TimelockEngine (queue, execute, cancel)
    └── writes: GovernanceGuard (checkTransferLimit, recordOutflow, checkProposalCooldown)

TimelockEngine
    └── executes: any target address (calls the final transaction)

RewardDistributor
    └── controlled by: governance address (separate from ProposalManager in some deployments)
```

Users interact only with ProposalManager and RewardDistributor. They never call TimelockEngine or GovernanceGuard directly — those are internal implementation details.

## Security Boundaries

Each module assumes the module above it is honest, but does not assume anything about the modules below it. For example:

- TimelockEngine does not trust that the caller gave it a valid operation ID. It just checks that the ID was previously queued and the delay has passed.
- GovernanceGuard does not trust that the treasury balance is correct. It enforces limits based on whatever balance ProposalManager reports.
- RewardDistributor does not trust the claimer. It only trusts the Merkle root set by governance.

This means even if ProposalManager were compromised, TimelockEngine's delay would still give observers time to notice and react.

## Trust Assumptions

1. The initial set of signers is honest and their private keys are not compromised.
2. The deployment is done correctly (governance addresses set properly).
3. The Merkle tree off-chain computation is correct (wrong roots = wrong payouts).
4. Block timestamps can be manipulated slightly by validators, but not by days — so our 2-day delay is safe in practice.
5. The ERC-20 token used for rewards is not malicious (no hooks that call back into our contracts).
