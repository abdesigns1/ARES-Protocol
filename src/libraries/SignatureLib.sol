// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SignatureLib
/// @notice Handles EIP-712 structured signature creation and verification.
///         We use EIP-712 because it shows users a human-readable message
///         in their wallet instead of just a raw hash - safer and clearer.
library SignatureLib {
    // EIP-712 domain typehash - this uniquely identifies our protocol
    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // The type structure for approving a proposal
    bytes32 public constant APPROVAL_TYPEHASH = keccak256(
        "ApproveProposal(uint256 proposalId,uint256 nonce,uint256 deadline)"
    );

    /// @notice Build the domain separator. This prevents cross-chain replay attacks
    ///         because chainId and verifyingContract are baked in.
    function buildDomainSeparator(
        string memory name,
        string memory version,
        address verifyingContract
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            block.chainid,         // changes per chain - prevents cross-chain replay
            verifyingContract      // changes per contract - prevents domain collision
        ));
    }

    /// @notice Hash a proposal approval message following EIP-712
    function hashApproval(
        bytes32 domainSeparator,
        uint256 proposalId,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            APPROVAL_TYPEHASH,
            proposalId,
            nonce,
            deadline
        ));
        // The \x19\x01 prefix is EIP-712 standard - prevents hash collisions with other data
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @notice Recover signer from a signature. Checks for signature malleability
    ///         by rejecting high-s values (a known ECDSA attack vector).
    function recoverSigner(bytes32 digest, bytes memory sig) internal pure returns (address) {
        require(sig.length == 65, "SignatureLib: bad sig length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }

        // Reject malleable signatures - s must be in lower half of curve order
        // This is the same check OpenZeppelin uses
        require(
            uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "SignatureLib: malleable signature"
        );

        require(v == 27 || v == 28, "SignatureLib: invalid v value");

        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0), "SignatureLib: ecrecover failed");

        return recovered;
    }
}
