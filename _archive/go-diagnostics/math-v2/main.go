package main

import (
    "crypto/sha256"
    "encoding/binary"
    "encoding/hex"
    "fmt"

    "golang.org/x/crypto/sha3"
)

type B struct {
    Num, ID int64
    TS      int64
    Prev, Merkle, Hash string
    TxCount int64
}

var blocks = []B{
    {0, 4, 1794246431,
     "0000000000000000000000000000000000000000000000000000000000000000",
     "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603",
     "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603", 0},
    {1, 5, 1794558193,
     "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603",
     "29dd62ce6a3ffdc5f03a7ed265f479809aa51cf5a4e591021f519930f82d3e3f",
     "8a03330385d8383eda5ed924abac81d8c2d11e15d7e6f219d63b22f49ceb6a76", 1},
    {2, 6, 1794558194,
     "8a03330385d8383eda5ed924abac81d8c2d11e15d7e6f219d63b22f49ceb6a76",
     "ad8f3c0152148034717c0faccef496e7c19814dd8b7a5cae9c25fe583c9766d5",
     "1ff69fc50184ee1d4f68ceea76a1c8670f1dcfe3c1a27789bdb0911085d87996", 1},
}

func s256(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func kecc(b []byte) string { k := sha3.NewLegacyKeccak256(); k.Write(b); return hex.EncodeToString(k.Sum(nil)) }
func sha3_256(b []byte) string { h := sha3.Sum256(b); return hex.EncodeToString(h[:]) }
func dec(s string) []byte { b, _ := hex.DecodeString(s); return b }
func be64(n int64) []byte { b := make([]byte, 8); binary.BigEndian.PutUint64(b, uint64(n)); return b }

func genMerkle(b B) string {
    if b.Num == 0 { return b.Prev } // hypothesis: genesis merkle was prev (0×64)
    return b.Merkle
}

func main() {
    type F struct{ name string; fn func(B) []byte }
    licid := func(b B) string { return fmt.Sprintf("BLOCK-LIC-%d-%d", b.Num, b.TS) }

    fs := []F{
        {"id|ts|prev|merkle", func(b B) []byte { return []byte(fmt.Sprintf("%d|%d|%s|%s", b.ID, b.TS, b.Prev, genMerkle(b))) }},
        {"id|ts|prev|merkle|tx", func(b B) []byte { return []byte(fmt.Sprintf("%d|%d|%s|%s|%d", b.ID, b.TS, b.Prev, genMerkle(b), b.TxCount)) }},
        {"(num+1)|ts|prev|merkle", func(b B) []byte { return []byte(fmt.Sprintf("%d|%d|%s|%s", b.Num+1, b.TS, b.Prev, genMerkle(b))) }},
        {"num|ts|prev|merkle (merkle=prev for B0)", func(b B) []byte { return []byte(fmt.Sprintf("%d|%d|%s|%s", b.Num, b.TS, b.Prev, genMerkle(b))) }},
        {"licid|prev|merkle", func(b B) []byte { return []byte(licid(b) + b.Prev + genMerkle(b)) }},
        {"licid|prev|merkle|ts", func(b B) []byte { return []byte(fmt.Sprintf("%s|%s|%s|%d", licid(b), b.Prev, genMerkle(b), b.TS)) }},
        {"licid|num|ts|prev|merkle", func(b B) []byte { return []byte(fmt.Sprintf("%s|%d|%d|%s|%s", licid(b), b.Num, b.TS, b.Prev, genMerkle(b))) }},
        {"num|ts|prev|merkle|tx (5 field pipe)", func(b B) []byte { return []byte(fmt.Sprintf("%d|%d|%s|%s|%d", b.Num, b.TS, b.Prev, genMerkle(b), b.TxCount)) }},
        {"num|ts|prev|merkle + trailing NL", func(b B) []byte { return []byte(fmt.Sprintf("%d|%d|%s|%s\n", b.Num, b.TS, b.Prev, genMerkle(b))) }},
        {"num|ts|prev|merkle (bin ts)", func(b B) []byte {
            buf := []byte(fmt.Sprintf("%d|", b.Num))
            buf = append(buf, be64(b.TS)...)
            buf = append(buf, '|')
            buf = append(buf, b.Prev...)
            buf = append(buf, '|')
            buf = append(buf, genMerkle(b)...)
            return buf
        }},
        {"prev|merkle|ts|num (num last)", func(b B) []byte { return []byte(fmt.Sprintf("%s|%s|%d|%d", b.Prev, genMerkle(b), b.TS, b.Num)) }},
        {"ts|num|prev|merkle (ts first)", func(b B) []byte { return []byte(fmt.Sprintf("%d|%d|%s|%s", b.TS, b.Num, b.Prev, genMerkle(b))) }},
        {"prev|merkle|ts|tx|num", func(b B) []byte { return []byte(fmt.Sprintf("%s|%s|%d|%d|%d", b.Prev, genMerkle(b), b.TS, b.TxCount, b.Num)) }},
    }

    for _, f := range fs {
        fmt.Printf("\n▸ %s\n", f.name)
        b0ok, b1ok, b2ok := false, false, false
        for _, b := range blocks {
            pre := f.fn(b)
            var match string
            if s256(pre) == b.Hash { match = "SHA256" }
            if kecc(pre) == b.Hash { match = "Keccak" }
            if sha3_256(pre) == b.Hash { match = "SHA3" }
            if match != "" {
                fmt.Printf("  ✅ B%d (%s)\n", b.Num, match)
                if b.Num == 0 { b0ok = true }
                if b.Num == 1 { b1ok = true }
                if b.Num == 2 { b2ok = true }
            } else {
                fmt.Printf("  ❌ B%d\n", b.Num)
            }
        }
        if b1ok && b2ok {
            tag := "⭐ B1+B2 MATCH"
            if b0ok { tag = "🎯🎯 ALL THREE MATCH — فرمول کشف شد!" }
            fmt.Printf("  → %s\n", tag)
        }
    }
}
