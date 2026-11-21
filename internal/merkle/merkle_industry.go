package merkle

import (
	"crypto/sha256"
	"errors"
)

// IndustryNode represents a leaf with an industry identifier
type IndustryNode struct {
	IndustryID string // e.g., "banking", "oil", "energy"
	Data       []byte // hash of transaction or license
}

// BuildTernaryTree builds a ternary Merkle tree from industry nodes and returns the root
func BuildTernaryTree(nodes []IndustryNode) ([]byte, error) {
	if len(nodes) == 0 {
		return nil, errors.New("no nodes provided")
	}

	// Step 1: Hash each node's data with its industry ID
	leaves := make([][]byte, len(nodes))
	for i, n := range nodes {
		combined := append([]byte(n.IndustryID), n.Data...)
		hash := sha256.Sum256(combined)
		leaves[i] = hash[:]
	}

	// Step 2: Build the ternary tree
	currentLevel := leaves
	for len(currentLevel) > 1 {
		nextLevel := make([][]byte, 0, (len(currentLevel)+2)/3)
		for i := 0; i < len(currentLevel); i += 3 {
			end := i + 3
			if end > len(currentLevel) {
				end = len(currentLevel)
			}
			combined := []byte{}
			for _, h := range currentLevel[i:end] {
				combined = append(combined, h...)
			}
			hash := sha256.Sum256(combined)
			nextLevel = append(nextLevel, hash[:])
		}
		currentLevel = nextLevel
	}

	return currentLevel[0], nil
}
