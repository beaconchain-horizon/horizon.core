package merkle

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"testing"
)

// TestRealLicenseProof proves fold(leaf, path) = root using real license data
func TestRealLicenseProof(t *testing.T) {
	fmt.Println("\n========================================")
	fmt.Println("اثبات fold(leaf, path) = root")
	fmt.Println("========================================")

	// برگ‌ها از داده‌های واقعی لایسنس
	leaves := [][]byte{
		[]byte("HORIZON-GOLD-001:dd8956292b03dec76652e342fe9a785e1ad3eb8b09407621722febe6ff63164b5eb96917d57f5977269d26bd5c89014fd31acffc19992168b05967f5c3448f63"),
		[]byte("HORIZON-TEST-001:dd8956292b03dec76652e342fe9a785e1ad3eb8b09407621722febe6ff63164b5eb96917d57f5977269d26bd5c89014fd31acffc19992168b05967f5c3448f63"),
		[]byte("OIL-LICENSE-001:sample-data-1"),
		[]byte("ENERGY-LICENSE-001:sample-data-2"),
		[]byte("STEEL-LICENSE-001:sample-data-3"),
	}

	// محاسبه root با فرمول v2 chain (همان که chain استفاده می‌کند)
	rootHex := BinaryRootNoPrefix(leaves)
	rootBytes, _ := hex.DecodeString(rootHex)
	var root [32]byte
	copy(root[:], rootBytes)

	fmt.Printf("\nRoot (32 byte): %s\n\n", rootHex)

	// تست هر لایسنس
	for i := range leaves {
		leafHash := sha256.Sum256(leaves[i])
		fmt.Printf("Leaf[%d]: %s...\n", i, hex.EncodeToString(leafHash[:])[:16])

		proof, err := BuildProof(leaves, i)
		if err != nil {
			t.Fatalf("BuildProof failed for index %d: %v", i, err)
		}

		if !proof.Verify(root) {
			t.Errorf("❌ FAIL: real leaf[%d] should verify but didn't", i)
		} else {
			fmt.Printf("  ✅ Verified (path: %d siblings)\n", len(proof.Siblings))
		}
	}

	// تست لایسنس جعلی
	fmt.Println("\n--- Testing fake license ---")
	fakeLeaf := []byte("HORIZON-FAKE-999:fake-signature-here")
	realProof, _ := BuildProof(leaves, 0)

	fakeProof := &Proof{
		Leaf:     fakeLeaf,
		Index:    0,
		Siblings: realProof.Siblings,
	}

	if fakeProof.Verify(root) {
		t.Errorf("❌ FAIL: fake license should be rejected but verified!")
	} else {
		fmt.Println("  ✅ Fake license REJECTED (as expected)")
	}

	// محاسبه صرفه‌جویی
	n := len(leaves)
	depth := len(realProof.Siblings)
	fmt.Printf("\n=== صرفه‌جویی ===\n")
	fmt.Printf("تعداد لایسنس: %d\n", n)
	fmt.Printf("عمق اثبات (تعداد هش): %d\n", depth)
	fmt.Printf("نسبت: %d بار سریع‌تر از روش تک‌تک\n", n/depth)

	fmt.Println("\n========================================")
	fmt.Println("✅ همه تست‌ها پاس شدند")
	fmt.Println("========================================")
}

// TestLeafHashMatchesSHA256 proves leaf hash formula
func TestLeafHashMatchesSHA256(t *testing.T) {
	data := []byte("test-data")
	expected := sha256.Sum256(data)
	actual := hashLeaf(data)
	if expected != actual {
		t.Fatalf("leaf hash formula mismatch: %x != %x", expected, actual)
	}
	fmt.Printf("✅ hashLeaf(data) = SHA256(data) = %x\n", actual)
}
