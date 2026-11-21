# Threat Model (v1.5 draft)

## Assets
1. Chain integrity
2. Signature authority
3. Private key material
4. OTS leaf state
5. License set
6. Availability

## Adversaries
- A1 Network attacker: replay/inject → TLS, single-use sessions
- A2 Malicious client: → license gate, MaxBytesReader, param queries
- A3 DB write access: → HMAC on wots_state, leaf audit log
- A4 USB theft: → NONE at software layer (HSM required)
- A5 Malicious operator: → durable state, audit log, PBFT quorum
- A6 Quantum: → WOTS+ dual sig (requires intact tree)

## Open gaps
- USB key model not tamper-resistant
- PBFT independence not documented
- Ternary Merkle security argument not published
- Authority final string not externally reproducible
- Fuzz coverage metrics missing
