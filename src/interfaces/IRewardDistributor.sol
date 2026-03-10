// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


interface IRewardDistributor {
    event RootUpdated(bytes32 indexed newRoot, uint256 indexed epoch);
    event RewardClaimed(address indexed user, uint256 amount, uint256 indexed epoch);

    function updateRoot(bytes32 newRoot) external;

    function claim(
        uint256 epoch,
        uint256 amount,
        bytes32[] calldata proof
    ) external;

    function hasClaimed(uint256 epoch, address user) external view returns (bool);
}
