// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProposalManager.sol";
import "../libraries/SignatureLib.sol";
import "../modules/TimelockEngine.sol";
import "../modules/GovernanceGuard.sol";

contract ProposalManager is IProposalManager {
    using SignatureLib for bytes;


    bytes32 public immutable DOMAIN_SEPARATOR;


    TimelockEngine public immutable timelock;


    GovernanceGuard public immutable guard;

    mapping(address => bool) public isSigner;
    uint256 public signerCount;


    uint256 public threshold;


    mapping(uint256 => Proposal) private _proposals;
    uint256 public proposalCount;


    mapping(uint256 => mapping(address => bool)) public hasApproved;


    mapping(address => uint256) public nonces;

    //Constructor 

    constructor(
        address[] memory _signers,
        uint256 _threshold,
        address _timelock,
        address _guard
    ) {
        require(_signers.length >= _threshold, "ProposalManager: threshold too high");
        require(_threshold >= 2, "ProposalManager: threshold must be >= 2");
        require(_timelock != address(0), "ProposalManager: zero timelock");
        require(_guard != address(0), "ProposalManager: zero guard");

        for (uint256 i = 0; i < _signers.length; i++) {
            require(_signers[i] != address(0), "ProposalManager: zero signer");
            require(!isSigner[_signers[i]], "ProposalManager: duplicate signer");
            isSigner[_signers[i]] = true;
        }
        signerCount = _signers.length;
        threshold = _threshold;

        timelock = TimelockEngine(_timelock);
        guard = GovernanceGuard(_guard);

    
        DOMAIN_SEPARATOR = SignatureLib.buildDomainSeparator(
            "ARES Protocol",
            "1",
            address(this)
        );
    }

    // Proposal Flow 

    function propose(
        ActionType actionType,
        address token,
        address target,
        uint256 amount,
        bytes calldata callData
    ) external returns (uint256 proposalId) {
    
        require(isSigner[msg.sender], "ProposalManager: not a signer");

     
        guard.checkProposalCooldown(msg.sender);

        require(target != address(0), "ProposalManager: zero target");
        if (actionType == ActionType.Transfer) {
            require(amount > 0, "ProposalManager: zero amount");
        }

        proposalId = ++proposalCount;

        _proposals[proposalId] = Proposal({
            id: proposalId,
            actionType: actionType,
            token: token,
            target: target,
            amount: amount,
            callData: callData,
            createdAt: block.timestamp,
            approvalCount: 0,
            state: ProposalState.Pending,
            proposer: msg.sender
        });

        emit ProposalCreated(proposalId, msg.sender, actionType);
    }


    function approve(uint256 proposalId, bytes calldata signature) external {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Pending, "ProposalManager: not pending");
        require(!hasApproved[proposalId][msg.sender], "ProposalManager: already approved");
        require(isSigner[msg.sender], "ProposalManager: not a signer");

        
        uint256 signerNonce = nonces[msg.sender];
        uint256 deadline = block.timestamp + 1 days;

  
        bytes32 digest = SignatureLib.hashApproval(
            DOMAIN_SEPARATOR,
            proposalId,
            signerNonce,
            deadline
        );

    
        address recovered = SignatureLib.recoverSigner(digest, signature);
        require(recovered == msg.sender, "ProposalManager: signature mismatch");

  
        nonces[msg.sender]++;

        hasApproved[proposalId][msg.sender] = true;
        p.approvalCount++;

        emit ProposalApproved(proposalId, msg.sender);

    
        if (p.approvalCount >= threshold) {
            p.state = ProposalState.Approved;
        }
    }


    function queue(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Approved, "ProposalManager: not approved");

        p.state = ProposalState.Queued;

     
        bytes memory execData = _buildExecData(p);


        bytes32 opId = timelock.operationId(p.target, 0, execData, proposalId);


        timelock.queue(opId);

        emit ProposalQueued(proposalId, block.timestamp + timelock.MIN_DELAY());
    }


    function execute(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Queued, "ProposalManager: not queued");

        p.state = ProposalState.Executed;

        bytes memory execData = _buildExecData(p);
        bytes32 opId = timelock.operationId(p.target, 0, execData, proposalId);


        if (p.actionType == ActionType.Transfer) {
            uint256 balance = _tokenBalance(p.token, address(timelock));
            guard.checkTransferLimit(p.amount, balance);
            guard.recordOutflow(p.amount);
        }

        emit ProposalExecuted(proposalId);

     
        timelock.execute(opId, p.target, 0, execData);
    }


    function cancel(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        require(
            p.state == ProposalState.Pending || p.state == ProposalState.Approved,
            "ProposalManager: cannot cancel"
        );

        require(
            msg.sender == p.proposer || isSigner[msg.sender],
            "ProposalManager: not authorized"
        );

        p.state = ProposalState.Cancelled;
        emit ProposalCancelled(proposalId);
    }



    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }



    function _buildExecData(Proposal storage p) internal view returns (bytes memory) {
        if (p.actionType == ActionType.Transfer) {

            return abi.encodeWithSignature("transfer(address,uint256)", p.target, p.amount);
        } else {

            return p.callData;
        }
    }

    function _tokenBalance(address token, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
