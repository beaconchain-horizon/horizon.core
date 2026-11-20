# WOTS/XMSS implementation status — Horizon Core v1.4

Status: **NOT PRODUCTION READY; NOT ACTIVE**.

The current `internal/crypto/wots` package is an experimental hash-chain construction. The available source does not establish conformance with RFC 8391 WOTS+ or a complete XMSS/XMSSMT construction. In particular, it does not implement an XMSS Merkle tree, authentication paths, persistent one-time signing index, or rollback-resistant state management.

Production license issuance therefore leaves `WOTSSignature` and `WOTSPubKey` empty and preserves the existing ECDSA signature path. The hard-coded fallback seed and the hard-coded `D:/pqkey.txt` read have been removed from this production issuance path. No USB key or seed file is read by this phase.

Do not enable this package for production signing. A future post-quantum migration requires a vetted RFC 8391 implementation (or another explicitly selected NIST-standardized scheme), a parameter-set decision, independent test vectors, state persistence and rollback protection, key lifecycle procedures, and an authority-transition checkpoint. Historical ECDSA-signed blocks and licenses must not be rewritten or re-signed.
