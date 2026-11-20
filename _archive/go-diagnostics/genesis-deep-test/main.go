package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"time"

	"horizon-core/internal/crypto"
)

func main() {
	genesisHash := "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
	zeros := "0000000000000000000000000000000000000000000000000000000000000000"
	sigHex := "afac005b7f7565fe69ca9d58dabdf0a3914fce0854ee05f214d788e9e478b02f7c82a05b35d1456b605a128e4074ed9d3c4e55932cc7b368516c0681d236face"
	pubHex := "04cf6aaaba8e7a6fddde63a2e2588553dc95503d2de6b2a5c78f4a30a0b91b0aca4d28d06fc1ccbaf730abe1dcda7c29726dab18008353b521c9253c04b1641214"

	pub, err := crypto.Secp256k1PublicKeyFromHex(pubHex)
	if err != nil {
		fmt.Println("❌ pubkey:", err)
		return
	}
	sigBytes, _ := hex.DecodeString(sigHex)
	hashBytes, _ := hex.DecodeString(genesisHash)

	jsonTs, _ := time.Parse(time.RFC3339Nano, "2026-10-31T18:43:01.8552524Z")
	createdTs, _ := time.Parse(time.RFC3339Nano, "2026-11-13T09:13:31.101616+03:30")

	fmt.Println("══════════ ۱۲ فرضیه امضای جنسیس ══════════\n")

	found := false

	// [1] VerifyHashRS directly on hash bytes
	fmt.Print("[1] VerifyHashRS(pub, hash_bytes_32, sig): ")
	if crypto.VerifyHashRS(pub, hashBytes, sigBytes) {
		fmt.Println("✅ MATCH!")
		found = true
	} else {
		fmt.Println("❌")
	}

	// [2] VerifyData on hash hex string
	fmt.Print("[2] VerifyData(pub, hex_string_of_hash, sig): ")
	if ok, _ := crypto.VerifyData(pub, []byte(genesisHash), sigHex); ok {
		fmt.Println("✅ MATCH!")
		found = true
	} else {
		fmt.Println("❌")
	}

	// [3] VerifyHashRS on sha256(hex_string)
	fmt.Print("[3] VerifyHashRS(pub, sha256(hex_string), sig): ")
	h := sha256.Sum256([]byte(genesisHash))
	if crypto.VerifyHashRS(pub, h[:], sigBytes) {
		fmt.Println("✅ MATCH!")
		found = true
	} else {
		fmt.Println("❌")
	}

	// [4] canonical message with various timestamps
	fmt.Println("\n[4] canonical 'HZBLK1|0|prev|merkle|ts' variations:")
	for _, ts := range []struct {
		name string
		v    int64
	}{
		{"DB=1794246431", 1794246431},
		{"JSON", jsonTs.Unix()},
		{"created_at", createdTs.Unix()},
		{"zero", 0},
	} {
		for _, merkle := range []string{"", genesisHash} {
			m := fmt.Sprintf("HZBLK1|0|%s|%s|%d", zeros, merkle, ts.v)
			ok, _ := crypto.VerifyData(pub, []byte(m), sigHex)
			if ok {
				fmt.Printf("  ✅ ts=%s merkle=%q → MATCH!\n", ts.name, merkle)
				found = true
			}
		}
	}
	if !found {
		fmt.Println("  (همه false)")
	}

	// [5] Without prefix HZBLK1
	fmt.Println("\n[5] بدون پیشوند HZBLK1:")
	for _, ts := range []int64{1794246431, jsonTs.Unix(), createdTs.Unix()} {
		m := fmt.Sprintf("0|%s||%d", zeros, ts)
		ok, _ := crypto.VerifyData(pub, []byte(m), sigHex)
		if ok {
			fmt.Println("  ✅ MATCH!")
			found = true
		}
	}
	if !found {
		fmt.Println("  (همه false)")
	}

	// [6] Canonical JSON
	fmt.Println("\n[6] canonical JSON variants:")
	for _, v := range []string{`"` + genesisHash + `"`, `{"hash":"` + genesisHash + `"}`} {
		ok, _ := crypto.VerifyData(pub, []byte(v), sigHex)
		if ok {
			fmt.Println("  ✅ MATCH!")
			found = true
		}
	}
	j, _ := json.Marshal(map[string]string{
		"genesis_hash": genesisHash, "previous_hash": zeros,
	})
	ok, _ := crypto.VerifyData(pub, j, sigHex)
	if ok {
		fmt.Println("  ✅ MATCH!")
		found = true
	} else {
		fmt.Println("  (همه false)")
	}

	// [7] Sign Block #1 with same formulas — for cross-check
	fmt.Println("\n══════════ Block #1 signature tests ══════════")
	block1Hash := "f981652e6c25945a2655b83f7536524441422bdeb7b9742a30a5256cd637ceba"
	block1Sig := "19f1b5674299e9625595f538c6c439cb77562a09246f13221b24ef62faa3ddb1433b4a8058424e31a6ece3577b755eed4543c7993c0261e0c977bf45994bd335"
	b1Bytes, _ := hex.DecodeString(block1Hash)
	b1SigBytes, _ := hex.DecodeString(block1Sig)

	fmt.Print("[1] VerifyHashRS on block1_hash_bytes: ")
	if crypto.VerifyHashRS(pub, b1Bytes, b1SigBytes) {
		fmt.Println("✅")
		found = true
	} else {
		fmt.Println("❌")
	}

	fmt.Print("[2] canonical HZBLK1|1|genesis|merkle|? : ")
	// need to know block1's merkle and ts — try common
	for _, merkle := range []string{"", "f981652e6c25945a2655b83f7536524441422bdeb7b9742a30a5256cd637ceba"} {
		for _, ts := range []int64{1794246431, jsonTs.Unix(), createdTs.Unix()} {
			m := fmt.Sprintf("HZBLK1|1|%s|%s|%d", genesisHash, merkle, ts)
			if ok, _ := crypto.VerifyData(pub, []byte(m), block1Sig); ok {
				fmt.Printf("✅ merkle=%q ts=%d\n", merkle, ts)
				found = true
			}
		}
	}

	// [8] Address check: signer_addr from pubkey
	fmt.Println("\n══════════ signer_addr vs pubkey ══════════")
	fmt.Println("signer_addr = 0x616d61c4f3dd6eae5dcc7e7524cd14549b58b81d")
	fmt.Println("(20 bytes — Ethereum-style)")
	fmt.Println("اگر keccak256(pubkey)[12:] با این برابر نباشد → کلید متفاوت است")

	// [9] Signature structure
	fmt.Println("\n══════════ Signature structure ══════════")
	r := new(big.Int).SetBytes(sigBytes[:32])
	s := new(big.Int).SetBytes(sigBytes[32:])
	n := pub.Curve.Params().N
	fmt.Printf("  r = %x...\n", r.Bytes()[:4])
	fmt.Printf("  s = %x...\n", s.Bytes()[:4])
	fmt.Printf("  low-S (RFC 6979): %v\n", s.Cmp(new(big.Int).Rsh(n, 1)) <= 0)

	fmt.Println("\n══════════ حکم ══════════")
	if found {
		fmt.Println("  🟢 حداقل یک فرمول match شد — امضا ریاضی معتبر")
	} else {
		fmt.Println("  🔴 هیچ‌کدام match نشد — نیاز به کشف بیشتر")
		fmt.Println("  احتمال: امضا با کلید متفاوت، یا فرمول کاملاً متفاوت")
	}
}
