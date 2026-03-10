// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IProposalManager
/// @notice Interface for creating and managing treasury proposals
interface IProposalManager {
    // The different stages a proposal can be in
    enum ProposalState {
        Pending,    // just created, waiting for approvals
        Approved,   // enough signatures collected
        Queued,     // sitting in the timelock queue
        Executed,   // successfully ran
        Cancelled   // cancelled or expired
    }

    // What kind of action a proposal can do
    enum ActionType {
        Transfer,   // send tokens somewhere
        Call,       // call an external contract
        Upgrade     // upgrade a contract
    }

    // The full proposal data structure
    struct Proposal {
        uint256 id;
        ActionType actionType;
        address token;          // used for Transfer actions
        address target;         // recipient or contract to call
        uint256 amount;         // used for Transfer actions
        bytes callData;         // used for Call/Upgrade actions
        uint256 createdAt;
        uint256 approvalCount;
        ProposalState state;
        address proposer;
    }

    event ProposalCreated(uint256 indexed id, address indexed proposer, ActionType actionType);
    event ProposalApproved(uint256 indexed id, address indexed approver);
    event ProposalQueued(uint256 indexed id, uint256 executeAfter);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);

    function propose(
        ActionType actionType,
        address token,
        address target,
        uint256 amount,
        bytes calldata callData
    ) external returns (uint256 proposalId);

    function approve(uint256 proposalId, bytes calldata signature) external;
    function queue(uint256 proposalId) external;
    function execute(uint256 proposalId) external;
    function cancel(uint256 proposalId) external;
    function getProposal(uint256 proposalId) external view returns (Proposal memory);
}
