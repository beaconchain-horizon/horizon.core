package main

import (
    "crypto/sha256"
    "crypto/sha512"
    "database/sql"
    "encoding/binary"
    "encoding/hex"
    "encoding/json"
    "flag"
    "fmt"
    "os"
    "strconv"

    _ "github.com/lib/pq"
    "golang.org/x/crypto/blake2b"
    "golang.org/x/crypto/sha3"
)

type B struct {
    Num     int64
    Prev    string
    Merkle  string
    TS      int64
    TxCount int64
    Hash    string
    LicID   string
    Signer  string
}

func loadBlocks(dsn string) ([]B, error) {
    db, err := sql.Open("postgres", dsn)
    if err != nil { return nil, err }
    defer db.Close()
    rows, err := db.Query(`SELECT block_num, COALESCE(prev_hash,''), COALESCE(merkle_root,''),
        COALESCE(timestamp,0), COALESCE(tx_count,0), hash,
        COALESCE(signer_addr,'') FROM chain_blocks WHERE block_num BETWEEN 0 AND 2 ORDER BY block_num`)
    if err != nil { return nil, err }
    defer rows.Close()
    var out []B
    for rows.Next() {
        var b B
        if err := rows.Scan(&b.Num, &b.Prev, &b.Merkle, &b.TS, &b.TxCount, &b.Hash, &b.Signer); err != nil { return nil, err }
        b.LicID = fmt.Sprintf("BLOCK-LIC-%d-%d", b.Num, b.TS)
        out = append(out, b)
    }
    return out, rows.Err()
}

func tryAll(data []byte, stored string) (string, bool) {
    h := sha256.Sum256(data)
    if hex.EncodeToString(h[:]) == stored { return "SHA256", true }
    h2 := sha256.Sum256(h[:])
    if hex.EncodeToString(h2[:]) == stored { return "SHA256^2", true }
    kh := sha3.NewLegacyKeccak256(); kh.Write(data)
    if hex.EncodeToString(kh.Sum(nil)) == stored { return "Keccak256", true }
    sh := sha3.Sum256(data)
    if hex.EncodeToString(sh[:]) == stored { return "SHA3-256", true }
    bh := blake2b.Sum256(data)
    if hex.EncodeToString(bh[:]) == stored { return "BLAKE2b", true }
    s5 := sha512.Sum512(data)
    if hex.EncodeToString(s5[:32]) == stored { return "SHA512[:32]", true }
    return "", false
}

func i64be(n int64) []byte { b := make([]byte, 8); binary.BigEndian.PutUint64(b, uint64(n)); return b }
func i64le(n int64) []byte { b := make([]byte, 8); binary.LittleEndian.PutUint64(b, uint64(n)); return b }
func dec(s string) []byte { b, _ := hex.DecodeString(s); return b }

