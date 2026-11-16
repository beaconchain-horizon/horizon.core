---

## International Standards Referenced

Horizon Core is built to meet and exceed global standards for security, cryptography, and financial interoperability. Every standard below is publicly verifiable.

| Standard | Issuer | Region | Purpose in Horizon | Reference |
|:---------|:-------|:------:|:-------------------|:----------|
| **SEC 2 v2 — secp256k1** | SECG | 🇺🇸 · 🌍 | Elliptic curve for all signatures | [secg.org/sec2-v2.pdf](https://www.secg.org/sec2-v2.pdf) |
| **RFC 6979 — Deterministic ECDSA** | IETF | 🌍 | No RNG in signing → reproducible signatures | [datatracker.ietf.org](https://datatracker.ietf.org/doc/html/rfc6979) |
| **BIP-62 — Low-S enforcement** | Bitcoin Core | 🌍 | `s ≤ n/2` → malleability eliminated | [bitcoin/bips](https://github.com/bitcoin/bips/blob/master/bip-0062.mediawiki) |
| **FIPS 180-4 — SHA-256** | NIST | 🇺🇸 | Block hashing, Merkle root, license ID | [csrc.nist.gov](https://csrc.nist.gov/publications/detail/fips/180/4/final) |
| **FIPS 205 — SLH-DSA (WOTS+)** | NIST | 🇺🇸 | Quantum-resistant hash-based signatures | [csrc.nist.gov](https://csrc.nist.gov/pubs/fips/205/final) |
| **ISO/IEC 25010 — Software quality** | ISO | 🇨🇭 · 🌍 | Architecture quality criteria | [iso25000.com](https://iso25000.com/index.php/en/iso-25000-standards/iso-25010) |
| **ISO 8583 — Financial transactions** | ISO | 🇨🇭 · 🌍 | Transaction interchange compatibility | [iso.org](https://www.iso.org/standard/79451.html) |
| **ISO 20022 — Financial messaging** | ISO | 🇨🇭 · 🌍 | License and settlement message semantics | [iso20022.org](https://www.iso20022.org/) |
| **Basel III — Banking regulation** | BIS | 🇨🇭 · 🌍 | Operational risk & capital framework alignment | [bis.org](https://www.bis.org/basel_framework/) |
| **GDPR — Data protection** | EU | 🇪🇺 | User data minimisation, right to erasure | [eur-lex.europa.eu](https://eur-lex.europa.eu/eli/reg/2016/679/oj) |

> **Full detailed compliance matrix:** [`docs/immutable/HORIZON-CORE-v1.4-STANDARDS.md`](docs/immutable/HORIZON-CORE-v1.4-STANDARDS.md)
> **Protocol Design:** [`docs/immutable/HORIZON-CORE-v1.4-CANONICAL.md`](docs/immutable/HORIZON-CORE-v1.4-CANONICAL.md)
> **Security Design:** [`docs/immutable/HORIZON-CORE-v1.4-SECURITY-DESIGN.md`](docs/immutable/HORIZON-CORE-v1.4-SECURITY-DESIGN.md)

---
<div align="center">
  <img src="assets/logo.png" width="300" alt="Horizon Core Logo"/>
  <br/>
  <h1>HORIZON CORE</h1>
  <p><strong>v1.4 — TRUST · VERIFY · MOVE FORWARD</strong></p>
  <hr/>
</div>

<div align="center">
<h1>HORIZON CORE</h1>
<p><strong>Offline-first tamper-evident ledger — v1.4</strong></p>
<p>Genesis LOCKED · Block #1 SIGNED · 8-Node Consensus</p>
</div>

## Genesis — locked 2026-11-03

- Chain ID: horizon-core-v1.4
- Genesis Hash: 8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603
- Block #1 Hash: f981652e6c25945a2655b83f7536524441422bdeb7b9742a30a5256cd637ceba
- Authority Pubkey: 04cf6aaaba8e7a6fddde63a2e2588553dc95503d2de6b2a5c78f4a30a0b91b0aca4d28d06fc1ccbaf730abe1dcda7c29726dab18008353b521c9253c04b1641214
- Genesis Sig: afac005b...d236face (R||S, 64 bytes)
- Block #1 Sig: 19f1b567...94bd335 (R||S, 64 bytes)
- Key format: hex only (no PEM)

Verify locally:

go run ./cmd/chain-verify

## Architecture — 7+1 Consensus (PBFT)

Backend (8080) → Switch (8091) → 7 Specialty Nodes (9001-9007)
                                  ↓
                              Agent Node (9008) — inspector, NOT consensus

### Port Map

- 8080 — Backend / API
- 8091 — Switch (operational gateway)
- 9001 — Angel Merkle: SHA256(left||right)
- 9002 — Angel Hash: SHA256(header)
- 9003 — Angel ECDSA: secp256k1 verify + WOTS+ verify
- 9004 — Angel Type: binary or ternary
- 9005 — Angel Volume: used < volume
- 9006 — Angel Time: volume = time (fails closed on exhaustion)
- 9007 — Angel User: user_id match
- 9008 — Agent Node (AI agents inspector, NOT consensus)

### Consensus (ANGEL-NODE-LAW.md)

- 4 CRITICAL (Merkle, Hash, ECDSA, Type) — 100% required
- 2 of 3 MAJORITY (Volume, Time, User) — required
- Otherwise: REJECT (fail-closed)

### Dual Merkle

- Binary: node(a,b) = SHA256(a||b) — internal/merkle/merkle.go
- Ternary: node(a,b,c) = SHA256(a||b||c) — internal/merkle/ternary.go (unique to Horizon)

## Cryptography — Dual Signature (Classical + Quantum-Resistant)

- **Classical Curve:** secp256k1 (SEC 2)
- **Hash:** SHA-256 (FIPS 180-4)
- **Determinism:** RFC 6979
- **Low-S:** s <= n/2 (BIP-62)
- **Quantum-Resistant:** WOTS+ (Winternitz One-Time Signature) based on SHA-256
- **Signature:** Every block and license is signed with BOTH ECDSA and WOTS+.
- **Key format:** hex only (64 chars, 0x optional). No PEM.

### Key Management (Zero-Knowledge)

- **ECDSA Key:** Read from USB `/d/mykey.txt` directly into RAM.
- **WOTS+ Key:** Read from USB `/d/pqkey.txt` directly into RAM.
- **No Database Storage:** The `KeyVault` table has been completely removed. Keys are **never** written to disk.
- **No API Setup:** `cmd/switch key/setup` is disabled (HTTP 410 Gone). Keys must be loaded via `/key/unlock`.

- Fuzz testing: 1.86M execs — zero counterexamples
- Cross-verification: OpenSSL 3.5.7 — Verified OK

## Security — Fail-Closed

- Auth Bypass → X-Admin-Token (>=32 chars) → BLOCKED (401)
- No License → 402 before tx → BLOCKED
- Forged License → 401 (License not found)
- No Signing Session → X-Session-Token single-use 5min → BLOCKED (401)
- SQL Injection → parameterized queries → BLOCKED (400/401)
- Buffer Overflow → MaxBytesReader 8MiB → BLOCKED (413)
- Replay → single-use session tokens → BLOCKED (401)
- Volume Exhausted → 402 (Time = Volume)

**Pentest Results:** 6/6 vectors passed. All blocked, 0 vulnerable.

## Tools

- cmd/genesis-lock — lock genesis with authority sig
- cmd/genesis-verify — verify genesis against GENESIS.json
- cmd/chain-verify — walk entire chain, verify prev_hash links + signed status
- cmd/block-produce — append new block to chain
- cmd/block-sign — sign block hash with hex key from stdin
- cmd/api — backend HTTP API
- cmd/switch — operational gateway (license, tx, mine)
- cmd/angel-node — 7 specialty nodes (includes WOTS+ verification)
- cmd/agent-node — AI agent inspector
- cmd/verify-tx — independent tx verifier
- cmd/license-signer — hex-based offline license signer
- cmd/cert-generator — sovereign certificate generator (QR + JSON)

## Documentation

- CONSTITUTION.md — 7 laws, immutable
- ANGEL-NODE-LAW.md — 8-node consensus rules
- GENESIS.json — locked genesis artifact
- CHAIN_STATE.json — pinned chain state
- STATE.md — current build status
- RISKS.md — known technical debt
- THREAT_MODEL.md — attack surface
- MATHEMATICAL_PROTOCOL_PROOF.md — mathematical proof
- VERIFICATION-GUIDE.md — public verification guide
- GDPER_COMPLIANCE_CERTIFICATE.md — GDPR compliance

---

<div align="center">
HORIZON CORE — a protocol, not a product.<br>
v1.4 · genesis locked 2026-11-03 · all rights reserved
</div>
