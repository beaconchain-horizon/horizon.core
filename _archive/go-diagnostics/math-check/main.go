package main

import (
    "crypto/sha256"
    "encoding/binary"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "strconv"
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

var blocks = []B{
    {1, "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603",
     "29dd62ce6a3ffdc5f03a7ed265f479809aa51cf5a4e591021f519930f82d3e3f",
     1794558193, 1, "8a03330385d8383eda5ed924abac81d8c2d11e15d7e6f219d63b22f49ceb6a76",
     "BLOCK-LIC-1-1794558193", "0x616d61c4f3dd6eae5dcc7e7524cd14549b58b81d"},
    {2, "8a03330385d8383eda5ed924abac81d8c2d11e15d7e6f219d63b22f49ceb6a76",
     "ad8f3c0152148034717c0faccef496e7c19814dd8b7a5cae9c25fe583c9766d5",
     1794558194, 1, "1ff69fc50184ee1d4f68ceea76a1c8670f1dcfe3c1a27789bdb0911085d87996",
     "BLOCK-LIC-2-1794558194", "0x616d61c4f3dd6eae5dcc7e7524cd14549b58b81d"},
}

func sha(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func i64(n int64) []byte { b := make([]byte, 8); binary.BigEndian.PutUint64(b, uint64(n)); return b }

func main() {
    type F struct { name string; fn func(B) string }
    fs := []F{
        // concatenation of hex-string fields
        {"prev+merkle+ts+tx", func(b B) string { return sha([]byte(b.Prev+b.Merkle+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10))) }},
        {"prev+merkle+tx+ts", func(b B) string { return sha([]byte(b.Prev+b.Merkle+strconv.FormatInt(b.TxCount,10)+strconv.FormatInt(b.TS,10))) }},
        {"prev+merkle+ts", func(b B) string { return sha([]byte(b.Prev+b.Merkle+strconv.FormatInt(b.TS,10))) }},
        {"merkle+prev+ts+tx", func(b B) string { return sha([]byte(b.Merkle+b.Prev+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10))) }},
        {"num+prev+merkle+ts+tx", func(b B) string { return sha([]byte(strconv.FormatInt(b.Num,10)+b.Prev+b.Merkle+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10))) }},
        {"prev+merkle+ts+tx+num", func(b B) string { return sha([]byte(b.Prev+b.Merkle+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10)+strconv.FormatInt(b.Num,10))) }},
        // with license id
        {"licid+prev+merkle", func(b B) string { return sha([]byte(b.LicID+b.Prev+b.Merkle)) }},
        {"prev+merkle+licid", func(b B) string { return sha([]byte(b.Prev+b.Merkle+b.LicID)) }},
        {"licid+prev+merkle+ts+tx", func(b B) string { return sha([]byte(b.LicID+b.Prev+b.Merkle+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10))) }},
        {"prev+merkle+licid+tx", func(b B) string { return sha([]byte(b.Prev+b.Merkle+b.LicID+strconv.FormatInt(b.TxCount,10))) }},
        // with signer
        {"prev+merkle+ts+tx+signer", func(b B) string { return sha([]byte(b.Prev+b.Merkle+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10)+b.Signer)) }},
        {"signer+prev+merkle+ts+tx", func(b B) string { return sha([]byte(b.Signer+b.Prev+b.Merkle+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10))) }},
        // separators on main formula
        {"prev|merkle|ts|tx", func(b B) string { return sha([]byte(b.Prev+"|"+b.Merkle+"|"+strconv.FormatInt(b.TS,10)+"|"+strconv.FormatInt(b.TxCount,10))) }},
        {"prev:merkle:ts:tx", func(b B) string { return sha([]byte(b.Prev+":"+b.Merkle+":"+strconv.FormatInt(b.TS,10)+":"+strconv.FormatInt(b.TxCount,10))) }},
        {"prev,merkle,ts,tx", func(b B) string { return sha([]byte(b.Prev+","+b.Merkle+","+strconv.FormatInt(b.TS,10)+","+strconv.FormatInt(b.TxCount,10))) }},
        {"prev\\nmerkle\\nts\\ntx", func(b B) string { return sha([]byte(b.Prev+"\n"+b.Merkle+"\n"+strconv.FormatInt(b.TS,10)+"\n"+strconv.FormatInt(b.TxCount,10))) }},
        {"prev merkle ts tx", func(b B) string { return sha([]byte(b.Prev+" "+b.Merkle+" "+strconv.FormatInt(b.TS,10)+" "+strconv.FormatInt(b.TxCount,10))) }},
        // binary forms
        {"bin(all) prev||merkle||i64(ts)||i64(tx)", func(b B) string {
            pb, _ := hex.DecodeString(b.Prev); mb, _ := hex.DecodeString(b.Merkle)
            buf := append(append(append(pb, mb...), i64(b.TS)...), i64(b.TxCount)...)
            return sha(buf)
        }},
        {"ascii(prev,merkle)||i64(ts)||i64(tx)", func(b B) string {
            buf := append(append([]byte(b.Prev+b.Merkle), i64(b.TS)...), i64(b.TxCount)...)
            return sha(buf)
        }},
        // different timestamp formats
        {"prev+merkle+ts*1000+tx", func(b B) string { return sha([]byte(b.Prev+b.Merkle+strconv.FormatInt(b.TS*1000,10)+strconv.FormatInt(b.TxCount,10))) }},
        {"prev+merkle+ts*1e9+tx", func(b B) string { return sha([]byte(b.Prev+b.Merkle+strconv.FormatInt(b.TS*1e9,10)+strconv.FormatInt(b.TxCount,10))) }},
        {"prev+merkle+hex(ts)+tx", func(b B) string { return sha([]byte(b.Prev+b.Merkle+fmt.Sprintf("%x",b.TS)+strconv.FormatInt(b.TxCount,10))) }},
        // JSON struct forms
        {"json{num,prev,merkle,ts,tx}", func(b B) string {
            j, _ := json.Marshal(struct{Num int64 `json:"block_num"`; Prev string `json:"prev_hash"`; M string `json:"merkle_root"`; TS int64 `json:"timestamp"`; TX int64 `json:"tx_count"`}{b.Num,b.Prev,b.Merkle,b.TS,b.TxCount})
            return sha(j)
        }},
        {"json{prev,merkle,ts,tx}", func(b B) string {
            j, _ := json.Marshal(struct{Prev string `json:"prev_hash"`; M string `json:"merkle_root"`; TS int64 `json:"timestamp"`; TX int64 `json:"tx_count"`}{b.Prev,b.Merkle,b.TS,b.TxCount})
            return sha(j)
        }},
        {"json{licid,prev,merkle,ts,tx}", func(b B) string {
            j, _ := json.Marshal(struct{Lic string `json:"block_license_id"`; Prev string `json:"prev_hash"`; M string `json:"merkle_root"`; TS int64 `json:"timestamp"`; TX int64 `json:"tx_count"`}{b.LicID,b.Prev,b.Merkle,b.TS,b.TxCount})
            return sha(j)
        }},
        // double hash
        {"sha256(sha256(prev+merkle+ts+tx))", func(b B) string {
            h1 := sha256.Sum256([]byte(b.Prev+b.Merkle+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10)))
            h2 := sha256.Sum256(h1[:])
            return hex.EncodeToString(h2[:])
        }},
        // hash of hex-decode of hash
        {"sha256(hex(h1))", func(b B) string {
            h1 := sha256.Sum256([]byte(b.Prev+b.Merkle+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10)))
            return sha([]byte(hex.EncodeToString(h1[:])))
        }},
        // no prev
        {"merkle+ts+tx", func(b B) string { return sha([]byte(b.Merkle+strconv.FormatInt(b.TS,10)+strconv.FormatInt(b.TxCount,10))) }},
        // merkle only
        {"merkle", func(b B) string { return sha([]byte(b.Merkle)) }},
        // raw merkle (already hex, just re-hex? probably not but cheap)
        {"merkle(decoded)", func(b B) string { mb, _ := hex.DecodeString(b.Merkle); return sha(mb) }},
    }

    fmt.Println("═══ B1 search ═══")
    fmt.Printf("stored: %s\n\n", blocks[0].Hash)
    found := []string{}
    for _, f := range fs {
        r := f.fn(blocks[0])
        if r == blocks[0].Hash {
            fmt.Printf("✅ B1 MATCH: %s\n", f.name)
            found = append(found, f.name)
        }
    }
    if len(found) == 0 {
        fmt.Println("❌ B1: هیچ‌کدام match نکرد")
    }

    fmt.Println("\n═══ B2 cross-check ═══")
    for _, name := range found {
        for _, f := range fs {
            if f.name == name {
                r := f.fn(blocks[1])
                ok := "✅"
                if r != blocks[1].Hash { ok = "❌" }
                fmt.Printf("%s B2 %s → %s\n", ok, name, r[:32])
            }
        }
    }
}
