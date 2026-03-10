// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


interface IProposalManager {

    enum ProposalState {
        Pending,    
        Approved,   
        Queued,     
        Executed,   
        Cancelled   
    }


    enum ActionType {
        Transfer,  
        Call,       
        Upgrade     
    }


    struct Proposal {
        uint256 id;
        ActionType actionType;
        address token;        
        address target;        
        uint256 amount;       
        bytes callData;        
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
