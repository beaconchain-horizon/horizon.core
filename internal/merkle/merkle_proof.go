package merkle

import (
	"crypto/sha256"
)

// MerkleProof holds the sibling hashes needed to verify a leaf
type MerkleProof struct {
	Leaf  []byte
	Path  [][]byte
	Index int
}

// VerifyProof verifies that a leaf is part of the tree with the given root
func VerifyProof(proof MerkleProof, root []byte) bool {
	current := proof.Leaf
	index := proof.Index

	for _, sibling := range proof.Path {
		var combined []byte
		switch index % 3 {
		case 0:
			combined = append(current, sibling...)
		case 1:
			combined = append(sibling, current...)
		case 2:
			combined = append(sibling, current...)
		}
		hash := sha256.Sum256(combined)
		current = hash[:]
		index /= 3
	}

	return string(current) == string(root)
}
