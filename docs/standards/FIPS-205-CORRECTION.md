# Correction: WOTS+ is not FIPS 205

## What v1.4 said
> "WOTS+ (Winternitz OTS) · FIPS 205"

## Why wrong
- FIPS 205 = SLH-DSA (SPHINCS+).
- WOTS+ = building block inside SLH-DSA, not the standard.
- Claiming FIPS 205 for bare WOTS+ is misrepresentation.

## Correct phrasing
"WOTS+ (hash-based OTS), Merkle-tree authenticated, inspired by SLH-DSA
(FIPS 205). NOT a certified FIPS 205 implementation."
