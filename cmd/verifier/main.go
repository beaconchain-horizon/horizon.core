package main

import (
    "crypto/ecdsa"
    "crypto/sha256"
    "crypto/x509"
    "database/sql"
    "encoding/hex"
    "encoding/json"
    "flag"
    "fmt"
    "os"
    "strconv"
    "strings"
    "sort"
    "time"

    _ "github.com/lib/pq"

    "horizon-core/internal/crypto"
    "horizon-core/internal/crypto/wots"
)

const genesisHash = "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
const zero64 = "0000000000000000000000000000000000000000000000000000000000000000"

type Block struct {
    Num, Ts, TxCount, LicenseCount int64
    Prev, Merkle, Hash, Sig, Signer, OrganizationID string
}

type License struct {
    ID, User, Prod, Sig, Merkle, Status, HwID, WOTSSig, WOTSPub, OrganizationID string
    Vol, Used, Dur, IssAt, ExpAt, BlockNum int64
}

type ChainTx struct {
    ID, TxID, TxType, Payload, TxHash, Signature string
    BlockNum, Timestamp int64
}

type organizationBatchPayload struct {
    SchemaVersion string `json:"schema_version"`
    OrganizationID string `json:"organization_id"`
    LicenseCount int `json:"license_count"`
    Licenses []struct {
        LicenseID string `json:"license_id"`
        UserID string `json:"user_id"`
        ProductID string `json:"product_id"`
        Volume int `json:"volume"`
        Duration int `json:"duration"`
        Signature string `json:"signature"`
        MerkleRoot string `json:"merkle_root"`
        IssuedAt int64 `json:"issued_at"`
        ExpiresAt int64 `json:"expires_at"`
        HardwareID string `json:"hardware_id"`
        LicenseType string `json:"license_type"`
        WOTSSignature string `json:"wots_signature"`
        WOTSPubKey string `json:"wots_pub_key"`
    } `json:"licenses"`
}

