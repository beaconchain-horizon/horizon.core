package main

import (
    "crypto/md5"
    "crypto/sha1"
    "crypto/sha256"
    "encoding/hex"
    "fmt"
    "strings"
)

type B struct{ Num, TS int64; Prev, Merkle, Hash string }

var blocks = []B{
    {1, 1794558193,
     "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603",
     "29dd62ce6a3ffdc5f03a7ed265f479809aa51cf5a4e591021f519930f82d3e3f",
     "8a03330385d8383eda5ed924abac81d8c2d11e15d7e6f219d63b22f49ceb6a76"},
    {2, 1794558194,
     "8a03330385d8383eda5ed924abac81d8c2d11e15d7e6f219d63b22f49ceb6a76",
     "ad8f3c0152148034717c0faccef496e7c19814dd8b7a5cae9c25fe583c9766d5",
     "1ff69fc50184ee1d4f68ceea76a1c8670f1dcfe3c1a27789bdb0911085d87996"},
}

func tryHash(data []byte, stored string) []string {
    var out []string
    h256 := sha256.Sum256(data)
    if hex.EncodeToString(h256[:]) == stored { out = append(out, "sha256") }
    h256b := sha256.Sum256(h256[:])
    if hex.EncodeToString(h256b[:]) == stored { out = append(out, "sha256^2") }
    // hash of hex(sha256)
    h256c := sha256.Sum256([]byte(hex.EncodeToString(h256[:])))
    if hex.EncodeToString(h256c[:]) == stored { out = append(out, "sha256(hex(sha256))") }
    // md5
    m := md5.Sum(data)
    if hex.EncodeToString(m[:]) == stored { out = append(out, "md5") }
    // sha1
    s1 := sha1.Sum(data)
    if hex.EncodeToString(s1[:]) == stored { out = append(out, "sha1") }
    return out
}

func main() {
    seps := []string{"|", ",", "-", ":", ";", " ", "\n", "\t", "_", ".", "::", "||", "&", "/", "\\"}
    for _, sep := range seps {
        for _, b := range blocks {
            data := fmt.Sprintf("%d%s%d%s%s%s%s", b.Num, sep, b.TS, sep, b.Prev, sep, b.Merkle)
            for _, m := range tryHash([]byte(data), b.Hash) {
                fmt.Printf("✅ B%d sep=%q → %s\n", b.Num, sep, m)
            }
        }
    }

    // empty field variants
    variants := []struct{ name string; fn func(B) string }{
        {"num|ts||merkle", func(b B) string { return fmt.Sprintf("%d|%d||%s", b.Num, b.TS, b.Merkle) }},
        {"num|ts|prev|", func(b B) string { return fmt.Sprintf("%d|%d|%s|", b.Num, b.TS, b.Prev) }},
        {"num|ts|prev", func(b B) string { return fmt.Sprintf("%d|%d|%s", b.Num, b.TS, b.Prev) }},
        {"prev|merkle", func(b B) string { return b.Prev + "|" + b.Merkle }},
        {"num|ts|prev|merkle|tx", func(b B) string { return fmt.Sprintf("%d|%d|%s|%s|1", b.Num, b.TS, b.Prev, b.Merkle) }},
        {"prev|ts|num|merkle", func(b B) string { return fmt.Sprintf("%s|%d|%d|%s", b.Prev, b.TS, b.Num, b.Merkle) }},
        {"merkle|prev|ts|num", func(b B) string { return fmt.Sprintf("%s|%s|%d|%d", b.Merkle, b.Prev, b.TS, b.Num) }},
    }
    for _, v := range variants {
        for _, b := range blocks {
            for _, m := range tryHash([]byte(v.fn(b)), b.Hash) {
                fmt.Printf("✅ B%d %s → %s\n", b.Num, v.name, m)
            }
        }
    }

    // Permutation of 4 fields
    fields := func(b B) map[string]string {
        return map[string]string{
            "n": fmt.Sprintf("%d", b.Num),
            "t": fmt.Sprintf("%d", b.TS),
            "p": b.Prev,
            "m": b.Merkle,
        }
    }
    perms := []string{"ntpm", "ntmp", "nptm", "npmt", "nmtp", "nmpt",
                      "tnpm", "tnmp", "tpnm", "tpmn", "tmnp", "tmpn",
                      "pntm", "pnmt", "ptnm", "ptmn", "pmnt", "pmtn",
                      "mntp", "mnpt", "mtnp", "mtpn", "mpnt", "mptn"}
    for _, p := range perms {
        for _, b := range blocks {
            f := fields(b)
            data := f[string(p[0])] + "|" + f[string(p[1])] + "|" + f[string(p[2])] + "|" + f[string(p[3])]
            for _, m := range tryHash([]byte(data), b.Hash) {
                fmt.Printf("✅ B%d perm=%s → %s\n", b.Num, p, m)
            }
        }
    }
    fmt.Println("\n[پایان] هر خط ✅ یعنی کشف شد.")
}
