# Horizon WOTS+ RFC 8391 primitive (experimental)

This package implements the RFC 8391 WOTSP-SHA2_256 parameter profile:
`n=32`, `w=16`, `len=67`, and 2144-byte WOTS+ public keys and signatures.
It uses SHA-256 with RFC domain-separation prefixes, PRF-derived secret chain
values, and an RFC-format 32-byte ADRS value.

## Safety boundary

WOTS+ is a **one-time** signature scheme. `PrivateKey.SignOnce` prevents a
second call on the same in-memory object, but this package has no persistent,
crash-safe, rollback-resistant index allocator. Copying/restoring process
memory or recreating a key object from the same secret seed can defeat that
guard. The private seed is intentionally not serializable by this package.

This package is therefore a cryptographic primitive and test milestone only.
It is NOT connected to license signing, block signing, genesis, consensus, or
the production Switch. Production multi-signature use requires a complete
XMSS/XMSSMT state manager with persistent atomic index reservation, rollback
protection, Merkle tree/root handling, and authentication paths, plus external
interoperability test vectors and independent review.

The included tests cover round-trip signing, tampering, address separation,
public-key reconstruction, input validation, and an
in-process one-use guard. These tests are not a substitute for RFC 8391
interoperability vectors or a cryptographic audit.
