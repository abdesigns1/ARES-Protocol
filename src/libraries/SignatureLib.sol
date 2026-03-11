// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


library SignatureLib {
    
    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

   
    bytes32 public constant APPROVAL_TYPEHASH = keccak256(
        "ApproveProposal(uint256 proposalId,uint256 nonce,uint256 deadline)"
    );

    function buildDomainSeparator(
        string memory name,
        string memory version,
        address verifyingContract
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            block.chainid,         
            verifyingContract     
        ));
    }

   
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
    
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

 
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
