#!/usr/bin/env bash
set -Eeuo pipefail

# Horizon v1.4 Phase 2C: targeted, read-only registry/source audit.
# No database writes, source edits, restarts, key reads, or payload dumps.

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run this script from inside horizon-core" >&2
  exit 1
}
cd "$ROOT"

PG="/c/Program Files/PostgreSQL/18/bin/psql.exe"
if [[ ! -x "$PG" ]]; then
  echo "ERROR: PostgreSQL psql.exe not found at: $PG" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$HOME/horizon-v14-backups/phase2c-registry-source-audit-$STAMP"
mkdir -p "$OUT"
REPORT="$OUT/phase2c-report.txt"

exec > >(tee "$REPORT") 2>&1

echo "===== HORIZON v1.4 PHASE 2C — REGISTRY + SOURCE AUDIT ====="
echo "Started: $(date -Iseconds)"
echo "Repository: $ROOT"
echo "Branch: $(git branch --show-current)"
echo "Commit: $(git rev-parse HEAD)"
echo "Go: $(go version)"
echo "Output: $OUT"
echo "DATABASE: READ ONLY TRANSACTIONS"
echo "SOURCE: READ ONLY"
echo "GENESIS: horizon-core-v1.4 / 8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"

psql_ro() {
  local db="$1"
  local sql="$2"
  echo "--- DATABASE: $db ---"
  "$PG" -X -h localhost -p 5432 -U postgres -d "$db" \
    -v ON_ERROR_STOP=1 -P pager=off -P null='[NULL]' \
    -c "BEGIN TRANSACTION READ ONLY; ${sql} ROLLBACK;"
}

HASH="8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"

cat <<'SQL'

===== 1. REGISTRY METADATA — NO SIGNATURE OR KEY MATERIAL PRINTED =====
SQL
psql_ro horizon_v14_registry "
SELECT chain_id,
       protocol_version,
       CASE WHEN btrim(COALESCE(declared_genesis_hash::text,''))='' THEN '[EMPTY]'
            ELSE left(btrim(declared_genesis_hash::text),16) END AS declared_genesis_prefix,
       (btrim(COALESCE(declared_genesis_hash::text,''))='$HASH') AS declared_genesis_matches_locked,
       CASE WHEN btrim(COALESCE(declared_block1_hash::text,''))='' THEN '[EMPTY]'
            ELSE left(btrim(declared_block1_hash::text),16) END AS declared_block1_prefix,
       genesis_timestamp,
       genesis_timestamp_unix_seconds,
       genesis_file_path,
       genesis_file_sha256,
       length(btrim(COALESCE(authority_signature_rs_hex::text,''))) AS authority_signature_chars,
       ecdsa_verification_status,
       wotsplus_status,
       fips205_status,
       standards_review_status,
       source_git_commit
FROM v14.protocol_manifest
ORDER BY created_at DESC;

SELECT chain_id, block_num, block_timestamp, block_timestamp_raw,
       left(btrim(COALESCE(prev_hash::text,'')),16) AS prev_hash_prefix,
       left(btrim(COALESCE(merkle_root::text,'')),16) AS merkle_prefix,
       left(btrim(COALESCE(block_hash::text,'')),16) AS block_hash_prefix,
       (btrim(COALESCE(block_hash::text,''))='$HASH') AS block_hash_matches_locked,
       tx_count,
       length(btrim(COALESCE(ecdsa_signature_rs_hex::text,''))) AS ecdsa_signature_chars,
       length(btrim(COALESCE(wotsplus_signature_hex,''))) AS wotsplus_signature_chars,
       length(btrim(COALESCE(signer_public_key_hex,''))) AS signer_public_key_chars,
       verification_status, source_kind
FROM v14.canonical_blocks
ORDER BY block_num;

SELECT chain_id, artifact_file_name, artifact_sha256, artifact_size_bytes,
       jsonb_typeof(artifact_json) AS artifact_json_type,
       (SELECT string_agg(k, ', ' ORDER BY k)
          FROM jsonb_object_keys(artifact_json) AS keys(k)) AS artifact_json_keys,
       COALESCE(artifact_json->>'chain_id','[EMPTY]') AS json_chain_id,
       COALESCE(artifact_json->>'timestamp', artifact_json->>'genesis_timestamp','[EMPTY]') AS json_timestamp,
       COALESCE(artifact_json->>'genesis_hash', artifact_json->>'hash','[EMPTY]') AS json_hash_value,
       length(COALESCE(artifact_json->>'signature','')) AS json_signature_chars,
       length(COALESCE(artifact_json->>'ecdsa_signature_rs_hex','')) AS json_ecdsa_signature_chars,
       signature_verification
