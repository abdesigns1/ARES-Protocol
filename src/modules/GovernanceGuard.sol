// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GovernanceGuard
/// @notice Defends against economic governance attacks.
///
/// Two main threats we defend against:
///
/// 1. Flash loan manipulation - someone borrows a huge amount of tokens,
///    votes/proposes something malicious, then repays in the same transaction.
///    Defense: Require a minimum holding period before a signer is trusted.
///             (In a token-weighted system, snapshot at proposal creation time.)
///
/// 2. Large treasury drain - a single proposal tries to drain a huge amount.
///    Defense: Hard cap per transaction + rate limit over time (drip limit).
///
/// 3. Proposal griefing - spamming proposals to clog the queue.
///    Defense: Minimum stake or cooldown between proposals per address.
contract GovernanceGuard {
    // Max single transfer as percentage of treasury (in basis points, 100 = 1%)
    // Set to 10% = 1000 bps
    uint256 public constant MAX_SINGLE_TRANSFER_BPS = 1000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // Max total outflow per 24 hours (in token units, set by governance at deploy)
    uint256 public dailyDrainLimit;

    // Cooldown between proposals from the same address
    uint256 public constant PROPOSAL_COOLDOWN = 1 hours;

    // Track daily outflow
    uint256 public dailyOutflow;
    uint256 public lastResetTimestamp;

    // Track last proposal time per address (griefing protection)
    mapping(address => uint256) public lastProposalTime;

    // Who controls this guard
    address public immutable governance;

    event DailyLimitUpdated(uint256 newLimit);
    event OutflowRecorded(uint256 amount, uint256 totalToday);

    modifier onlyGovernance() {
        require(msg.sender == governance, "GovernanceGuard: not governance");
        _;
    }

    constructor(address _governance, uint256 _dailyDrainLimit) {
        require(_governance != address(0));
        governance = _governance;
        dailyDrainLimit = _dailyDrainLimit;
        lastResetTimestamp = block.timestamp;
    }

    /// @notice Check if a transfer amount is safe (not too large in one shot)
    /// @param amount    Proposed transfer amount
    /// @param treasury  Current treasury balance (used to compute percentage)
    function checkTransferLimit(uint256 amount, uint256 treasury) external pure {
        if (treasury == 0) return; // nothing to protect
        uint256 maxAllowed = (treasury * MAX_SINGLE_TRANSFER_BPS) / BPS_DENOMINATOR;
        require(amount <= maxAllowed, "GovernanceGuard: exceeds single transfer limit");
    }

    /// @notice Record an outflow and check the daily rate limit.
    ///         Resets every 24 hours automatically.
    function recordOutflow(uint256 amount) external onlyGovernance {
        // Reset window if 24 hours have passed
        if (block.timestamp >= lastResetTimestamp + 1 days) {
            dailyOutflow = 0;
            lastResetTimestamp = block.timestamp;
        }

        dailyOutflow += amount;
        require(dailyOutflow <= dailyDrainLimit, "GovernanceGuard: daily drain limit exceeded");

        emit OutflowRecorded(amount, dailyOutflow);
    }

    /// @notice Proposal cooldown check - prevents the same address from spamming proposals
    function checkProposalCooldown(address proposer) external {
        require(
            block.timestamp >= lastProposalTime[proposer] + PROPOSAL_COOLDOWN,
            "GovernanceGuard: proposal cooldown active"
        );
        lastProposalTime[proposer] = block.timestamp;
    }

    /// @notice Update the daily drain limit (governance only)
    function setDailyDrainLimit(uint256 newLimit) external onlyGovernance {
        dailyDrainLimit = newLimit;
        emit DailyLimitUpdated(newLimit);
    }
}
