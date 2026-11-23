# Writer inventory from HORIZON_V15_SOURCE.txt

| Path | Current behavior | Required disposition |
|---|---|---|
| `cmd/switch/switch.go:mineBlock` | Writes `blocks`; updates `transactions.block_index` | Replace with unified engine adapter or disable |
| `cmd/switch/switch.go:mineBlockHandler` | Writes `blocks`; builds a different consensus/Merkle/hash payload; marks queue rows synced | Replace with unified engine adapter or disable |
| `cmd/switch/license_chain.go:addChainBlock` | Writes `chain_blocks` and `chain_txes` in separate DB operations (not one transaction) | Make private helper or remove as independent writer |
| `cmd/switch/license_chain.go:appendChainTx` | Signs one event then calls `addChainBlock` | Route batch/license issuance to unified engine; other events use same core append primitive |
| `internal/chain/append.go:AppendBlock` | Writes another `blocks`/transactions/Merkle-root model in its own schema | Must be retired or made a read-only adapter; cannot remain a competing canonical writer |
| `cmd/switch/switch.go:saveLicenseHandler` | Inserts directly into `licenses` without block linkage | Route through organization batch writer; no direct insert |

## Reader/verifier split

- `cmd/verifier/main.go` reads `chain_blocks` and `licenses` and recomputes two historical block-hash formulas.
- `cmd/chain-verify/main.go` reads a separate GORM/SQLite `blocks` schema.
- `internal/chain/query.go` and related files operate on `internal/chain` model tables.

The canonical v1.5 integration must select one physical block/transaction schema and make all verifiers read that same schema. No legacy data should be copied, merged, or backfilled by inference.