func main() {
    dsn := flag.String("dsn", "host=localhost port=5432 user=postgres password=postgres dbname=horizon_switch sslmode=disable", "")
    flag.Parse()
    blocks, err := loadBlocks(*dsn)
    if err != nil { fmt.Println("❌", err); os.Exit(1) }
    if len(blocks) < 3 { fmt.Println("❌ نیاز به بلاک ۰،۱،۲"); os.Exit(1) }

    for _, b := range blocks {
        prev := b.Prev; if len(prev) > 16 { prev = prev[:16] }
        fmt.Printf("B%d: hash=%s prev=%s ts=%d tx=%d\n", b.Num, b.Hash[:16], prev, b.TS, b.TxCount)
    }
    fmt.Println()

    type C struct{ name string; fn func(B) []byte }
    sTS := func(b B) string { return strconv.FormatInt(b.TS, 10) }
    sTX := func(b B) string { return strconv.FormatInt(b.TxCount, 10) }
    sN  := func(b B) string { return strconv.FormatInt(b.Num, 10) }

    cands := []C{
        // Ordering variants
        {"prev+merkle+ts+tx", func(b B) []byte { return []byte(b.Prev + b.Merkle + sTS(b) + sTX(b)) }},
        {"prev+merkle+tx+ts", func(b B) []byte { return []byte(b.Prev + b.Merkle + sTX(b) + sTS(b)) }},
        {"prev+merkle+ts", func(b B) []byte { return []byte(b.Prev + b.Merkle + sTS(b)) }},
        {"prev+merkle", func(b B) []byte { return []byte(b.Prev + b.Merkle) }},
        {"merkle+ts+tx", func(b B) []byte { return []byte(b.Merkle + sTS(b) + sTX(b)) }},
        {"merkle+prev+ts+tx", func(b B) []byte { return []byte(b.Merkle + b.Prev + sTS(b) + sTX(b)) }},
        {"prev+ts+tx", func(b B) []byte { return []byte(b.Prev + sTS(b) + sTX(b)) }},
        {"merkle+tx", func(b B) []byte { return []byte(b.Merkle + sTX(b)) }},
        {"merkle", func(b B) []byte { return []byte(b.Merkle) }},
        // With num
        {"num+prev+merkle+ts+tx", func(b B) []byte { return []byte(sN(b) + b.Prev + b.Merkle + sTS(b) + sTX(b)) }},
        {"prev+num+merkle+ts+tx", func(b B) []byte { return []byte(b.Prev + sN(b) + b.Merkle + sTS(b) + sTX(b)) }},
        {"prev+merkle+num+ts+tx", func(b B) []byte { return []byte(b.Prev + b.Merkle + sN(b) + sTS(b) + sTX(b)) }},
        {"prev+merkle+ts+num+tx", func(b B) []byte { return []byte(b.Prev + b.Merkle + sTS(b) + sN(b) + sTX(b)) }},
        {"prev+merkle+ts+tx+num", func(b B) []byte { return []byte(b.Prev + b.Merkle + sTS(b) + sTX(b) + sN(b)) }},
        // With licid
        {"licid+prev+merkle", func(b B) []byte { return []byte(b.LicID + b.Prev + b.Merkle) }},
        {"prev+merkle+licid", func(b B) []byte { return []byte(b.Prev + b.Merkle + b.LicID) }},
        {"licid+prev+merkle+ts+tx", func(b B) []byte { return []byte(b.LicID + b.Prev + b.Merkle + sTS(b) + sTX(b)) }},
        {"prev+merkle+ts+tx+licid", func(b B) []byte { return []byte(b.Prev + b.Merkle + sTS(b) + sTX(b) + b.LicID) }},
        // With signer
        {"prev+merkle+ts+tx+signer", func(b B) []byte { return []byte(b.Prev + b.Merkle + sTS(b) + sTX(b) + b.Signer) }},
        {"signer+prev+merkle+ts+tx", func(b B) []byte { return []byte(b.Signer + b.Prev + b.Merkle + sTS(b) + sTX(b)) }},
        // Separators
        {"prev|merkle|ts|tx", func(b B) []byte { return []byte(b.Prev+"|"+b.Merkle+"|"+sTS(b)+"|"+sTX(b)) }},
        {"prev:merkle:ts:tx", func(b B) []byte { return []byte(b.Prev+":"+b.Merkle+":"+sTS(b)+":"+sTX(b)) }},
        {"prev,merkle,ts,tx", func(b B) []byte { return []byte(b.Prev+","+b.Merkle+","+sTS(b)+","+sTX(b)) }},
        {"prev\\nmerkle\\nts\\ntx", func(b B) []byte { return []byte(b.Prev+"\n"+b.Merkle+"\n"+sTS(b)+"\n"+sTX(b)) }},
        {"prev merkle ts tx", func(b B) []byte { return []byte(b.Prev+" "+b.Merkle+" "+sTS(b)+" "+sTX(b)) }},
        // Binary
        {"bin:prev+merkle+tsBE+txBE", func(b B) []byte {
            buf := append(append(append(dec(b.Prev), dec(b.Merkle)...), i64be(b.TS)...), i64be(b.TxCount)...)
            return buf
        }},
        {"bin:prev+merkle+tsLE+txLE", func(b B) []byte {
            buf := append(append(append(dec(b.Prev), dec(b.Merkle)...), i64le(b.TS)...), i64le(b.TxCount)...)
            return buf
        }},
        {"mix:prev_bin+merkle_bin+ts_ascii+tx_ascii", func(b B) []byte {
            buf := append(append([]byte{}, dec(b.Prev)...), dec(b.Merkle)...)
            return append(buf, []byte(sTS(b)+sTX(b))...)
        }},
        // JSON
        {"json{prev,merkle,ts,tx}", func(b B) []byte {
            j, _ := json.Marshal(struct{Prev string `json:"prev_hash"`; M string `json:"merkle_root"`; TS int64 `json:"timestamp"`; TX int64 `json:"tx_count"`}{b.Prev, b.Merkle, b.TS, b.TxCount})
            return j
        }},
        {"json{num,prev,merkle,ts,tx}", func(b B) []byte {
            j, _ := json.Marshal(struct{N int64 `json:"block_num"`; Prev string `json:"prev_hash"`; M string `json:"merkle_root"`; TS int64 `json:"timestamp"`; TX int64 `json:"tx_count"`}{b.Num, b.Prev, b.Merkle, b.TS, b.TxCount})
            return j
        }},
        // ts variants
        {"prev+merkle+ts_hex+tx", func(b B) []byte { return []byte(b.Prev + b.Merkle + fmt.Sprintf("%x", b.TS) + sTX(b)) }},
        {"prev+merkle+ts_ms+tx", func(b B) []byte { return []byte(b.Prev + b.Merkle + strconv.FormatInt(b.TS*1000, 10) + sTX(b)) }},
    }

    fmt.Println("Testing (must match B1 AND B2 — B0 may be special):")
    fmt.Println("═══════════════════════════════════════════════════════════════════")

    found := 0
    for _, c := range cands {
        // Test on B1 and B2 only (skip B0 — genesis may be special)
        var algos []string
        match12 := true
        for _, b := range blocks[1:] {
            algo, ok := tryAll(c.fn(b), b.Hash)
            if !ok { match12 = false; break }
            algos = append(algos, fmt.Sprintf("B%d=%s", b.Num, algo))
        }
        if match12 {
            fmt.Printf("✅ %-40s → %v\n", c.name, algos)
            found++
            // Check B0
            if algo0, ok0 := tryAll(c.fn(blocks[0]), blocks[0].Hash); ok0 {
                fmt.Printf("   ✅ B0 also matches (%s) → 🎯 FULL FORMULA\n", algo0)
            } else {
                fmt.Printf("   ⚠ B0 does NOT match (genesis uses different formula)\n")
            }
        }
    }

    if found == 0 {
        fmt.Println("❌ هیچ‌کدام از ۳۰+ ترکیب × ۶ تابع hash روی B1 و B2 match نکرد")
        fmt.Println()
        fmt.Println("── نتیجه ──")
        fmt.Println("فرمول legacy ناشناخته است. برای کشف:")
        fmt.Println("  1) git log -p -- cmd/switch/switch.go | grep -B2 -A8 'blockHash :='")
        fmt.Println("  2) psql: SELECT block_num, prev_hash, merkle_root, timestamp, tx_count FROM chain_blocks WHERE block_num=0")
        fmt.Println("  3) اتصال USB → E2E → بلاک ۴۳ با کد فعلی ساخته شود")
    }
}
