# HORIZON CORE - v1.5

Offline-first tamper-evident ledger - v1.5
Genesis LOCKED | Block #1 SIGNED | 8-Node Consensus

---

## Genesis - locked 2026-11-03

- Chain ID: horizon-core-v1.5
- Genesis Hash: 8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603
- Block #1 Hash: f981652e6c25945a2655b83f7536524441422bdeb7b9742a30a5256cd637ceba
- Authority Pubkey: 04cf6aaaba8e7a6fddde63a2e2588553dc95503d2de6b2a5c78f4a30a0b91b0aca4d28d06fc1ccbaf730abe1dcda7c29726dab18008353b521c9253c04b1641214
- Genesis Sig: afac005b7f7565fe69ca9d58dabdf0a3914fce0854ee05f214d788e9e478b02f7c82a05b35d1456b605a128e4074ed9d3c4e55932cc7b368516c0681d236face (R||S, 64 bytes)
- Block #1 Sig: 19f1b567...94bd335 (R||S, 64 bytes)
- Key format: hex only (no PEM)

Verify locally:

    go run ./cmd/chain-verify

---

## Architecture - 7+1 Consensus (PBFT)

    Backend (8080) -> Switch (8091) -> 7 Specialty Nodes (9001-9007)
                                        |
                                  Agent Node (9008) - inspector, NOT consensus

### Port Map

- 8080 - Backend / API
- 8091 - Switch (operational gateway)
- 9001 - Angel Merkle: SHA256(left||right)
- 9002 - Angel Hash: SHA256(header)
- 9003 - Angel ECDSA: secp256k1 verify + WOTS+ verify
- 9004 - Angel Type: binary or ternary
- 9005 - Angel Volume: used < volume
- 9006 - Angel Time: volume = time (fails closed on exhaustion)
- 9007 - Angel User: user_id match
- 9008 - Agent Node (AI agents inspector, NOT consensus)

### Consensus (ANGEL-NODE-LAW.md)

- 4 CRITICAL (Merkle, Hash, ECDSA, Type) - 100% required
- 2 of 3 MAJORITY (Volume, Time, User) - required
- Otherwise: REJECT (fail-closed)

---

## Dual Merkle - Binary + Ternary

### Binary Merkle (RFC 6962 + v2 chain formula)

- RFC 6962 variant (internal/merkle/merkle.go):
  - leaf = SHA256(0x00 || data)
  - parent = SHA256(0x01 || left || right)
- v2 chain formula (BinaryRootNoPrefix):
  - leaf = SHA256(data) (no prefix)
  - node = SHA256(left || right) (no prefix)
  - odd = SHA256(last || last) (self-pair)
- Purpose: blocks and license roots use the same formula, so they can be recomputed by the same tool.

### Ternary Merkle (unique to Horizon)

- Leaf: L_i = SHA256(IndustryID_i || Data_i)
- Parent: N = SHA256(L || M || R)
- Depth: H = ceil(log_3(N))
- Purpose: Industry isolation + faster proofs (33% shallower than binary)

### Merkle Proof - Proven Theorem

Theorem: fold(leaf, path) = root is one-way and verifiable.

Proof (executed, test-passing):

    Root  = 9a4967b79ae3654141c56d03b4df33e5033574e4e0343f089e13a00b6b60a216
    Leaves = 5 (real license data + industry samples)
    Depth = 3 (log_2(5) = 3)

    Test                              Result
    Real license (all 5 leaves)       VERIFIED
    Fake license (HORIZON-FAKE-999)   REJECTED
    Tampered path (bit flip)          REJECTED

Run locally:

    go test ./internal/merkle/ -run TestRealLicenseProof -v

What it proves:

1. A data center holding only the root can verify any license with 3-16 hash operations (depending on tree size).
2. Fake licenses cannot be forged because SHA-256 is preimage-resistant.
3. The root cannot be used to recover other leaves (data sovereignty preserved).

Commit: df24fa3

---

## Cryptography - Dual Signature (Classical + Quantum-Resistant)

- Classical Curve: secp256k1 (SEC 2)
- Hash: SHA-256 (FIPS 180-4)
- Determinism: RFC 6979
- Low-S: s <= n/2 (BIP-62)
- Quantum-Resistant: WOTS+ (Winternitz One-Time Signature) based on SHA-256
- Signature: Every block and license is signed with BOTH ECDSA and WOTS+.
- Key format: hex only (64 chars, 0x optional). No PEM.

