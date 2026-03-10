// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


contract GovernanceGuard {
   
    uint256 public constant MAX_SINGLE_TRANSFER_BPS = 1000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

  
    uint256 public dailyDrainLimit;


    uint256 public constant PROPOSAL_COOLDOWN = 1 hours;


    uint256 public dailyOutflow;
    uint256 public lastResetTimestamp;

    mapping(address => uint256) public lastProposalTime;


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

 
    function checkTransferLimit(uint256 amount, uint256 treasury) external pure {
        if (treasury == 0) return; 
        uint256 maxAllowed = (treasury * MAX_SINGLE_TRANSFER_BPS) / BPS_DENOMINATOR;
        require(amount <= maxAllowed, "GovernanceGuard: exceeds single transfer limit");
    }


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


    function checkProposalCooldown(address proposer) external {
        require(
            block.timestamp >= lastProposalTime[proposer] + PROPOSAL_COOLDOWN,
            "GovernanceGuard: proposal cooldown active"
        );
        lastProposalTime[proposer] = block.timestamp;
    }


    function setDailyDrainLimit(uint256 newLimit) external onlyGovernance {
        dailyDrainLimit = newLimit;
        emit DailyLimitUpdated(newLimit);
    }
}
