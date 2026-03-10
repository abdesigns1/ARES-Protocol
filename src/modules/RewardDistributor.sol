// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IRewardDistributor.sol";
import "../libraries/MerkleLib.sol";

/// @title RewardDistributor
/// @notice Distributes contributor rewards using a Merkle tree.
///         Instead of sending tokens to thousands of addresses (expensive!),
///         we store one root hash and let users prove and claim their own rewards.
///
/// How it works:
///   1. Off-chain: build a Merkle tree with (address, amount, epoch) leaves
///   2. Store the root on-chain (cheap - just 32 bytes)
///   3. Each user submits their proof + amount to claim
///   4. Contract verifies the proof and pays out
///
/// Security:
///   - Bitmap tracks claims to prevent double-claiming
///   - Each epoch has its own root, so updating doesn't affect past claims
///   - Only governance can update roots
contract RewardDistributor is IRewardDistributor {
    using MerkleLib for bytes32[];

    // Who controls this contract
    address public immutable governance;

    // Token being distributed
    address public immutable rewardToken;

    // epoch => merkle root
    mapping(uint256 => bytes32) public merkleRoots;

    // epoch => user => claimed?
    // Using a nested mapping is cleaner than a bitmap for readability
    mapping(uint256 => mapping(address => bool)) private _claimed;

    // Current epoch number
    uint256 public currentEpoch;

    modifier onlyGovernance() {
        require(msg.sender == governance, "RewardDistributor: not governance");
        _;
    }

    constructor(address _governance, address _rewardToken) {
        require(_governance != address(0), "RewardDistributor: zero address");
        require(_rewardToken != address(0), "RewardDistributor: zero token");
        governance = _governance;
        rewardToken = _rewardToken;
    }

    /// @notice Update the Merkle root for a new distribution epoch.
    ///         Old epochs remain claimable - this just adds a new one.
    function updateRoot(bytes32 newRoot) external onlyGovernance {
        require(newRoot != bytes32(0), "RewardDistributor: empty root");
        currentEpoch++;
        merkleRoots[currentEpoch] = newRoot;
        emit RootUpdated(newRoot, currentEpoch);
    }

    /// @notice Claim rewards for a specific epoch using a Merkle proof.
    /// @param epoch  Which distribution epoch to claim from
    /// @param amount How many tokens the user is claiming
    /// @param proof  Merkle proof path (from off-chain tree)
    function claim(
        uint256 epoch,
        uint256 amount,
        bytes32[] calldata proof
    ) external {
        require(epoch > 0 && epoch <= currentEpoch, "RewardDistributor: invalid epoch");
        require(!_claimed[epoch][msg.sender], "RewardDistributor: already claimed");

        bytes32 root = merkleRoots[epoch];
        require(root != bytes32(0), "RewardDistributor: no root for epoch");

        // Build the leaf that should be in the tree
        bytes32 leaf = MerkleLib.leafHash(msg.sender, amount, epoch);

        // Verify the proof
        require(MerkleLib.verify(proof, root, leaf), "RewardDistributor: invalid proof");

        // Mark as claimed BEFORE transfer (checks-effects-interactions)
        _claimed[epoch][msg.sender] = true;

        emit RewardClaimed(msg.sender, amount, epoch);

        // Transfer the tokens - using low-level call to support tokens that don't return bool
        (bool success, bytes memory data) = rewardToken.call(
            abi.encodeWithSignature("transfer(address,uint256)", msg.sender, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "RewardDistributor: transfer failed"
        );
    }

    /// @notice Check if a user has claimed for a given epoch
    function hasClaimed(uint256 epoch, address user) external view returns (bool) {
        return _claimed[epoch][user];
    }
}
