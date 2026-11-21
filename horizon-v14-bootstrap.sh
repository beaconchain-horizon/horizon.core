#!/usr/bin/env bash
# Horizon Core v1.4 — isolated registry + immutable-by-default archive bootstrap
# Safe defaults: never changes the source DB; refuses to overwrite target DBs;
# creates a consistent pg_dump snapshot; does not invent ECDSA/WOTS+ signatures.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PG_BIN="${PG_BIN:-/c/Program Files/PostgreSQL/18/bin}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
SOURCE_DB="${SOURCE_DB:-horizon_switch}"
REGISTRY_DB="${REGISTRY_DB:-horizon_v14_registry}"
ARCHIVE_DB="${ARCHIVE_DB:-horizon_v14_archive}"
GENESIS_FILE="${HORIZON_GENESIS_FILE:-$ROOT/GENESIS.json}"
BACKUP_ROOT="${HORIZON_BACKUP_ROOT:-$HOME/horizon-v14-backups}"

log() { printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

for tool in psql pg_dump pg_restore createdb; do
  [[ -x "$PG_BIN/$tool.exe" ]] || die "Missing $PG_BIN/$tool.exe"
done
command -v go >/dev/null 2>&1 || die "Go is not available in PATH. Go 1.24.x is required."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."

GO_VERSION="$(go version)"
case "$GO_VERSION" in
  *"go1.24."*) ;;
  *) die "Go 1.24.x is required by project policy. Detected: $GO_VERSION" ;;
esac

[[ -f "$GENESIS_FILE" ]] || die "Genesis file not found: $GENESIS_FILE. Expected repo-root ./GENESIS.json. Set HORIZON_GENESIS_FILE if its real path differs. No database changes were made."

GENESIS_SHA256="$(sha256sum "$GENESIS_FILE" | cut -d ' ' -f 1)"
GENESIS_BYTES="$(wc -c < "$GENESIS_FILE" | tr -d '[:space:]')"
GENESIS_REL="${GENESIS_FILE#"$ROOT"/}"
[[ "$GENESIS_REL" != "$GENESIS_FILE" ]] || GENESIS_REL="$GENESIS_FILE"
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
GIT_BRANCH="$(git branch --show-current 2>/dev/null || printf 'unknown')"
STAMP="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="$BACKUP_ROOT/$STAMP"
mkdir -p "$RUN_DIR"

PSQL=("$PG_BIN/psql.exe" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -v ON_ERROR_STOP=1 -P pager=off)

log "Preflight: PostgreSQL connection and source DB"
"${PSQL[@]}" -d "$SOURCE_DB" -Atqc "SELECT 1" >/dev/null || die "Cannot connect to source database $SOURCE_DB"
REQUIRED_TABLE_COUNT="$("${PSQL[@]}" -d "$SOURCE_DB" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' AND table_name IN ('blocks','chain_blocks','chain_txes','transactions','blocks_bak_1794548568','blocks_bak_1794548606','chain_blocks_bak_1794548568','chain_blocks_bak_1794548606')")"
[[ "$REQUIRED_TABLE_COUNT" == "8" ]] || die "Expected 8 audited ledger tables, found $REQUIRED_TABLE_COUNT. No target DB has been created. Check source DB name/schema first."

log "Preflight: target DB names must not already exist"
EXISTING="$("${PSQL[@]}" -d postgres -Atqc "SELECT datname FROM pg_database WHERE datname IN ('$REGISTRY_DB','$ARCHIVE_DB') ORDER BY datname")"
[[ -z "$EXISTING" ]] || die "Target database already exists: $EXISTING. Refusing to overwrite or merge. Inspect it manually first."

