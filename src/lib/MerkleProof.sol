// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Sorted-pair Merkle verification, byte-for-byte the rule of OpenZeppelin's MerkleProof, so trees
/// built with the OpenZeppelin merkle-tree package (StandardMerkleTree) verify here unchanged.
library MerkleProof {
    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            h = h < p ? _pair(h, p) : _pair(p, h);
        }
        return h == root;
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32 v) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            v := keccak256(0x00, 0x40)
        }
    }
}
