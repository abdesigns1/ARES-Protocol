// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IRewardDistributor.sol";
import "../libraries/MerkleLib.sol";


contract RewardDistributor is IRewardDistributor {
    using MerkleLib for bytes32[];

    address public immutable governance;

    address public immutable rewardToken;
   
    mapping(uint256 => bytes32) public merkleRoots;
  
    mapping(uint256 => mapping(address => bool)) private _claimed;

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

  

    function updateRoot(bytes32 newRoot) external onlyGovernance {
        require(newRoot != bytes32(0), "RewardDistributor: empty root");
        currentEpoch++;
        merkleRoots[currentEpoch] = newRoot;
        emit RootUpdated(newRoot, currentEpoch);
    }


    function claim(
        uint256 epoch,
        uint256 amount,
        bytes32[] calldata proof
    ) external {
        require(epoch > 0 && epoch <= currentEpoch, "RewardDistributor: invalid epoch");
        require(!_claimed[epoch][msg.sender], "RewardDistributor: already claimed");

        bytes32 root = merkleRoots[epoch];
        require(root != bytes32(0), "RewardDistributor: no root for epoch");

    
        bytes32 leaf = MerkleLib.leafHash(msg.sender, amount, epoch);


        require(MerkleLib.verify(proof, root, leaf), "RewardDistributor: invalid proof");

       
        _claimed[epoch][msg.sender] = true;

        emit RewardClaimed(msg.sender, amount, epoch);


        (bool success, bytes memory data) = rewardToken.call(
            abi.encodeWithSignature("transfer(address,uint256)", msg.sender, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "RewardDistributor: transfer failed"
        );
    }


    function hasClaimed(uint256 epoch, address user) external view returns (bool) {
        return _claimed[epoch][user];
    }
}