log "Source information"
printf 'Repository: %s\nGenesis file: %s\nGenesis SHA-256: %s\nGenesis bytes: %s\nGo: %s\nGit: %s (%s)\nSource DB: %s@%s:%s/%s\nRegistry DB: %s@%s:%s/%s\nArchive DB: %s@%s:%s/%s\n' \
  "$ROOT" "$GENESIS_REL" "$GENESIS_SHA256" "$GENESIS_BYTES" "$GO_VERSION" "$GIT_BRANCH" "$GIT_COMMIT" \
  "$PGUSER" "$PGHOST" "$PGPORT" "$SOURCE_DB" "$PGUSER" "$PGHOST" "$PGPORT" "$REGISTRY_DB" "$PGUSER" "$PGHOST" "$PGPORT" "$ARCHIVE_DB"

DUMP_FILE="$RUN_DIR/${SOURCE_DB}_${STAMP}.dump"
DUMP_LIST="$RUN_DIR/${SOURCE_DB}_${STAMP}.dump.list"

log "1/7 — Consistent backup of ledger-only source tables (no customer/account tables)"
TABLE_ARGS=(
  -t public.blocks
  -t public.chain_blocks
  -t public.chain_txes
  -t public.transactions
  -t public.blocks_bak_1794548568
  -t public.blocks_bak_1794548606
  -t public.chain_blocks_bak_1794548568
  -t public.chain_blocks_bak_1794548606
)
"$PG_BIN/pg_dump.exe" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$SOURCE_DB" -Fc -f "$DUMP_FILE" "${TABLE_ARGS[@]}"
[[ -s "$DUMP_FILE" ]] || die "Backup file is empty: $DUMP_FILE"
"$PG_BIN/pg_restore.exe" --list "$DUMP_FILE" > "$DUMP_LIST"
[[ -s "$DUMP_LIST" ]] || die "Backup archive listing is empty."
printf 'Backup file: %s\n' "$DUMP_FILE"

log "2/7 — Create separate archive database and restore complete snapshot"
"$PG_BIN/createdb.exe" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -T template0 -E UTF8 "$ARCHIVE_DB"
"$PG_BIN/pg_restore.exe" --exit-on-error --no-owner --no-acl -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$ARCHIVE_DB" "$DUMP_FILE"

log "3/7 — Create v1.4 registry database"
"$PG_BIN/createdb.exe" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -T template0 -E UTF8 "$REGISTRY_DB"

INIT_SQL="$RUN_DIR/init_registry.sql"
cat > "$INIT_SQL" <<'SQL'
BEGIN;
CREATE SCHEMA IF NOT EXISTS v14;
CREATE SCHEMA IF NOT EXISTS archive;

