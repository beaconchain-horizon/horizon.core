# Horizon v1.5 — unified organization/license block writer (engineering draft)

This patch introduces one atomic write primitive for organization license blocks:

`CreateOrganizationBlockWithLicenses(db, ownerKey, organizationID, licenses)`

For one call it writes, in one GORM transaction:

1. one `chain_blocks` row (one organization, `license_count = N`, `tx_count = 1`),
2. one `chain_txes` event whose canonical JSON payload contains the exact ordered license batch,
3. exactly N rows in `licenses`, each linked to the same `organization_id` and `block_num`.

The block's Merkle root covers the hash of the batch event; the event payload contains the full license batch. Existing per-license signatures are preserved. The owner key signs the chain event and block using the existing `signData`, `canonicalTxMessage`, and `canonicalBlockMessage` functions. No Genesis is created or rewritten.

## Important integration status

This is an integration patch draft based on the captured `HORIZON_V15_SOURCE.txt`, not a completed repository merge. The captured source reveals at least three distinct writers (`mineBlock`, `mineBlockHandler`, `addChainBlock`/`appendChainTx`, plus `internal/chain.AppendBlock`) and separate verifier readers. The local full repository and its current uncommitted edits were not mounted in this workspace, so the legacy call sites have deliberately not been rewritten blindly.

Before enabling this writer, the integration must:

- apply the additive SQL migration to a verified backup/clone only;
- route the old license-save endpoint and every block writer through this function (or reject writes);
- disable/remove `mineBlock`, `mineBlockHandler`, `addChainBlock`, `appendChainTx`, and `internal/chain.AppendBlock` as independent writers;
- update the verifier to check `organization_id`, `license_count`, exact license membership, batch payload, Merkle root, block hash, and signatures;
- add PostgreSQL integration tests, including rollback on duplicate license IDs and injected mid-batch failures;
- run `go test -count=1 ./...` with Go 1.24.4.

Do not execute the migration against the operational database until the integration is reviewed and tested. No database was changed by producing this patch.

`models.patch` contains the required additive Go model fields. It is intentionally
separate from the engine file because those structs already exist in the source.
