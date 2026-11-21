# Changelog

## [v1.5-rc1] — 2026-11-21

### Security (CRITICAL)
- WOTS+ state persistence: leaf counter in DB with HMAC tamper-evidence,
  atomic reserve-before-sign, audit log.

### Documentation
- Corrected FIPS 205 labeling
- Documented Signature vs License tree separation
- Fixed 9-vs-8 node count, clarified PBFT quorum
- Added threat model

### Tooling
- Added read-only Authority verification script

### Not changed
- GENESIS.json, CHAIN_STATE.json, chain blocks — untouched.
- No key material created, read, copied, or stored.
