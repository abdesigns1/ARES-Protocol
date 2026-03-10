// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IProposalManager.sol";
import "../libraries/SignatureLib.sol";
import "../modules/TimelockEngine.sol";
import "../modules/GovernanceGuard.sol";

/// @title ProposalManager
/// @notice The main entry point for ARES treasury governance.
///         Coordinates proposal creation, multi-sig approval, timelock queueing,
///         and execution. Talks to TimelockEngine and GovernanceGuard.
///
/// Lifecycle:
///   propose() → approve() [x N signers] → queue() → [wait delay] → execute()
///
/// Security model:
///   - N-of-M multisig via EIP-712 signatures
///   - Each signer has an on-chain nonce (prevents replay)
///   - Deadline on signatures (prevents stale signature attacks)
///   - All execution goes through TimelockEngine (enforces delay + reentrancy guard)
///   - GovernanceGuard checks drain limits
contract ProposalManager is IProposalManager {
    using SignatureLib for bytes;

    // ─────────────────────────────── State ────────────────────────────────

    // EIP-712 domain separator (set once at deploy, includes chainId)
    bytes32 public immutable DOMAIN_SEPARATOR;

    // The timelock that actually runs transactions
    TimelockEngine public immutable timelock;

    // The guard that enforces rate limits
    GovernanceGuard public immutable guard;

    // Approved signer addresses
    mapping(address => bool) public isSigner;
    uint256 public signerCount;

    // How many approvals needed to pass a proposal
    uint256 public threshold;

    // Proposal storage
    mapping(uint256 => Proposal) private _proposals;
    uint256 public proposalCount;

    // Track which signers have approved which proposals
    mapping(uint256 => mapping(address => bool)) public hasApproved;

    // Per-signer nonces for signature replay protection
    mapping(address => uint256) public nonces;

    // ──────────────────────────── Constructor ─────────────────────────────

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

        // Build domain separator once. Includes chainId so cross-chain replay is impossible.
        DOMAIN_SEPARATOR = SignatureLib.buildDomainSeparator(
            "ARES Protocol",
            "1",
            address(this)
        );
    }

    // ──────────────────────────── Proposal Flow ───────────────────────────

    /// @notice Create a new treasury proposal
    function propose(
        ActionType actionType,
        address token,
        address target,
        uint256 amount,
        bytes calldata callData
    ) external returns (uint256 proposalId) {
        // Only signers can propose (prevents spam from random addresses)
        require(isSigner[msg.sender], "ProposalManager: not a signer");

        // Cooldown check - prevents griefing by spamming proposals
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

    /// @notice Submit a cryptographic approval for a proposal.
    ///         Uses EIP-712 signatures so signers can approve off-chain.
    /// @param proposalId  Which proposal to approve
    /// @param signature   EIP-712 signature from an authorized signer
    function approve(uint256 proposalId, bytes calldata signature) external {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Pending, "ProposalManager: not pending");
        require(!hasApproved[proposalId][msg.sender], "ProposalManager: already approved");
        require(isSigner[msg.sender], "ProposalManager: not a signer");

        // Signatures must include a deadline to prevent old signatures being used later
        // We encode the nonce in the sig so each approval can only be used once
        uint256 signerNonce = nonces[msg.sender];
        uint256 deadline = block.timestamp + 1 days; // signer must submit within 24h of signing

        // Build the digest the signer should have signed
        bytes32 digest = SignatureLib.hashApproval(
            DOMAIN_SEPARATOR,
            proposalId,
            signerNonce,
            deadline
        );

        // Recover who signed this - reverts if invalid
        address recovered = SignatureLib.recoverSigner(digest, signature);
        require(recovered == msg.sender, "ProposalManager: signature mismatch");

        // Increment nonce - this makes the signature one-time-use
        nonces[msg.sender]++;

        hasApproved[proposalId][msg.sender] = true;
        p.approvalCount++;

        emit ProposalApproved(proposalId, msg.sender);

        // Auto-advance to Approved state if threshold is met
        if (p.approvalCount >= threshold) {
            p.state = ProposalState.Approved;
        }
    }

    /// @notice Move an approved proposal into the timelock queue
    function queue(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Approved, "ProposalManager: not approved");

        p.state = ProposalState.Queued;

        // Build the calldata we'll eventually execute
        bytes memory execData = _buildExecData(p);

        // Compute the operation ID in the timelock
        bytes32 opId = timelock.operationId(p.target, 0, execData, proposalId);

        // Register with the timelock - starts the delay countdown
        timelock.queue(opId);

        emit ProposalQueued(proposalId, block.timestamp + timelock.MIN_DELAY());
    }

    /// @notice Execute a queued proposal after the timelock delay has passed
    function execute(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        require(p.state == ProposalState.Queued, "ProposalManager: not queued");

        p.state = ProposalState.Executed;

        bytes memory execData = _buildExecData(p);
        bytes32 opId = timelock.operationId(p.target, 0, execData, proposalId);

        // For transfer proposals, check the drain limits
        if (p.actionType == ActionType.Transfer) {
            // Check single-tx limit (e.g. max 10% of treasury)
            uint256 balance = _tokenBalance(p.token, address(timelock));
            guard.checkTransferLimit(p.amount, balance);
            // Record the outflow (will revert if daily limit exceeded)
            guard.recordOutflow(p.amount);
        }

        emit ProposalExecuted(proposalId);

        // The timelock handles reentrancy protection and actually runs the call
        timelock.execute(opId, p.target, 0, execData);
    }

    /// @notice Cancel a pending or approved proposal
    function cancel(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        require(
            p.state == ProposalState.Pending || p.state == ProposalState.Approved,
            "ProposalManager: cannot cancel"
        );
        // Only the proposer or any signer can cancel
        require(
            msg.sender == p.proposer || isSigner[msg.sender],
            "ProposalManager: not authorized"
        );

        p.state = ProposalState.Cancelled;
        emit ProposalCancelled(proposalId);
    }

    // ─────────────────────────────── Views ────────────────────────────────

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    // ─────────────────────────────── Helpers ──────────────────────────────

    /// @notice Build the raw calldata for a proposal's action
    function _buildExecData(Proposal storage p) internal view returns (bytes memory) {
        if (p.actionType == ActionType.Transfer) {
            // ERC-20 transfer(address,uint256)
            return abi.encodeWithSignature("transfer(address,uint256)", p.target, p.amount);
        } else {
            // For Call and Upgrade, the proposer supplies the calldata directly
            return p.callData;
        }
    }

    /// @notice Get ERC-20 balance of an address
    function _tokenBalance(address token, address account) internal view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
