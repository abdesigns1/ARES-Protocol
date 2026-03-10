// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


contract TimelockEngine {
   
    uint256 public constant MIN_DELAY = 2 days;
  
    uint256 public constant GRACE_PERIOD = 7 days;

   
    address public immutable governance;


    mapping(bytes32 => uint256) public queuedAt;


    uint256 private _lock;

    event Queued(bytes32 indexed opId, uint256 executeAfter);
    event Executed(bytes32 indexed opId);
    event Cancelled(bytes32 indexed opId);

    modifier onlyGovernance() {
        require(msg.sender == governance, "TimelockEngine: not governance");
        _;
    }


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


    function operationId(
        address target,
        uint256 value,
        bytes memory data,
        uint256 proposalId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, proposalId));
    }

   
    function queue(bytes32 opId) external onlyGovernance {
        require(queuedAt[opId] == 0, "TimelockEngine: already queued");
        uint256 readyTime = block.timestamp + MIN_DELAY;
        queuedAt[opId] = readyTime;
        emit Queued(opId, readyTime);
    }


    function execute(
        bytes32 opId,
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyGovernance nonReentrant returns (bytes memory) {
        uint256 readyTime = queuedAt[opId];
        require(readyTime != 0, "TimelockEngine: not queued");
        require(block.timestamp >= readyTime, "TimelockEngine: too early");
  
        require(block.timestamp <= readyTime + GRACE_PERIOD, "TimelockEngine: expired");

     
        delete queuedAt[opId];

        emit Executed(opId);


        (bool success, bytes memory result) = target.call{value: value}(data);
        require(success, "TimelockEngine: execution failed");

        return result;
    }


    function cancel(bytes32 opId) external onlyGovernance {
        require(queuedAt[opId] != 0, "TimelockEngine: not queued");
        delete queuedAt[opId];
        emit Cancelled(opId);
    }


    function isReady(bytes32 opId) external view returns (bool) {
        uint256 readyTime = queuedAt[opId];
        if (readyTime == 0) return false;
        return block.timestamp >= readyTime && block.timestamp <= readyTime + GRACE_PERIOD;
    }
}
