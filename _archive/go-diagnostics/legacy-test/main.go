package main

import (
    "crypto/sha256"
    "encoding/hex"
    "fmt"

    "golang.org/x/crypto/sha3"
)

type B struct{ Num int64; Prev, Merkle string; TS int64; Hash string }
var blocks = []B{
    {0, "0000000000000000000000000000000000000000000000000000000000000000",
     "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603",
     1794246431, "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"},
    {1, "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603",
     "29dd62ce6a3ffdc5f03a7ed265f479809aa51cf5a4e591021f519930f82d3e3f",
     1794558193, "8a03330385d8383eda5ed924abac81d8c2d11e15d7e6f219d63b22f49ceb6a76"},
    {2, "8a03330385d8383eda5ed924abac81d8c2d11e15d7e6f219d63b22f49ceb6a76",
     "ad8f3c0152148034717c0faccef496e7c19814dd8b7a5cae9c25fe583c9766d5",
     1794558194, "1ff69fc50184ee1d4f68ceea76a1c8670f1dcfe3c1a27789bdb0911085d87996"},
}

func testHash(name, data, stored string) {
    h := sha256.Sum256([]byte(data))
    if hex.EncodeToString(h[:]) == stored { fmt.Printf("  ✅ SHA256  %s\n", name); return }
    k := sha3.NewLegacyKeccak256(); k.Write([]byte(data))
    if hex.EncodeToString(k.Sum(nil)) == stored { fmt.Printf("  ✅ Keccak  %s\n", name); return }
    s := sha3.Sum256([]byte(data))
    if hex.EncodeToString(s[:]) == stored { fmt.Printf("  ✅ SHA3    %s\n", name); return }
}

func main() {
    for _, b := range blocks {
        fmt.Printf("\n═══ B%d ═══\n", b.Num)
        fmt.Printf("stored: %s\n", b.Hash)

        // فرمول legacy از git: fmt.Sprintf("%d|%d|%s|%s", num, ts, prev, merkle)
        legacy := fmt.Sprintf("%d|%d|%s|%s", b.Num, b.TS, b.Prev, b.Merkle)
        testHash("legacy: num|ts|prev|merkle", legacy, b.Hash)

        // تنوع‌ها
        testHash("num|ts|merkle|prev", fmt.Sprintf("%d|%d|%s|%s", b.Num, b.TS, b.Merkle, b.Prev), b.Hash)
        testHash("ts|num|prev|merkle", fmt.Sprintf("%d|%d|%s|%s", b.TS, b.Num, b.Prev, b.Merkle), b.Hash)
        testHash("prev|merkle|ts|num", fmt.Sprintf("%s|%s|%d|%d", b.Prev, b.Merkle, b.TS, b.Num), b.Hash)
        testHash("num|prev|ts|merkle", fmt.Sprintf("%d|%s|%d|%s", b.Num, b.Prev, b.TS, b.Merkle), b.Hash)
        testHash("num+ts+prev+merkle(no sep)", fmt.Sprintf("%d%d%s%s", b.Num, b.TS, b.Prev, b.Merkle), b.Hash)
        testHash("num|ts|prev|merkle|tx", fmt.Sprintf("%d|%d|%s|%s|0", b.Num, b.TS, b.Prev, b.Merkle), b.Hash)
    }
}
