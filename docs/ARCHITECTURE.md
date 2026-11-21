# Architecture — Node Roles

Horizon runs 8 service nodes on ports 9001–9008, plus 1 Guardian inspector.

| Port | Node    | Role                              | Consensus |
|------|---------|-----------------------------------|-----------|
| 9001 | Merkle  | SHA-256(left‖right)               | YES (CRITICAL) |
| 9002 | Hash    | SHA-256(header)                   | YES (CRITICAL) |
| 9003 | ECDSA   | secp256k1 + WOTS+ verify          | YES (CRITICAL) |
| 9004 | Type    | binary / ternary policy           | YES (CRITICAL) |
| 9005 | Volume  | used < volume                     | YES (MAJORITY) |
| 9006 | Time    | fail-closed on exhaustion         | YES (MAJORITY) |
| 9007 | User    | user_id match                     | YES (MAJORITY) |
| 9008 | Guardian| veto — not a consensus vote       | NO (INSPECTOR) |

## PBFT math
- Voting nodes n = 7 (Guardian excluded)
- Tolerated Byzantine f = floor((n-1)/3) = 2
- Quorum 2f+1 = 5 of 7

> v1.4 heading said "9 nodes" but listed 8 roles.
> This document fixes: 8 services, 7 voting, 1 inspector.

## Independence requirement
PBFT is meaningful only if the 7 voting nodes are operationally
independent (separate hosts, admins, networks).