CREATE TABLE v14.protocol_manifest (
  chain_id text PRIMARY KEY,
  protocol_version text NOT NULL,
  genesis_locked_date date NOT NULL,
  declared_genesis_hash char(64) NOT NULL,
  declared_block1_hash char(64) NOT NULL,
  authority_pubkey_hex text NOT NULL,
  genesis_signature_excerpt text,
  block1_signature_excerpt text,
  genesis_timestamp bigint,
  genesis_timestamp_source text NOT NULL,
  genesis_file_path text NOT NULL,
  genesis_file_sha256 char(64) NOT NULL,
  registry_database text NOT NULL,
  archive_database text NOT NULL,
  standards_review_status text NOT NULL DEFAULT 'PENDING_REVIEW',
  verification_status text NOT NULL DEFAULT 'DECLARED_NOT_CRYPTO_VERIFIED',
  source_document text NOT NULL,
  source_git_commit text NOT NULL,
  notes text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (declared_genesis_hash ~ '^[0-9a-f]{64}$'),
  CHECK (declared_block1_hash ~ '^[0-9a-f]{64}$'),
  CHECK (genesis_file_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE TABLE v14.genesis_artifact (
  chain_id text PRIMARY KEY REFERENCES v14.protocol_manifest(chain_id),
  artifact_file_name text NOT NULL,
  artifact_status text NOT NULL,
  artifact_json jsonb NOT NULL,
  missing_items text[] NOT NULL DEFAULT ARRAY[]::text[],
  captured_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE v14.artifact_registry (
  artifact_id bigserial PRIMARY KEY,
  artifact_type text NOT NULL,
  repository_path text NOT NULL,
  sha256 char(64) NOT NULL,
  size_bytes bigint NOT NULL,
  status text NOT NULL,
  registered_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (artifact_type, repository_path, sha256)
);

CREATE TABLE v14.canonical_blocks (
  chain_id text NOT NULL REFERENCES v14.protocol_manifest(chain_id),
  block_num bigint NOT NULL,
  block_timestamp bigint,
  prev_hash char(64),
  merkle_root text,
  tx_count bigint,
  block_hash char(64) NOT NULL,
  ecdsa_signature_hex text,
  wotsplus_signature_hex text,
  wotsplus_ots_key_id text,
  signer_public_key_hex text,
  verification_status text NOT NULL,
  source_kind text NOT NULL,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  inserted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, block_num),
  UNIQUE (chain_id, block_hash)
);

CREATE TABLE v14.checkpoints (
  chain_id text NOT NULL REFERENCES v14.protocol_manifest(chain_id),
  block_num bigint NOT NULL,
  expected_hash char(64) NOT NULL,
  checkpoint_status text NOT NULL,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (chain_id, block_num)
);

CREATE TABLE v14.hash_profiles (
  profile_id text PRIMARY KEY,
  algorithm text NOT NULL,
  formula text NOT NULL,
  byte_encoding text NOT NULL,
  status text NOT NULL,
  source_reference text NOT NULL,
  notes text NOT NULL
);

CREATE TABLE v14.signature_profiles (
  profile_id text PRIMARY KEY,
  algorithm text NOT NULL,
  standard_reference text NOT NULL,
  parameters jsonb NOT NULL DEFAULT '{}'::jsonb,
  key_usage_model text NOT NULL,
  signature_size_bytes bigint,
  status text NOT NULL,
  notes text NOT NULL
);

-- A WOTS+ private key is one-time. This table reserves one unique OTS key ID
-- for exactly one message target; it never stores private key material.
CREATE TABLE v14.one_time_signature_usage (
  ots_key_id text PRIMARY KEY,
  chain_id text NOT NULL REFERENCES v14.protocol_manifest(chain_id),
  algorithm text NOT NULL CHECK (algorithm IN ('WOTS+', 'XMSS-WOTS+', 'OTHER_OTS')),
  key_index bigint NOT NULL,
  target_type text NOT NULL CHECK (target_type IN ('GENESIS','BLOCK','LICENSE')),
  target_id text NOT NULL,
  message_digest_sha256 char(64) NOT NULL,
  public_key_hex text,
  signature_hex text,
  usage_status text NOT NULL,
  signed_at timestamptz,
  UNIQUE (chain_id, algorithm, key_index),
  UNIQUE (chain_id, target_type, target_id),
  CHECK (message_digest_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE TABLE v14.signature_policy (
  chain_id text PRIMARY KEY REFERENCES v14.protocol_manifest(chain_id),
  ecdsa_required boolean NOT NULL,
  wotsplus_required boolean NOT NULL,
  pqc_standard_profile text NOT NULL,
  enforcement_status text NOT NULL,
  policy_notes text NOT NULL
);

CREATE TABLE v14.verification_runs (
  run_id bigserial PRIMARY KEY,
  chain_id text NOT NULL REFERENCES v14.protocol_manifest(chain_id),
  verifier_name text NOT NULL,
  verifier_version text,
  source_tables text[] NOT NULL DEFAULT ARRAY[]::text[],
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  run_status text NOT NULL,
  blocks_checked bigint NOT NULL DEFAULT 0,
  hashes_valid bigint NOT NULL DEFAULT 0,
  signatures_valid bigint NOT NULL DEFAULT 0,
  links_valid bigint NOT NULL DEFAULT 0,
  transactions_checked bigint NOT NULL DEFAULT 0,
  report jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE v14.reconciliation_issues (
  issue_id bigserial PRIMARY KEY,
  chain_id text NOT NULL REFERENCES v14.protocol_manifest(chain_id),
  source_database text NOT NULL,
  source_table text NOT NULL,
  source_record_id text,
  source_block_num bigint,
  severity text NOT NULL,
  issue_code text NOT NULL,
  description text NOT NULL,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  issue_status text NOT NULL DEFAULT 'OPEN',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE archive.import_manifest (
  import_id bigserial PRIMARY KEY,
  source_database text NOT NULL,
  archive_database text NOT NULL,
  source_tables text[] NOT NULL,
  backup_file_path text NOT NULL,
  backup_sha256 char(64) NOT NULL,
  import_status text NOT NULL,
  source_git_commit text NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now(),
  notes text NOT NULL
);

INSERT INTO v14.protocol_manifest (
  chain_id, protocol_version, genesis_locked_date,
  declared_genesis_hash, declared_block1_hash, authority_pubkey_hex,
  genesis_signature_excerpt, block1_signature_excerpt,
  genesis_timestamp, genesis_timestamp_source, genesis_file_path,
  genesis_file_sha256, registry_database, archive_database,
  standards_review_status, verification_status, source_document,
  source_git_commit, notes
) VALUES (
  'horizon-core-v1.4', '1.4', DATE '2026-11-03',
  '8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603',
  'f981652e6c25945a2655b83f7536524441422bdeb7b9742a30a5256cd637ceba',
  '04cf6aaaba8e7a6fddde63a2e2588553dc95503d2de6b2a5c78f4a30a0b91b0aca4d28d06fc1ccbaf730abe1dcda7c29726dab18008353b521c9253c04b1641214',
  'afac005b...d236face', '19f1b567...94bd335',
  1794246431,
  'Previously observed source DB Genesis timestamp; must be cross-checked against the supplied GENESIS.json and verifier',
  :'genesis_path', :'genesis_sha256', 'horizon_v14_registry', 'horizon_v14_archive',
  'PENDING_REVIEW', 'DECLARED_NOT_CRYPTO_VERIFIED',
  'Owner-provided Horizon Core v1.4 README and root Genesis artifact',
  :'git_commit',
  'Genesis hash is the owner-declared locked anchor. The Genesis and Block #1 signature values in the README are truncated excerpts; do not mark as cryptographically verified until the complete GENESIS.json and verifier agree.'
);

INSERT INTO v14.genesis_artifact (
  chain_id, artifact_file_name, artifact_status, artifact_json, missing_items
) VALUES (
  'horizon-core-v1.4', :'genesis_path', 'FILE_PRESENT_HASH_RECORDED_CONTENT_NOT_CRYPTO_VERIFIED',
  jsonb_build_object(
    'chain_id','horizon-core-v1.4',
    'protocol_version','1.4',
    'genesis_locked_date','2026-11-03',
    'genesis_hash','8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603',
    'block_1_hash','f981652e6c25945a2655b83f7536524441422bdeb7b9742a30a5256cd637ceba',
    'authority_pubkey_hex','04cf6aaaba8e7a6fddde63a2e2588553dc95503d2de6b2a5c78f4a30a0b91b0aca4d28d06fc1ccbaf730abe1dcda7c29726dab18008353b521c9253c04b1641214',
    'genesis_signature_excerpt','afac005b...d236face',
    'block_1_signature_excerpt','19f1b567...94bd335',
    'signature_encoding','R||S',
    'signature_length_bytes',64,
    'key_format','hex only (no PEM)',
    'repository_path', :'genesis_path',
    'file_sha256', :'genesis_sha256',
    'file_size_bytes', :genesis_bytes,
    'full_file_content_loaded', false
  ),
  ARRAY[
    'Compare the complete Genesis JSON fields with the locked hash using cmd/genesis-verify',
    'Verify the complete Genesis ECDSA signature; README excerpt is truncated',
    'Verify Block #1 complete header and signature against the declared Block #1 hash',
    'Provision a real WOTS+ OTS key and signature for the Genesis message; no private key was supplied'
  ]
);

INSERT INTO v14.artifact_registry (artifact_type, repository_path, sha256, size_bytes, status)
VALUES ('GENESIS_JSON', :'genesis_path', :'genesis_sha256', :genesis_bytes, 'PRESENT_HASH_RECORDED_PENDING_VERIFICATION');

-- Genesis anchor only. No other source-chain block is promoted to canonical here.
INSERT INTO v14.canonical_blocks (
  chain_id, block_num, block_timestamp, prev_hash, merkle_root, tx_count,
  block_hash, ecdsa_signature_hex, wotsplus_signature_hex,
  wotsplus_ots_key_id, signer_public_key_hex, verification_status,
  source_kind, evidence
) VALUES (
  'horizon-core-v1.4', 0, 1794246431, repeat('0',64),
  '8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603',
  0,
  '8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603',
  NULL, NULL, NULL,
  '04cf6aaaba8e7a6fddde63a2e2588553dc95503d2de6b2a5c78f4a30a0b91b0aca4d28d06fc1ccbaf730abe1dcda7c29726dab18008353b521c9253c04b1641214',
  'OWNER_DECLARED_LOCKED_ANCHOR_PENDING_FULL_HASH_AND_SIGNATURE_VERIFICATION',
  'Owner README + source DB observation; not a verified reconstruction',
  jsonb_build_object(
    'genesis_locked_date','2026-11-03',
    'timestamp_observed_in_source_database',1794246431,
    'source_db_timestamp_is_not_independent_proof',true,
    'signature_excerpt_only',true,
    'wotsplus_signature_not_fabricated',true
  )
);

INSERT INTO v14.checkpoints (chain_id, block_num, expected_hash, checkpoint_status, evidence)
VALUES (
  'horizon-core-v1.4', 1,
  'f981652e6c25945a2655b83f7536524441422bdeb7b9742a30a5256cd637ceba',
  'OWNER_DECLARED_HASH_AWAITING_FULL_HEADER_AND_SIGNATURE',
  jsonb_build_object('source','owner README','full_header_supplied',false,'full_signature_supplied',false)
);

-- Protocol equations recorded as profiles. Code-observed formulas remain candidates
-- until the canonical verifier proves they reproduce the locked artifacts.
INSERT INTO v14.hash_profiles (profile_id, algorithm, formula, byte_encoding, status, source_reference, notes) VALUES
('BLOCK_HASH_HZBLK1_CODE_CANDIDATE','SHA-256','SHA256(UTF8("HZBLK1|" || block_num || "|" || prev_hash || "|" || merkle_root || "|" || timestamp))','UTF-8 decimal fields; hashes represented as lowercase hex text','CODE_OBSERVED_NOT_PROVEN_CANONICAL','cmd/switch/license_chain.go canonicalBlockMessage/computeBlockHash','Must reproduce Genesis and Block #1 before promoted to canonical.'),
('TX_HASH_HZTXH1_CODE_CANDIDATE','SHA-256','SHA256(UTF8("HZTXH1|" || tx_type || "|" || payload || "|" || timestamp))','UTF-8','CODE_OBSERVED_NOT_PROVEN_CANONICAL','cmd/switch/license_chain.go computeTxHash','Payload serialization and field ordering must match the verifier.'),
('TX_SIGN_HZTX1_CODE_CANDIDATE','SHA-256 digest signed by ECDSA','UTF8("HZTX1|" || tx_type || "|" || tx_id || "|" || payload || "|" || timestamp)','UTF-8','CODE_OBSERVED_NOT_PROVEN_CANONICAL','cmd/switch/license_chain.go canonicalTxMessage','Exact signed preimage must be tested against real signatures.'),
('MERKLE_BINARY_DECLARED','SHA-256','SHA256(left_node_bytes || right_node_bytes)','Raw 32-byte child hashes; odd-leaf rule must be explicitly pinned','OWNER_DECLARED_PROFILE_PENDING_VERIFICATION','README: internal/merkle/merkle.go','Do not hash textual hex unless the canonical implementation explicitly does so.'),
('MERKLE_TERNARY_DECLARED','SHA-256','SHA256(child_a_bytes || child_b_bytes || child_c_bytes)','Raw 32-byte child hashes; incomplete final group rule must be pinned','OWNER_DECLARED_PROFILE_PENDING_VERIFICATION','README: internal/merkle/ternary.go','Project-specific ternary profile; independent tests required.'),
('MERKLE_LICENSE_CHAIN_FLAT_CODE_OBSERVED','SHA-256','SHA256(UTF8(tx_hash_hex_1 || tx_hash_hex_2 || ...))','Concatenated hex text in transaction order','LEGACY_CODE_OBSERVED_NOT_CANONICAL_APPROVAL','cmd/switch/license_chain.go computeBlockMerkleRoot','This is not the declared binary Merkle rule; archive and compare, do not silently promote.'),
('TIMESTAMP_UNIX_SECONDS_DECLARED','POSIX time','timestamp = seconds since 1970-01-01T00:00:00Z','Signed 64-bit integer seconds','DECLARED_PENDING_CROSS_CHECK','time.Now().Unix() call sites and source DB observations','Timestamp is metadata in block preimage; timestamp is never a block height.');

INSERT INTO v14.signature_profiles (profile_id, algorithm, standard_reference, parameters, key_usage_model, signature_size_bytes, status, notes) VALUES
('ECDSA_SECP256K1_RFC6979_LOW_S_RAW64','ECDSA secp256k1','SEC 2 + RFC 6979 + project Low-S rule',jsonb_build_object('curve','secp256k1','nonce','RFC6979','low_s','s <= n/2','encoding','R||S','signature_bytes',64),'Reusable key subject to normal ECDSA key protection',64,'OWNER_DECLARED_PENDING_IMPLEMENTATION_AUDIT','Must verify raw R||S, low-S, deterministic nonce and public-key/address derivation.'),
('WOTS_PLUS_SHA256_N32_W16_RFC8391','WOTS+','RFC 8391 section 3.1',jsonb_build_object('n_bytes',32,'w',16,'len_1',64,'len_2',3,'chain_count',67,'signature_bytes',2144,'hash_family','SHA-256'),'ONE-TIME: a private OTS key MUST sign exactly one message',2144,'PROFILE_DECLARED_KEYS_AND_SIGNER_NOT_PROVISIONED','A unique one-time key is required for each separately signed message. Never reuse one WOTS+ private key for Genesis, blocks, or licenses.'),
('SLH_DSA_FIPS205_NOT_CONFIGURED','SLH-DSA','NIST FIPS 205',jsonb_build_object('parameter_set','NOT_SELECTED','mode','NOT_CONFIGURED'),'Stateless hash-based signature standard',NULL,'STANDARD_REFERENCE_ONLY_NOT_IMPLEMENTED','FIPS 205 is SLH-DSA based on SPHINCS+; WOTS+ alone is not a FIPS 205 implementation.');

INSERT INTO v14.signature_policy (chain_id, ecdsa_required, wotsplus_required, pqc_standard_profile, enforcement_status, policy_notes)
VALUES (
  'horizon-core-v1.4', true, true, 'SLH-DSA-FIPS205-TO-BE-SELECTED',
  'DECLARED_NOT_ENFORCED_IN_RUNNING_SWITCH',
  'Owner requested dual classical + hash-based signatures. Registry is prepared, but active enforcement requires implementation, independent test vectors, public keys, protected private-key handling, and WOTS+ one-time-key state. No fake signature or private key is generated.'
);

INSERT INTO archive.import_manifest (
  source_database, archive_database, source_tables, backup_file_path,
  backup_sha256, import_status, source_git_commit, notes
) VALUES (
  'horizon_switch', 'horizon_v14_archive',
  ARRAY['public.blocks','public.chain_blocks','public.chain_txes','public.transactions','public.blocks_bak_1794548568','public.blocks_bak_1794548606','public.chain_blocks_bak_1794548568','public.chain_blocks_bak_1794548606'],
  :'dump_path', :'dump_sha256', 'RESTORED_FULL_SNAPSHOT_READ_ONLY_BY_DEFAULT',
  :'git_commit',
  'Point-in-time pg_dump snapshot of ledger/block tables only. Customer, bank-account, tenant, key-vault and other application tables were intentionally excluded. Original source database was not modified. Archive database is configured default_transaction_read_only=on; superuser can override this guard.'
);

COMMIT;
SQL

DUMP_SHA256="$(sha256sum "$DUMP_FILE" | cut -d ' ' -f 1)"

log "4/7 — Register v1.4 Genesis anchor, math profiles, and archive manifest"
"${PSQL[@]}" -d "$REGISTRY_DB" \
  -v genesis_path="$GENESIS_REL" \
  -v genesis_sha256="$GENESIS_SHA256" \
  -v genesis_bytes="$GENESIS_BYTES" \
  -v git_commit="$GIT_COMMIT" \
  -v dump_path="$DUMP_FILE" \
  -v dump_sha256="$DUMP_SHA256" \
  -f "$INIT_SQL"

AUDIT_SQL="$RUN_DIR/archive_audit.sql"
cat > "$AUDIT_SQL" <<'SQL'
\echo '=== HORIZON SOURCE ARCHIVE: READ-ONLY AUDIT ==='
SELECT current_database() AS archive_database, now() AS audit_time;
\echo '=== SOURCE TABLE ROW COUNTS ==='
SELECT 'blocks' AS source_table, count(*) AS rows FROM public.blocks
UNION ALL SELECT 'chain_blocks', count(*) FROM public.chain_blocks
UNION ALL SELECT 'chain_txes', count(*) FROM public.chain_txes
UNION ALL SELECT 'transactions', count(*) FROM public.transactions
UNION ALL SELECT 'blocks_bak_1794548568', count(*) FROM public.blocks_bak_1794548568
UNION ALL SELECT 'blocks_bak_1794548606', count(*) FROM public.blocks_bak_1794548606
UNION ALL SELECT 'chain_blocks_bak_1794548568', count(*) FROM public.chain_blocks_bak_1794548568
UNION ALL SELECT 'chain_blocks_bak_1794548606', count(*) FROM public.chain_blocks_bak_1794548606
ORDER BY source_table;
\echo '=== HEIGHT / TIMESTAMP ANOMALIES IN LEGACY BLOCKS ==='
SELECT count(*) FILTER (WHERE block_num::bigint = timestamp) AS height_equals_timestamp,
       count(*) FILTER (WHERE block_num > 1000000) AS height_over_one_million,
       count(*) AS total_blocks
FROM public.blocks;
\echo '=== LEGACY BLOCKS LINK CHECK (NUMERIC HEIGHT ORDER) ==='
WITH ordered AS (
  SELECT block_num, hash, prev_hash,
         lag(hash) OVER (ORDER BY block_num, id) AS prior_hash
  FROM public.blocks
)
SELECT count(*) FILTER (WHERE block_num > 0 AND prior_hash IS NOT NULL AND prev_hash IS DISTINCT FROM prior_hash) AS broken_or_nonconsecutive_links,
       count(*) FILTER (WHERE block_num > 0 AND prior_hash IS NULL) AS first_row_non_genesis,
       count(*) AS ordered_rows
FROM ordered;
\echo '=== CHAIN_BLOCKS LINK CHECK ==='
WITH ordered AS (
  SELECT block_num, hash, prev_hash,
         lag(hash) OVER (ORDER BY block_num, id) AS prior_hash
  FROM public.chain_blocks
)
SELECT count(*) FILTER (WHERE block_num > 0 AND prior_hash IS NOT NULL AND prev_hash IS DISTINCT FROM prior_hash) AS broken_links,
       count(*) FILTER (WHERE block_num > 0 AND prior_hash IS NULL) AS missing_prior_rows,
       count(*) AS chain_block_rows
FROM ordered;
\echo '=== SAME-HEIGHT HASH CONFLICTS BETWEEN BLOCK TABLES ==='
SELECT count(*) AS same_height_different_hashes
FROM public.blocks b
JOIN public.chain_blocks c USING (block_num)
WHERE b.hash IS DISTINCT FROM c.hash;
\echo '=== CHAIN_TXES WITHOUT A MATCHING CHAIN_BLOCK HEIGHT ==='
SELECT count(*) AS tx_rows_without_chain_block_height
FROM public.chain_txes t
LEFT JOIN public.chain_blocks b ON b.block_num = t.block_num
WHERE b.block_num IS NULL;
\echo '=== GENESIS HASH VARIANTS ==='
SELECT 'blocks' AS source, block_num, hash FROM public.blocks WHERE block_num = 0
UNION ALL
SELECT 'chain_blocks', block_num, hash FROM public.chain_blocks WHERE block_num = 0
ORDER BY source;
\echo '=== IMPORTANT ==='
\echo 'These are structural observations only. They do NOT prove SHA-256 recomputation, Merkle correctness, ECDSA validity, WOTS+ validity, or canonical membership.'
SQL

log "5/7 — Run read-only structural audit on restored archive"
AUDIT_LOG="$RUN_DIR/archive_audit.txt"
"${PSQL[@]}" -d "$ARCHIVE_DB" -f "$AUDIT_SQL" | tee "$AUDIT_LOG"

log "6/7 — Apply archive read-only-by-default guard"
"${PSQL[@]}" -d postgres -v archive_db="$ARCHIVE_DB" -v db_user="$PGUSER" <<'SQL'
REVOKE CONNECT, TEMPORARY ON DATABASE :"archive_db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"archive_db" TO :"db_user";
ALTER DATABASE :"archive_db" SET default_transaction_read_only = on;
SQL

log "7/7 — Run complete Go test suite without changing the Go toolchain"
TEST_LOG="$RUN_DIR/go_test.log"
TEST_STATUS=0
if GOTOOLCHAIN=local go test -count=1 ./... 2>&1 | tee "$TEST_LOG"; then
  TEST_STATUS=0
else
  TEST_STATUS=$?
fi

REPORT="$RUN_DIR/bootstrap_report.txt"
cat > "$REPORT" <<EOF
HORIZON CORE v1.4 BOOTSTRAP REPORT
Run: $STAMP
Repository: $ROOT
Git branch: $GIT_BRANCH
Git commit: $GIT_COMMIT
Go: $GO_VERSION
Genesis file: $GENESIS_REL
Genesis SHA-256: $GENESIS_SHA256
Genesis bytes: $GENESIS_BYTES
Source database: $SOURCE_DB (ledger tables only; no customer/account/key-vault data copied)
Registry database: $REGISTRY_DB
Archive database: $ARCHIVE_DB
Backup dump: $DUMP_FILE
Backup SHA-256: $DUMP_SHA256
Archive audit: $AUDIT_LOG
Go test exit code: $TEST_STATUS

Database URLs (no password embedded):
postgresql://$PGUSER@$PGHOST:$PGPORT/$REGISTRY_DB
postgresql://$PGUSER@$PGHOST:$PGPORT/$ARCHIVE_DB

Genesis canonical anchor:
8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603

Block #1 declared checkpoint:
f981652e6c25945a2655b83f7536524441422bdeb7b9742a30a5256cd637ceba

WOTS+ policy: profile registered (RFC 8391 n=32, w=16, 67 chains, 2144-byte signature); no private key/signature fabricated; OTS key reuse prohibited by registry uniqueness constraints.
SLH-DSA: FIPS 205 reference registered, parameter set not selected or implemented.
Canonical promotion: Genesis declaration only; source blocks/transactions and backup-table history remain in separate archive DB. Non-ledger customer/account/key-vault tables were excluded.
EOF

cat "$REPORT"

if [[ "$TEST_STATUS" -ne 0 ]]; then
  die "Database setup/archive completed, but go test failed (exit $TEST_STATUS). Review $TEST_LOG. No source DB data was modified."
fi

log "SUCCESS — isolated v1.4 registry created, source snapshot archived, read-only-by-default guard set, Go tests passed."
printf 'Run artifacts: %s\n' "$RUN_DIR"