FROM v14.genesis_artifact;

SELECT chain_id, block_num,
       left(btrim(COALESCE(expected_hash::text,'')),16) AS expected_hash_prefix,
       (btrim(COALESCE(expected_hash::text,''))='$HASH') AS matches_locked_genesis,
       checkpoint_status
FROM v14.checkpoints
ORDER BY block_num;

SELECT chain_id, ecdsa_required, wotsplus_required, fips205_required,
       enforcement_status, policy_notes
FROM v14.signature_policy;

SELECT profile_id, algorithm, standard_reference, key_usage_model,
       signature_size_bytes, status
FROM v14.signature_profiles
ORDER BY profile_id;

SELECT profile_id, algorithm, status, source_reference
FROM v14.hash_profiles
ORDER BY profile_id;

SELECT issue_id, source_database, source_table, source_record_id,
       source_block_num, severity, issue_code, issue_status
FROM v14.reconciliation_issues
ORDER BY issue_id;

SELECT import_id, source_database, archive_database, source_tables,
       backup_sha256, import_status, source_git_commit, imported_at
FROM archive.import_manifest
ORDER BY import_id;
"

cat <<'SQL'

===== 2. ARCHIVE VS ACTIVE — EXACT COUNTS ONLY =====
SQL
psql_ro horizon_v14_archive "
SELECT 'blocks' AS table_name, count(*)::bigint AS row_count FROM public.blocks
UNION ALL SELECT 'chain_blocks', count(*)::bigint FROM public.chain_blocks
UNION ALL SELECT 'chain_txes', count(*)::bigint FROM public.chain_txes
UNION ALL SELECT 'transactions', count(*)::bigint FROM public.transactions
ORDER BY table_name;
"

cat <<'SQL'

===== 3. BLOCK WRITE-PATH INVENTORY — SOURCE SNIPPETS =====
SQL
for spec in \
  "cmd/switch/switch.go:1:65" \
  "cmd/switch/switch.go:240:305" \
  "cmd/switch/switch.go:575:680" \
  "cmd/switch/switch.go:940:1000" \
  "cmd/switch/license_chain.go:75:165" \
  "cmd/switch/license_chain.go:165:250" \
  "cmd/switch/license_chain.go:375:415" \
  "internal/chain/append.go:1:180"; do
  IFS=: read -r file start end <<< "$spec"
  if [[ -f "$file" ]]; then
    echo "--- $file lines $start-$end ---"
    sed -n "${start},${end}p" "$file"
  else
    echo "--- MISSING: $file ---"
  fi
done

echo "--- all relevant Go write-path references (line references only) ---"
grep -Rni --include='*.go' --exclude-dir=vendor \
  -E 'mineBlockHandler|addChainBlock\(|appendChainTx\(|Create\(&block\)|CreateInBatches\(.*tx|AutoMigrate\(&Block|AutoMigrate\(&ChainBlock' \
  cmd/switch internal/chain || true

echo "--- API routes mentioning block mining ---"
grep -Rni --include='*.go' --exclude-dir=vendor \
  -E 'block/mine|mineBlockHandler|MineBlock' cmd/switch || true

cat <<'SQL'

===== 4. LOCKED GENESIS FILE CHECK =====
SQL
if [[ -f GENESIS.json ]]; then
  sha256sum GENESIS.json
  grep -nE '"chain_id"|"genesis_hash"|"locked_at"|"timestamp"' GENESIS.json
else
  echo "ERROR: GENESIS.json missing from repository root"
fi

echo
echo "===== 5. EXISTING GUARDS + TESTS ====="
grep -nE 'licenseChainSchemaMigrationAllowed|licenseChainGenesisBootstrapAllowed|func migrateChain|func createGenesisBlock' cmd/switch/license_chain.go || true
ls -l cmd/switch/*guard*test.go 2>/dev/null || true

echo
echo "===== 6. TARGETED SWITCH TESTS ====="
GOFLAGS='' go test -count=1 -timeout=180s ./cmd/switch

echo
echo "===== 7. DIFF CHECK AND STATUS ====="
git diff --check
git diff --stat -- cmd/switch/db.go cmd/switch/license_chain.go cmd/switch/switch.go
git status --short

echo
echo "===== PHASE 2C AUDIT COMPLETE ====="
echo "No database writes issued. No source files modified."
echo "Report: $REPORT"
