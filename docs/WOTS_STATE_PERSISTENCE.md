# WOTS+ State Persistence (v1.5)

## Problem in v1.4
RAM-only leaf counter = restart resets to 0 = leaf reuse = broken OTS.

## Fix
Leaf counter persisted in DB with:
1. Atomic reserve-before-sign
2. HMAC tamper-evidence
3. Monotonic CHECK constraint
4. wots_leaf_log audit trail

## State ≠ key
The counter is not a private key. DB storage is safe.
Private WOTS+ material stays on USB.

## Residual risks
- DB and HMAC key must be on separate storage
- Crash between commit and sign wastes a leaf
