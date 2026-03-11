// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


library MerkleLib {
    function verify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computed = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
          
            if (computed <= sibling) {
                computed = keccak256(abi.encodePacked(computed, sibling));
            } else {
                computed = keccak256(abi.encodePacked(sibling, computed));
            }
        }

        return computed == root;
    }

 
    function leafHash(address user, uint256 amount, uint256 epoch) internal pure returns (bytes32) {
    
        return keccak256(abi.encodePacked(keccak256(abi.encodePacked(user, amount, epoch))));
    }
}
