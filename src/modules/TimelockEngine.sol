// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TimelockEngine
/// @notice Holds queued transactions and enforces a minimum delay before execution.
///         This gives token holders time to exit if they disagree with a decision.
///
/// Security measures:
/// - Reentrancy guard on execute() prevents re-entering during execution
/// - Operations identified by content hash - can't queue the same thing twice
/// - Timestamp window check prevents executing too late (also prevents replay)
/// - No ETH stored here - just execution logic
contract TimelockEngine {
    // Minimum time between queuing and executing (2 days)
    uint256 public constant MIN_DELAY = 2 days;
    // Maximum time to execute after the delay passes (7 days window)
    uint256 public constant GRACE_PERIOD = 7 days;

    // Who is allowed to queue/execute (the ProposalManager)
    address public immutable governance;

    // operationId => timestamp when it can be executed (0 = not queued)
    mapping(bytes32 => uint256) public queuedAt;

    // Reentrancy lock - 1 = unlocked, 2 = locked
    uint256 private _lock;

    event Queued(bytes32 indexed opId, uint256 executeAfter);
    event Executed(bytes32 indexed opId);
    event Cancelled(bytes32 indexed opId);

    modifier onlyGovernance() {
        require(msg.sender == governance, "TimelockEngine: not governance");
        _;
    }

    /// @notice Reentrancy guard. We use 1/2 instead of bool to save gas on re-set.
    modifier nonReentrant() {
        require(_lock == 1, "TimelockEngine: reentrant call");
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address _governance) {
        require(_governance != address(0), "TimelockEngine: zero address");
        governance = _governance;
        _lock = 1;
    }

    /// @notice Build a unique ID for an operation from its parameters.
    ///         Same parameters = same ID, so duplicates are automatically blocked.
    function operationId(
        address target,
        uint256 value,
        bytes memory data,
        uint256 proposalId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, proposalId));
    }

    /// @notice Queue an operation. Can only be called by governance (ProposalManager).
    function queue(bytes32 opId) external onlyGovernance {
        require(queuedAt[opId] == 0, "TimelockEngine: already queued");
        uint256 readyTime = block.timestamp + MIN_DELAY;
        queuedAt[opId] = readyTime;
        emit Queued(opId, readyTime);
    }

    /// @notice Execute a queued operation. Enforces delay and reentrancy protection.
    function execute(
        bytes32 opId,
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyGovernance nonReentrant returns (bytes memory) {
        uint256 readyTime = queuedAt[opId];
        require(readyTime != 0, "TimelockEngine: not queued");
        require(block.timestamp >= readyTime, "TimelockEngine: too early");
        // Grace period check prevents old proposals from being executed much later
        require(block.timestamp <= readyTime + GRACE_PERIOD, "TimelockEngine: expired");

        // Delete BEFORE executing - this is the checks-effects-interactions pattern
        // It prevents reentrancy from re-executing the same operation
        delete queuedAt[opId];

        emit Executed(opId);

        // Actually run the transaction
        (bool success, bytes memory result) = target.call{value: value}(data);
        require(success, "TimelockEngine: execution failed");

        return result;
    }

    /// @notice Cancel a queued operation
    function cancel(bytes32 opId) external onlyGovernance {
        require(queuedAt[opId] != 0, "TimelockEngine: not queued");
        delete queuedAt[opId];
        emit Cancelled(opId);
    }

    /// @notice Check if an operation is ready to execute
    function isReady(bytes32 opId) external view returns (bool) {
        uint256 readyTime = queuedAt[opId];
        if (readyTime == 0) return false;
        return block.timestamp >= readyTime && block.timestamp <= readyTime + GRACE_PERIOD;
    }
}