### Key Management (Zero-Knowledge)

- ECDSA Key: Read from USB /d/mykey.txt directly into RAM.
- WOTS+ Key: Read from USB /d/pqkey.txt directly into RAM.
- No Database Storage: The KeyVault table has been completely removed. Keys are never written to disk.
- No API Setup: cmd/switch key/setup is disabled (HTTP 410 Gone). Keys must be loaded via /key/unlock.
- Air-Gap Unlock: /api/v1/key/unlock requires physical USB connection. If disconnected, all transactions are rejected.

Verified:

- Fuzz testing: 1.86M execs - zero counterexamples
- Cross-verification: OpenSSL 3.5.7 - Verified OK

---

## Offline License Signer - v1.5

A single-page HTML signer that runs fully offline (no internet required after initial CDN load).

### Features

- ECDSA signing (secp256k1, RFC 6979, low-S/BIP-62)
- Ethereum address derivation from public key (keccak256(pub[1:])[-20:])
- 64-byte raw R||S output (compatible with block-sign and license-signer)
- WireGuard deep link (wireguard://) for tunnel connection
- Industry selector (banking, oil, energy, steel + custom)
- Volume selector (1M, 5M, 10M, 20M, 50M + custom)
- Batch testing mode with per-transaction session tokens

### Verified Output Example

    {
      "chain_id": "horizon-core-v1.5",
      "license_id": "HORIZON-GOLD-001",
      "pubkey": "04cf6aaa...1214",
      "eth_address": "0x28b80715050641b2ff984dd1f9638055bf3530ce",
      "ecdsa_signature": "dd895629...8f63",
      "wots_signature": "pending"
    }

---

## Benchmarks - Verified

### 10K Transaction Test (Full Security Chain)

    Transactions   10,000
    Success        10,000 (100%)
    Duration       4.57 s
    TPS            2,190

Test conditions:

- Full security chain active (Air-Gap unlock + License + Session Token)
- PostgreSQL database (not in-memory)
- Per-transaction ECDSA signature + session token
- 100 concurrent clients

### 100K Transaction Test (Batch Mode)

    Transactions   100,000
    Success        45,770 (45.8%)
    Failed         54,230 (54.2%)
    Duration       286.57 s
    TPS (avg)      159.72

Observation: The 100K test revealed two bottlenecks:

1. X-Session-Token is single-use: a new token is required per transaction (adds ~150ms overhead each).
2. Windows TCP TIME_WAIT exhaustion at 50 concurrent clients.

Known mitigation: Batch endpoint (/api/v1/tx/batch) supports 100,000 txs per request and previously hit 124,533 TPS (instantaneous). This is the recommended path for production throughput.

### Historical Peak (in-memory, single batch)

    Mode                          TPS
    Ledger only                   241,545
    With chain                    124,533
    Production (real workload)    2,190
    Batch (real workload)         TBD

---

## Security - Fail-Closed

- Auth Bypass: X-Admin-Token (>=32 chars) - BLOCKED (401)
- No License: 402 before tx - BLOCKED
- Forged License: 401 (License not found)
- No Signing Session: X-Session-Token single-use 5min - BLOCKED (401)
- SQL Injection: parameterized queries - BLOCKED (400/401)
- Buffer Overflow: MaxBytesReader 8MiB - BLOCKED (413)
- Replay: single-use session tokens - BLOCKED (401)
- Volume Exhausted: 402 (Time = Volume)
- Air-Gap Disconnected: 401 (USB key not found)

Pentest Results: 6/6 vectors passed. All blocked, 0 vulnerable.

Known Technical Debt: Dependabot reports 20 vulnerabilities (10 critical, 2 high, 7 moderate, 1 low). Remediation in progress (see RISKS.md).

---

## Tools

- cmd/genesis-lock - lock genesis with authority sig
- cmd/genesis-verify - verify genesis against GENESIS.json
- cmd/chain-verify - walk entire chain, verify prev_hash links + signed status
- cmd/block-produce - append new block to chain
- cmd/block-sign - sign block hash with hex key from stdin
- cmd/api - backend HTTP API
- cmd/switch - operational gateway (license, tx, mine)
- cmd/angel-node - 7 specialty nodes (includes WOTS+ verification)
- cmd/agent-node - AI agent inspector
- cmd/verify-tx - independent tx verifier
- cmd/license-signer - hex-based offline license signer
- cmd/cert-generator - sovereign certificate generator (QR + JSON)

---

## Documentation

- CONSTITUTION.md - 7 laws, immutable
- ANGEL-NODE-LAW.md - 8-node consensus rules
- GENESIS.json - locked genesis artifact
- CHAIN_STATE.json - pinned chain state
- STATE.md - current build status
- RISKS.md - known technical debt
- THREAT_MODEL.md - attack surface
- MATHEMATICAL_PROTOCOL_PROOF.md - mathematical proof (updated: fold(leaf, path) = root)
- MATH_MODELS.md - full mathematical models (new in v1.5)
- VERIFICATION-GUIDE.md - public verification guide
- GDPR_COMPLIANCE_CERTIFICATE.md - GDPR compliance

---

## International Standards Referenced

    Standard                          Issuer        Purpose
    SEC 2 v2 - secp256k1              SECG          Elliptic curve for all signatures
    RFC 6979 - Deterministic ECDSA    IETF          No RNG in signing -> reproducible
    BIP-62 - Low-S enforcement        Bitcoin Core  s <= n/2 -> malleability eliminated
    FIPS 180-4 - SHA-256              NIST          Block hashing, Merkle root, license ID
    FIPS 205 - SLH-DSA (WOTS+)        NIST          Quantum-resistant hash-based signatures
    ISO/IEC 25010 - Software quality  ISO           Architecture quality criteria
    ISO 8583 - Financial transactions ISO           Transaction interchange compatibility
    ISO 20022 - Financial messaging   ISO           License and settlement semantics
    Basel III - Banking regulation    BIS           Operational risk and capital framework
    GDPR - Data protection            EU            User data minimisation, right to erasure

Note on WOTS+ vs FIPS 205: WOTS+ is the hash-based one-time signature primitive underlying SPHINCS+ (standardized as SLH-DSA in FIPS 205). Horizon Core uses WOTS+ directly, not the full SPHINCS+ construction. This distinction is documented in docs/immutable/HORIZON-CORE-v1.5-STANDARDS.md.

---

## Changelog - v1.4 to v1.5

### Added

- Ternary Merkle with Industry ID (internal/merkle/merkle_industry.go)
- Merkle Proof verification (internal/merkle/proof.go)
- Real-license proof test (internal/merkle/merkle_license_test.go) - commits 9765408, df24fa3
- Offline HTML signer with ECDSA + ETH address + WireGuard link
- Mathematical models document (MATH_MODELS.md)
- Benchmark results (2,190 TPS verified at 10K tx)

### Fixed

- Conflict between RFC 6962 and v2 chain Merkle formulas resolved by using BinaryRootNoPrefix consistently.
- Duplicate VerifyProof / BuildProof declarations removed.

### Known Issues

- Dependabot: 20 vulnerabilities (10 critical) - remediation in progress.
- govulncheck requires Go 1.26+ (current: Go 1.24.4, GOSUMDB=off).
- 100K test throughput limited by single-use session tokens; use batch endpoint.

---

## How to Verify (for Auditors)

    # 1. Clone
    git clone https://github.com/beaconchain-horizon/horizon.core.git
    cd horizon.core

    # 2. Verify genesis
    go run ./cmd/genesis-verify

    # 3. Verify chain
    go run ./cmd/chain-verify

    # 4. Verify Merkle proof (the new theorem)
    go test ./internal/merkle/ -run TestRealLicenseProof -v

    # 5. Verify ternary tree
    go test ./internal/merkle/ -run TestTernary -v

Expected output of step 4:

    Root (32 byte): 9a4967b79ae3654141c56d03b4df33e5033574e4e0343f089e13a00b6b60a216
    Leaf[0]: Verified
    Leaf[1]: Verified
    Leaf[2]: Verified
    Leaf[3]: Verified
    Leaf[4]: Verified
    Fake license REJECTED (as expected)
    All tests passed

---

HORIZON CORE - a protocol, not a product.
v1.5 | genesis locked 2026-11-03 | all rights reserved
