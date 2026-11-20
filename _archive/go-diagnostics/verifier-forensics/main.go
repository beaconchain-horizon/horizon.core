package main

import (
    "crypto/sha256"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "strconv"
)

func main() {
    prev := "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
    merkle := "29dd62ce6a3ffdc5f03a7ed265f479809aa51cf5a4e591021f519930f82d3e3f"
    ts := int64(1794558193)
    tx := int64(1)
    bn := int64(1)
    stored := "8a03330385d8383eda5ed924abac81d8c2d11e15d7e6f219d63b22f49ceb6a76"

    tsS := strconv.FormatInt(ts, 10)
    txS := strconv.FormatInt(tx, 10)
    bnS := strconv.FormatInt(bn, 10)

    type cand struct{ name, data string }
    cands := []cand{
        {"1. prev+merkle+ts+tx", prev + merkle + tsS + txS},
        {"2. prev+merkle+ts", prev + merkle + tsS},
        {"3. bn+prev+merkle+ts+tx", bnS + prev + merkle + tsS + txS},
        {"4. prev+merkle+tx+ts", prev + merkle + txS + tsS},
        {"5. merkle+prev+ts+tx", merkle + prev + tsS + txS},
        {"6. prev+merkle+ts+tx+bn", prev + merkle + tsS + txS + bnS},
        {"7. pipe-sep", prev + "|" + merkle + "|" + tsS + "|" + txS},
        {"8. newline-sep", prev + "\n" + merkle + "\n" + tsS + "\n" + txS},
        {"9. space-sep", prev + " " + merkle + " " + tsS + " " + txS},
        {"10. ts as hex", prev + merkle + fmt.Sprintf("%x", ts)},
        {"11. 0x-prefixed", "0x" + prev + "0x" + merkle + "0x" + tsS + "0x" + txS},
        {"12. k=v &", "prev=" + prev + "&merkle=" + merkle + "&ts=" + tsS + "&tx=" + txS},
        {"13. tx_count last", prev + merkle + tsS + strconv.Itoa(int(tx))},
        {"14. no-merkle", prev + tsS + txS},
        {"15. blockNum+txCount", bnS + txS + prev + merkle + tsS},
    }

    jsonStruct := struct {
        BlockNum int64 `json:"block_num"`
        PrevHash string `json:"prev_hash"`
        MerkleRoot string `json:"merkle_root"`
        Timestamp int64 `json:"timestamp"`
        TxCount int64 `json:"tx_count"`
    }{bn, prev, merkle, ts, tx}
    jd, _ := json.Marshal(jsonStruct)
    cands = append(cands, cand{"16. JSON canonical", string(jd)})

    fmt.Printf("stored: %s\n\n", stored)
    found := 0
    for _, c := range cands {
        h := sha256.Sum256([]byte(c.data))
        computed := hex.EncodeToString(h[:])
        status := "  "
        if computed == stored {
            status = "✅"
            found++
        }
        fmt.Printf("%s %-28s %s\n", status, c.name, computed[:32])
    }
    if found == 0 {
        fmt.Println("\n⚠ هیچ فرمولی match نکرد — legacy formula ناشناخته است")
    }
}
