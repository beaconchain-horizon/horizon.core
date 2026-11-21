# Merkle Trees in Horizon Core

## Tree A — Signature Tree (OTS)
- Purpose: authorise signatures
- Leaf: hash(WOTS+ public key)
- Consumption: one per signature, never reused
- Persistence: leaf counter in wots_state

## Tree B — License Tree (Membership)
- Purpose: prove existence of license ID
- Leaf: hash(license_id || metadata_hash)
- Consumption: append-only
- Persistence: rebuildable from chain

## Why separate
1. Tree A: one-time leaves. Tree B: persistent leaves.
2. A = burn-after-use. B = append-only.
3. Leak of B does not break A.

## Ternary vs binary
- Binary = standard (RFC 8391, RFC 8554). Recommended.
- Ternary = non-standard. If used, publish hash function, security
  argument, test vectors, and reason for choice.
