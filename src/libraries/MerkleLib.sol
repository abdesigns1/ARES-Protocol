// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MerkleLib
/// @notice Verifies Merkle proofs for the reward distribution system.
///         Merkle trees let us store one small root hash on-chain while
///         still being able to prove any leaf belongs to the tree.
library MerkleLib {
    /// @notice Verify a Merkle proof.
    /// @param proof  Array of sibling hashes going up the tree
    /// @param root   The expected root hash (stored on-chain)
    /// @param leaf   Hash of the data we're proving (e.g. keccak256(user, amount))
    function verify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computed = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            // Sort the pair so the tree is consistent regardless of which
            // side the sibling is on. This is the standard approach.
            if (computed <= sibling) {
                computed = keccak256(abi.encodePacked(computed, sibling));
            } else {
                computed = keccak256(abi.encodePacked(sibling, computed));
            }
        }

        return computed == root;
    }

    /// @notice Build a leaf hash for a reward claim
    function leafHash(address user, uint256 amount, uint256 epoch) internal pure returns (bytes32) {
        // Double hashing prevents second preimage attacks on the leaf nodes
        return keccak256(abi.encodePacked(keccak256(abi.encodePacked(user, amount, epoch))));
    }
}
