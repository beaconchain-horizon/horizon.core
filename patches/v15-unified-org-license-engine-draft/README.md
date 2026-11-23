# Horizon v1.5 — organization-scoped license blocks

## Canonical write contract

`CreateOrganizationBlockWithLicenses(db, ownerKey, organizationID, licenses)` is the sole supported writer for new v1.5 license blocks.

Each call is one SQL transaction and writes:
1. one `chain_blocks` row with one `organization_id`, `license_count = N`, and `tx_count = 1`;
2. one signed `organization.licenses.issue` event containing the exact ordered batch;
3. exactly N `licenses` rows linked to that same organization and block.

The batch event is signed by the authority key. Its transaction hash is the single Merkle leaf; the block header hash and signature cover that Merkle root. Per-license signatures are preserved. WOTS values are persisted as supplied; production issuance deliberately leaves the experimental WOTS fields empty.

## Safety gates now in place

- Direct `/license/save` writes are rejected.
- Admin license issuance uses the canonical organization writer and requires `organization_id`.
- Legacy `blocks` mining and generic `chain_blocks` append writers are disabled.
- `internal/chain.AppendBlock` is disabled as a competing writer.
- Generic batcher and unscoped industrial anchor worker are disabled.
- Direct revocation and renewal confirmation are paused until their state changes can be committed as organization-scoped events in the same transaction.
- The writer refuses any existing non-Genesis block without organization membership, exact license count, and one-event cardinality.
- PostgreSQL migration adds organization fields, constraints, a composite foreign key, and indexes without backfilling legacy rows.

## Verification and tests

The canonical `cmd/verifier` checks organization batch metadata, exact batch-to-row membership, transaction hash/signature, Merkle root, block hash/signature, and organization/block linkage. It fails closed when no canonical block rows can be loaded. `cmd/chain-verify` is explicitly labeled as a legacy SQLite audit tool, not the v1.5 verifier.

CI uses Go 1.24.4 and a disposable PostgreSQL 16 service. It validates the additive migration, tests cross-organization FK rejection, builds the chain packages, runs unit tests, exercises mid-batch rollback, and starts separate test processes to exercise PostgreSQL advisory locking.

## Critical cutover limitation

Existing history is never assigned to organizations by inference. The currently audited operational `chain_blocks` history contains non-Genesis blocks that do not have v1.5 organization membership. After the additive migration those historical rows remain `organization_id = NULL` and `license_count = 0`. The write gate therefore rejects appending v1.5 blocks to that history.

This is intentional. Do not:
- backfill organization IDs without signed, independently verified source evidence;
- rewrite Genesis or existing block hashes;
- run the migration against the operational database before a separately verified backup/clone review;
- enable the legacy writers to bypass the gate.

A production cutover decision is still required for how the existing legacy history is retained and how the canonical v1.5 chain is rooted without rewriting or duplicating Genesis. Until that decision and an end-to-end verification of the selected database are complete, production issuance, renewal, and revocation remain fail-closed.

## Operational status

No production database migration, Genesis change, history rewrite, deployment, version bump, or merge was performed by this patch work.