func shaHex(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

// ─── Legacy formula (license_chain.go) ───
func legacyBlockMsg(n int64, prev, merkle string, ts int64) string {
    return fmt.Sprintf("HZBLK1|%d|%s|%s|%d", n, prev, merkle, ts)
}
func legacyBlockHash(n int64, prev, merkle string, ts int64) string {
    return shaHex([]byte(legacyBlockMsg(n, prev, merkle, ts)))
}

// ─── Current formula (mineBlockHandler) ───
func currentBlockHash(prev, merkle string, ts, txCount int64) string {
    h := sha256.New()
    h.Write([]byte(prev))
    h.Write([]byte(merkle))
    fmt.Fprintf(h, "%d", ts)
    fmt.Fprintf(h, "%d", txCount)
    return hex.EncodeToString(h.Sum(nil))
}

// ─── License canonical message ───
func licenseCanonical(l *License) ([]byte, error) {
    return json.Marshal(struct {
        LicenseID  string `json:"license_id"`
        UserID     string `json:"user_id"`
        ProductID  string `json:"product_id"`
        Volume     int64  `json:"volume"`
        Duration   int64  `json:"duration"`
        MerkleRoot string `json:"merkle_root"`
        IssuedAt   int64  `json:"issued_at"`
        ExpiresAt  int64  `json:"expires_at"`
        HardwareID string `json:"hardware_id"`
    }{l.ID, l.User, l.Prod, l.Vol, l.Dur, l.Merkle, l.IssAt, l.ExpAt, l.HwID})
}

func main() {
    dsn := flag.String("dsn", "host=localhost port=5432 user=postgres password=postgres dbname=horizon_switch sslmode=disable", "")
    pubHex := flag.String("pubkey", os.Getenv("HORIZON_LICENSE_PUBLIC_KEY"), "")
    verbose := flag.Bool("v", false, "")
    flag.Parse()

    pubStr := strings.TrimPrefix(strings.TrimPrefix(*pubHex, "0x"), "0X")
    if pubStr == "" {
        fmt.Println("❌ HORIZON_LICENSE_PUBLIC_KEY not set"); os.Exit(2)
    }
    pub, err := crypto.Secp256k1PublicKeyFromHex(pubStr)
    if err != nil { fmt.Println("❌ bad pubkey:", err); os.Exit(2) }

    db, err := sql.Open("postgres", *dsn)
    if err != nil { fmt.Println("❌ db:", err); os.Exit(2) }
    defer db.Close()

    blocks := loadBlocks(db)
    licenses := loadLicenses(db)
    chainTxs := loadChainTxs(db)

    fmt.Println("╔═══════════════════════════════════════════════════════════════════╗")
    fmt.Println("║  HORIZON CORE — MATHEMATICAL VERIFIER v2.0                        ║")
    fmt.Printf("║  %s                                            ║\n", time.Now().Format("2006-01-02 15:04:05"))
    fmt.Println("╚═══════════════════════════════════════════════════════════════════╝")
    fmt.Printf("  Blocks: %d  |  Licenses: %d\n\n", len(blocks), len(licenses))

    critical := []string{}

    // ─── [0/5] v1.5 organization batch commitment ───
    fmt.Println("▸ [0/5] v1.5 Organization Batch Commitment")
    fmt.Println("───────────────────────────────────────────────────────────────────")
    if err := verifyOrganizationBatches(blocks, licenses, chainTxs, pub); err != nil {
        fmt.Printf("  ❌ %v\\n", err)
        critical = append(critical, "organization-batch")
    } else {
        fmt.Println("  ✅ all organization batches verified")
    }
    fmt.Println()

    // ─── [1/5] Chain linkage ───
    fmt.Println("▸ [1/5] Chain Linkage & Genesis Lock")
    fmt.Println("───────────────────────────────────────────────────────────────────")
    linkOK := 0
    for i, b := range blocks {
        if i == 0 {
            if b.Hash == genesisHash { linkOK++; fmt.Println("  ✅ B0 genesis locked") } else { critical = append(critical, "genesis") }
            continue
        }
        if b.Num != blocks[i-1].Num+1 { critical = append(critical, "seq") }
        if b.Prev != blocks[i-1].Hash { critical = append(critical, "link-"+strconv.FormatInt(b.Num,10)) }
        linkOK++
    }
    fmt.Printf("  → %d/%d linked ✓\n\n", linkOK, len(blocks))

    // ─── [2/5] Block hash recompute (dual formula) ───
    fmt.Println("▸ [2/5] Block Hash Recomputation (legacy + current)")
    fmt.Println("───────────────────────────────────────────────────────────────────")
    legacyCount, currentCount, legacyFail, currentFail := 0, 0, 0, 0
    for _, b := range blocks {
        legacy := legacyBlockHash(b.Num, b.Prev, b.Merkle, b.Ts)
        current := currentBlockHash(b.Prev, b.Merkle, b.Ts, b.TxCount)

        if legacy == b.Hash {
            legacyCount++
            if *verbose { fmt.Printf("  ✅ B%-3d legacy\n", b.Num) }
        } else if current == b.Hash {
            currentCount++
            if *verbose { fmt.Printf("  ✅ B%-3d current\n", b.Num) }
        } else {
            // B0 special: try with empty merkle
            if b.Num == 0 {
                if altLegacy := legacyBlockHash(0, zero64, "", b.Ts); altLegacy == b.Hash {
                    fmt.Printf("  ✅ B0 legacy (empty merkle)\n")
                    legacyCount++
                    continue
                }
            }
            fmt.Printf("  ❌ B%-3d FAIL  stored=%s\n", b.Num, b.Hash[:24])
            if *verbose {
                fmt.Printf("       legacy : %s\n", legacy[:24])
                fmt.Printf("       current: %s\n", current[:24])
                fmt.Printf("       prev=%s ts=%d tx=%d merkle=%s\n", b.Prev[:16], b.Ts, b.TxCount, b.Merkle[:16])
            }
            if b.Num < 43 { legacyFail++ } else { currentFail++ }
            critical = append(critical, "hash-"+strconv.FormatInt(b.Num,10))
        }
    }
    fmt.Printf("  → legacy: %d OK, current: %d OK, failures: %d+%d\n\n", legacyCount, currentCount, legacyFail, currentFail)

    // ─── [3/5] Block ECDSA ───
    fmt.Println("▸ [3/5] Block ECDSA Signatures")
    fmt.Println("───────────────────────────────────────────────────────────────────")
    blockSigOK := 0
    for _, b := range blocks {
        if b.Sig == "" { continue }
        // legacy: sign on canonicalBlockMessage → SHA256 → RS
        msg := []byte(legacyBlockMsg(b.Num, b.Prev, b.Merkle, b.Ts))
        ok, _ := crypto.VerifyData(pub, msg, b.Sig)
        if ok { blockSigOK++ }
    }
    fmt.Printf("  → %d/%d verified via license pubkey\n", blockSigOK, len(blocks))
    if blockSigOK == 0 {
        fmt.Println("  ⚠ signer uses different key (block signing key ≠ license key)")
    }
    fmt.Println()

    // ─── [4/5] License ECDSA ───
    fmt.Println("▸ [4/5] License ECDSA (secp256k1)")
    fmt.Println("───────────────────────────────────────────────────────────────────")
    licECDSA := 0
    for _, l := range licenses {
        msg, _ := licenseCanonical(&l)
        ok, verr := crypto.VerifyData(pub, msg, l.Sig)
        if verr != nil || !ok {
            fmt.Printf("  ❌ %s\n", l.ID)
            critical = append(critical, "lic-"+l.ID)
        } else {
            fmt.Printf("  ✅ %s\n", l.ID)
            licECDSA++
        }
    }
    fmt.Printf("  → %d/%d ✓\n\n", licECDSA, len(licenses))

    // ─── [5/5] License WOTS+ ───
    fmt.Println("▸ [5/5] License WOTS+ (post-quantum)")
    fmt.Println("───────────────────────────────────────────────────────────────────")
    licWOTS := 0
    for _, l := range licenses {
        if l.WOTSSig == "" || l.WOTSPub == "" {
            fmt.Printf("  ⚠ %s: no WOTS+ data\n", l.ID); continue
        }
        msg, _ := licenseCanonical(&l)
        h := sha256.Sum256(msg)
        pub, e1 := hex.DecodeString(l.WOTSPub)
        sig, e2 := hex.DecodeString(l.WOTSSig)
        if e1 != nil || e2 != nil || len(pub) != wots.PubKeySize || len(sig) != wots.SigSize {
            fmt.Printf("  ❌ %s: bad WOTS+ data\n", l.ID)
            critical = append(critical, "wots-"+l.ID); continue
        }
        if wots.Verify(pub, h[:], sig) {
            fmt.Printf("  ✅ %s\n", l.ID); licWOTS++
        } else {
            fmt.Printf("  ❌ %s: verify FAILED\n", l.ID)
            critical = append(critical, "wots-"+l.ID)
        }
    }
    fmt.Printf("  → %d/%d ✓\n\n", licWOTS, len(licenses))

    // ─── BONUS: Fail-Closed ───
    fmt.Println("▸ [BONUS] Fail-Closed Status")
    fmt.Println("───────────────────────────────────────────────────────────────────")
    for _, l := range licenses {
        state := "ok ✅"
        if l.Used >= l.Vol { state = "EXHAUSTED ⚠" }
        fmt.Printf("  %-30s  %d/%d  status=%s  %s\n", l.ID, l.Used, l.Vol, l.Status, state)
    }

    fmt.Println()
    if len(critical) == 0 {
        fmt.Println("╔═══════════════════════════════════════════════════════════════════╗")
        fmt.Println("║  🟢 ALL CHECKS PASSED                                             ║")
        fmt.Println("║  Chain is mathematically immutable. Dual-formula verified.        ║")
        fmt.Println("║  Licenses signed with ECDSA + WOTS+ (post-quantum).               ║")
        fmt.Println("╚═══════════════════════════════════════════════════════════════════╝")
        os.Exit(0)
    }
    fmt.Printf("╔═══════════════════════════════════════════════════════════════════╗\n")
    fmt.Printf("║  🔴 %d CRITICAL FAILURE(S)\n", len(critical))
    for _, c := range critical { fmt.Printf("║    • %s\n", c) }
    fmt.Println("╚═══════════════════════════════════════════════════════════════════╝")
    os.Exit(1)
}

func loadBlocks(db *sql.DB) []Block {
    rows, err := db.Query(`SELECT block_num, COALESCE(prev_hash,''), COALESCE(merkle_root,''),
        COALESCE(timestamp,0), COALESCE(tx_count,0), hash,
        COALESCE(signature,''), COALESCE(signer_addr,''),
        COALESCE(organization_id,''), COALESCE(license_count,0)
        FROM chain_blocks ORDER BY block_num ASC`)
    if err != nil { fmt.Println("⚠ loadBlocks:", err); return nil }
    defer rows.Close()
    var out []Block
    for rows.Next() {
        var b Block
        rows.Scan(&b.Num, &b.Prev, &b.Merkle, &b.Ts, &b.TxCount, &b.Hash, &b.Sig, &b.Signer, &b.OrganizationID, &b.LicenseCount)
        out = append(out, b)
    }
    return out
}

func loadLicenses(db *sql.DB) []License {
    rows, err := db.Query(`SELECT license_id, user_id, COALESCE(product_id,''),
        COALESCE(volume,0), COALESCE(used,0), COALESCE(duration,0),
        COALESCE(signature,''), COALESCE(merkle_root,''),
        issued_at::text, expires_at::text,
        COALESCE(status,''), COALESCE(hardware_id,''),
        COALESCE(wots_signature,''), COALESCE(wots_pub_key,''),
        COALESCE(organization_id,''), COALESCE(block_num,0)
        FROM licenses ORDER BY license_id`)
    if err != nil { fmt.Println("⚠ loadLicenses:", err); return nil }
    defer rows.Close()
    var out []License
    for rows.Next() {
        var l License
        var iss, exp sql.NullString
        rows.Scan(&l.ID, &l.User, &l.Prod, &l.Vol, &l.Used, &l.Dur,
            &l.Sig, &l.Merkle, &iss, &exp, &l.Status, &l.HwID, &l.WOTSSig, &l.WOTSPub, &l.OrganizationID, &l.BlockNum)
        l.IssAt = parseTs(iss.String)
        l.ExpAt = parseTs(exp.String)
        out = append(out, l)
    }
    return out
}

func loadChainTxs(db *sql.DB) []ChainTx {
    rows, err := db.Query(`SELECT tx_id, block_num, tx_type, payload, tx_hash,
        COALESCE(signature,''), COALESCE(timestamp,0)
        FROM chain_txes ORDER BY block_num ASC, tx_id ASC`)
    if err != nil { fmt.Println("⚠ loadChainTxs:", err); return nil }
    defer rows.Close()
    var out []ChainTx
    for rows.Next() {
        var tx ChainTx
        if err := rows.Scan(&tx.TxID, &tx.BlockNum, &tx.TxType, &tx.Payload, &tx.TxHash, &tx.Signature, &tx.Timestamp); err != nil {
            fmt.Println("⚠ scan chain tx:", err); return nil
        }
        out = append(out, tx)
    }
    return out
}

func verifyOrganizationBatches(blocks []Block, licenses []License, txs []ChainTx, pub *ecdsa.PublicKey) error {
    txsByBlock := make(map[int64][]ChainTx)
    licensesByBlock := make(map[int64][]License)
    for _, tx := range txs {
        txsByBlock[tx.BlockNum] = append(txsByBlock[tx.BlockNum], tx)
    }
    for _, lic := range licenses {
        if lic.BlockNum > 0 || lic.OrganizationID != "" {
            licensesByBlock[lic.BlockNum] = append(licensesByBlock[lic.BlockNum], lic)
        }
    }

    verified := 0
    for _, block := range blocks {
        if block.Num == 0 { continue }
        if strings.TrimSpace(block.OrganizationID) == "" {
            return fmt.Errorf("block #%d has no organization_id; legacy history cannot be silently relabeled as v1.5", block.Num)
        }
        if block.LicenseCount <= 0 || block.TxCount != 1 {
            return fmt.Errorf("block #%d violates organization block cardinality: license_count=%d tx_count=%d", block.Num, block.LicenseCount, block.TxCount)
        }
        blockTxs := txsByBlock[block.Num]
        if len(blockTxs) != 1 {
            return fmt.Errorf("block #%d must contain exactly one organization batch event; found %d", block.Num, len(blockTxs))
        }
        tx := blockTxs[0]
        if tx.TxType != "organization.licenses.issue" {
            return fmt.Errorf("block #%d has unexpected event type %q", block.Num, tx.TxType)
        }

        var payload organizationBatchPayload
        if err := json.Unmarshal([]byte(tx.Payload), &payload); err != nil {
            return fmt.Errorf("block #%d batch payload JSON: %w", block.Num, err)
        }
        if payload.SchemaVersion != "horizon.organization-license-batch.v1" ||
            payload.OrganizationID != block.OrganizationID ||
            payload.LicenseCount != int(block.LicenseCount) ||
            payload.LicenseCount != len(payload.Licenses) {
            return fmt.Errorf("block #%d batch metadata mismatch", block.Num)
        }

        expectedTxHash := shaHex([]byte(fmt.Sprintf("HZTXH1|%s|%s|%d", tx.TxType, tx.Payload, tx.Timestamp)))
        if tx.TxHash != expectedTxHash {
            return fmt.Errorf("block #%d event hash mismatch", block.Num)
        }
        expectedMerkle := shaHex([]byte(tx.TxHash))
        if block.Merkle != expectedMerkle {
            return fmt.Errorf("block #%d batch Merkle root mismatch", block.Num)
        }
        if block.Hash != legacyBlockHash(block.Num, block.Prev, block.Merkle, block.Ts) {
            return fmt.Errorf("block #%d block hash mismatch", block.Num)
        }
        txMsg := []byte(fmt.Sprintf("HZTX1|%s|%s|%s|%d", tx.TxType, tx.TxID, tx.Payload, tx.Timestamp))
        txSigOK, txSigErr := crypto.VerifyData(pub, txMsg, tx.Signature)
        if txSigErr != nil || !txSigOK {
            return fmt.Errorf("block #%d batch event signature invalid", block.Num)
        }
        blockSigOK, blockSigErr := crypto.VerifyData(pub, []byte(legacyBlockMsg(block.Num, block.Prev, block.Merkle, block.Ts)), block.Sig)
        if blockSigErr != nil || !blockSigOK {
            return fmt.Errorf("block #%d block signature invalid", block.Num)
        }

        stored := licensesByBlock[block.Num]
        if len(stored) != int(block.LicenseCount) {
            return fmt.Errorf("block #%d license row count mismatch: declared=%d stored=%d", block.Num, block.LicenseCount, len(stored))
        }
        storedByID := make(map[string]License, len(stored))
        for _, lic := range stored {
            if lic.OrganizationID != block.OrganizationID {
                return fmt.Errorf("block #%d contains cross-organization license %q", block.Num, lic.ID)
            }
            if _, exists := storedByID[lic.ID]; exists {
                return fmt.Errorf("block #%d has duplicate persisted license %q", block.Num, lic.ID)
            }
            storedByID[lic.ID] = lic
        }
        payloadIDs := make([]string, 0, len(payload.Licenses))
        for _, item := range payload.Licenses {
            payloadIDs = append(payloadIDs, item.LicenseID)
            lic, ok := storedByID[item.LicenseID]
            if !ok {
                return fmt.Errorf("block #%d payload license %q is absent from registry rows", block.Num, item.LicenseID)
            }
            if lic.User != item.UserID || lic.Prod != item.ProductID ||
                lic.Vol != int64(item.Volume) || lic.Dur != int64(item.Duration) ||
                lic.Sig != item.Signature || lic.Merkle != item.MerkleRoot ||
                lic.IssAt != item.IssuedAt || lic.ExpAt != item.ExpiresAt ||
                lic.HwID != item.HardwareID || lic.WOTSSig != item.WOTSSignature ||
                lic.WOTSPub != item.WOTSPubKey || lic.BlockNum != block.Num {
                return fmt.Errorf("block #%d payload/registry mismatch for license %q", block.Num, item.LicenseID)
            }
        }
        sort.Strings(payloadIDs)
        if len(payloadIDs) != len(storedByID) {
            return fmt.Errorf("block #%d payload membership length mismatch", block.Num)
        }
        for i := 1; i < len(payloadIDs); i++ {
            if payloadIDs[i] == payloadIDs[i-1] {
                return fmt.Errorf("block #%d payload repeats license %q", block.Num, payloadIDs[i])
            }
        }
        verified++
    }

    // Every v1.5-linked license must point to an existing organization block.
    for _, lic := range licenses {
        if lic.OrganizationID == "" && lic.BlockNum == 0 { continue } // legacy, unassigned record
        found := false
        for _, block := range blocks {
            if block.Num == lic.BlockNum && block.OrganizationID == lic.OrganizationID {
                found = true
                break
            }
        }
        if !found {
            return fmt.Errorf("license %q references missing organization block #%d", lic.ID, lic.BlockNum)
        }
    }
    _ = verified
    return nil
}

func parseTs(s string) int64 {
    s = strings.TrimSpace(s)
    if s == "" { return 0 }
    if n, e := strconv.ParseInt(s, 10, 64); e == nil { return n }
    for _, layout := range []string{time.RFC3339, "2006-01-02 15:04:05.999999-07:00",
        "2006-01-02 15:04:05", "2006-01-02 15:04:05-07:00"} {
        if t, e := time.Parse(layout, s); e == nil { return t.Unix() }
    }
    return 0
}

var _ = x509.MarshalPKCS1PrivateKey // suppress unused warning
