#!/usr/bin/env bash
# Horizon v1.4 Phase 2 forensic audit — read-only only.
# No source changes, no database writes, no private payloads or credentials printed.
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

PG="${PG:-/c/Program Files/PostgreSQL/18/bin/psql.exe}"
if [[ ! -x "$PG" ]]; then
  echo "ERROR: psql.exe not found: $PG" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_ROOT="${HORIZON_AUDIT_DIR:-$HOME/horizon-v14-backups}"
OUT="$BACKUP_ROOT/phase2-forensic-audit-$STAMP"
mkdir -p "$OUT"
REPORT="$OUT/phase2-forensic-report.txt"

# Capture all terminal output in the report and keep it visible.
exec > >(tee "$REPORT") 2>&1

PSQL_BASE=("$PG" -X -v ON_ERROR_STOP=1 -P pager=off -P footer=on -h localhost -p 5432 -U postgres)
run_sql() {
  local db="$1"; shift
  "${PSQL_BASE[@]}" -d "$db" "$@"
}

section() { printf '\n\n===== %s =====\n' "$1"; }

section "HORIZON v1.4 PHASE 2 FORENSIC AUDIT"
echo "Started: $(date -Is)"
echo "Repository: $ROOT"
echo "Branch: $(git branch --show-current 2>/dev/null || echo unknown)"
echo "Commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
echo "Go: $(go version 2>/dev/null || echo unavailable)"
echo "Output: $OUT"
echo "SOURCE MODE: READ ONLY"
echo "DATABASE MODE: READ ONLY TRANSACTIONS"

section "1. DATABASE CONNECTION AND SESSION READ-ONLY CHECK"
for DB in horizon_switch horizon_v14_registry horizon_v14_archive; do
  echo "--- $DB ---"
  run_sql "$DB" -c "SELECT current_database() AS database, current_user AS role, current_setting('default_transaction_read_only') AS default_read_only;"
done

section "2. REGISTRY DATABASE — ALL USER SCHEMAS AND RELATIONS"
run_sql horizon_v14_registry <<'SQL'
BEGIN READ ONLY;
SELECT n.nspname AS schema_name,
       c.relname AS relation_name,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned_table'
         WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized_view' WHEN 'f' THEN 'foreign_table'
         ELSE c.relkind::text END AS relation_type,
       c.reltuples::bigint AS estimated_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND c.relkind IN ('r','p','v','m','f')
ORDER BY n.nspname,c.relname;
SELECT n.nspname AS schema_name,
       count(*) FILTER (WHERE c.relkind IN ('r','p')) AS table_count,
       count(*) FILTER (WHERE c.relkind IN ('v','m')) AS view_count
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND c.relkind IN ('r','p','v','m','f')
GROUP BY n.nspname ORDER BY n.nspname;
COMMIT;
SQL

section "3. ARCHIVE — SCHEMAS, TABLE COUNTS, AND READ-ONLY STATUS"
run_sql horizon_v14_archive <<'SQL'
BEGIN READ ONLY;
SELECT current_database() AS database,
       current_setting('transaction_read_only') AS transaction_read_only;
SELECT n.nspname AS schema_name, c.relname AS relation_name,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned_table'
         WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized_view' ELSE c.relkind::text END AS relation_type,
       c.reltuples::bigint AS estimated_rows
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND c.relkind IN ('r','p','v','m')
ORDER BY n.nspname,c.relname;
SELECT 'blocks' AS table_name, count(*) AS rows FROM public.blocks
UNION ALL SELECT 'chain_blocks', count(*) FROM public.chain_blocks
UNION ALL SELECT 'chain_txes', count(*) FROM public.chain_txes
UNION ALL SELECT 'transactions', count(*) FROM public.transactions
ORDER BY table_name;
COMMIT;
SQL

section "4. SWITCH DATABASE — BLOCK TABLE HEIGHT DISTRIBUTION"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout='120s';
SELECT 'blocks' AS table_name, count(*) AS rows,
       min(block_num) AS min_block_num, max(block_num) AS max_block_num,
       count(*) FILTER (WHERE block_num BETWEEN 0 AND 326) AS rows_0_326,
       count(*) FILTER (WHERE block_num >= 1000000000) AS timestamp_like_heights
FROM public.blocks
UNION ALL
SELECT 'chain_blocks', count(*), min(block_num), max(block_num),
       count(*) FILTER (WHERE block_num BETWEEN 0 AND 326),
       count(*) FILTER (WHERE block_num >= 1000000000)
FROM public.chain_blocks;
SELECT block_num, left(prev_hash,16) AS prev_prefix, left(hash,16) AS hash_prefix,
       left(merkle_root,16) AS merkle_prefix, tx_count, timestamp,
       length(signature) AS signature_chars, (coalesce(signer_addr,'') <> '') AS has_signer
FROM public.blocks
WHERE block_num < 0 OR block_num > 326
ORDER BY block_num;
WITH ordered AS (
  SELECT block_num, hash, prev_hash,
         lag(block_num) OVER (ORDER BY block_num) AS prior_num,
         lag(hash) OVER (ORDER BY block_num) AS prior_hash
  FROM public.blocks WHERE block_num BETWEEN 0 AND 326
)
SELECT count(*) AS rows_0_326,
       min(block_num) AS min_height, max(block_num) AS max_height,
       count(DISTINCT block_num) AS distinct_heights,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1) AS adjacent_height_pairs,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1 AND prev_hash=prior_hash) AS linked_adjacent_pairs,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1 AND prev_hash<>prior_hash) AS broken_adjacent_pairs
FROM ordered;
COMMIT;
SQL

section "5. CHAIN_BLOCKS — GENESIS, LINKAGE, AND BASIC SHAPE"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout='120s';
SELECT block_num, prev_hash, merkle_root, hash,
       (hash=merkle_root) AS hash_equals_merkle_root,
       (prev_hash=repeat('0',64)) AS zero_previous_hash,
       timestamp, to_timestamp(timestamp) AT TIME ZONE 'UTC' AS timestamp_utc,
       length(signature) AS signature_chars,
       (coalesce(signer_addr,'') <> '') AS has_signer
FROM public.chain_blocks WHERE block_num=0;
WITH ordered AS (
  SELECT block_num,hash,prev_hash,
         lag(block_num) OVER (ORDER BY block_num) AS prior_num,
         lag(hash) OVER (ORDER BY block_num) AS prior_hash
  FROM public.chain_blocks
)
SELECT count(*) AS total_blocks,
       count(*) FILTER (WHERE hash ~ '^[0-9a-fA-F]{64}$') AS valid_format_hashes,
       count(*) FILTER (WHERE prev_hash ~ '^[0-9a-fA-F]{64}$') AS valid_format_prev_hashes,
       count(*) FILTER (WHERE length(signature)=128) AS sig_128_chars,
       count(*) FILTER (WHERE coalesce(signer_addr,'')='') AS missing_signer,
       count(DISTINCT block_num) AS distinct_heights,
       count(DISTINCT hash) AS distinct_hashes,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1 AND prev_hash=prior_hash) AS linked_adjacent_pairs,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1 AND prev_hash<>prior_hash) AS broken_adjacent_pairs
FROM ordered;
COMMIT;
SQL

section "6. BLOCKS VS CHAIN_BLOCKS — OVERLAP AND CONFLICT SUMMARY"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SELECT count(*) AS overlapping_heights,
       count(*) FILTER (WHERE b.hash=c.hash) AS same_hash,
       count(*) FILTER (WHERE b.hash IS DISTINCT FROM c.hash) AS different_or_missing_hash,
       count(*) FILTER (WHERE b.prev_hash IS DISTINCT FROM c.prev_hash) AS different_or_missing_prev_hash,
       count(*) FILTER (WHERE b.tx_count IS DISTINCT FROM c.tx_count) AS different_tx_count
FROM public.blocks b JOIN public.chain_blocks c ON c.block_num=b.block_num;
SELECT b.block_num,
       left(b.hash,16) AS blocks_hash_prefix,
       left(c.hash,16) AS chain_blocks_hash_prefix,
       b.tx_count AS blocks_tx_count, c.tx_count AS chain_tx_count
FROM public.blocks b JOIN public.chain_blocks c ON c.block_num=b.block_num
WHERE b.hash IS DISTINCT FROM c.hash OR b.prev_hash IS DISTINCT FROM c.prev_hash
ORDER BY b.block_num LIMIT 60;
COMMIT;
SQL

section "7. CHAIN_TXES — ROW DISTRIBUTION AND CHAIN MEMBERSHIP"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout='180s';
SELECT count(*) AS total_rows,
       count(DISTINCT tx_id) AS distinct_tx_ids,
       count(DISTINCT block_num) AS distinct_block_numbers,
       min(block_num) AS min_block_num, max(block_num) AS max_block_num,
       count(*) FILTER (WHERE block_num BETWEEN 1 AND 42) AS rows_1_42,
       count(*) FILTER (WHERE block_num NOT BETWEEN 1 AND 42) AS rows_outside_1_42,
       count(*) FILTER (WHERE block_num >= 1000000000) AS timestamp_like_block_numbers
FROM public.chain_txes;
SELECT block_num, count(*) AS stored_chain_txs,
       max(c.tx_count) AS declared_block_tx_count,
       count(*)-max(c.tx_count) AS count_delta
FROM public.chain_txes t
LEFT JOIN public.chain_blocks c ON c.block_num=t.block_num
GROUP BY block_num
ORDER BY count(*) DESC, block_num
LIMIT 30;
SELECT count(*) AS chain_tx_rows,
       count(*) FILTER (WHERE c.block_num IS NULL) AS rows_without_chain_block,
       count(*) FILTER (WHERE c.block_num IS NOT NULL) AS rows_with_chain_block
FROM public.chain_txes t
LEFT JOIN public.chain_blocks c ON c.block_num=t.block_num;
COMMIT;
SQL

section "8. TRANSACTIONS QUEUE — COUNTS ONLY"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SELECT count(*) AS transaction_rows,
       count(DISTINCT tx_id) AS distinct_tx_ids,
       count(*) FILTER (WHERE synced) AS synced_rows,
       count(*) FILTER (WHERE NOT synced) AS unsynced_rows,
       count(*) FILTER (WHERE block_index=-1) AS negative_block_index_rows,
       min(block_index) AS min_block_index, max(block_index) AS max_block_index
FROM public.transactions;
SELECT block_index,synced,count(*) AS rows
FROM public.transactions GROUP BY block_index,synced ORDER BY block_index,synced;
COMMIT;
SQL

section "9. SOURCE CALL GRAPH — MODEL AND WRITE LOCATIONS"
echo "--- Block / ChainBlock declarations ---"
grep -Rni --include='*.go' --exclude-dir=vendor -E 'type (Block|ChainBlock|ChainTx) struct' cmd/switch internal 2>/dev/null || true
echo "--- Writes and initialization entry points ---"
grep -Rni --include='*.go' --exclude-dir=vendor -E 'db\.Create\(&?(block|newBlock)|Create\(block\)|addChainBlock\(|appendChainTx\(|mineBlockHandler|initLicenseChain\(|ensureChainGenesis\(' cmd/switch 2>/dev/null | head -n 160 || true
echo "--- License-chain block / transaction implementation (source excerpts) ---"
if [[ -f cmd/switch/license_chain.go ]]; then
  sed -n '110,245p' cmd/switch/license_chain.go
  sed -n '350,435p' cmd/switch/license_chain.go
fi
echo "--- Main block mining handler (source excerpt) ---"
if [[ -f cmd/switch/switch.go ]]; then
  MINE_LINE="$(grep -n '^func mineBlockHandler' cmd/switch/switch.go | head -n 1 | cut -d: -f1 || true)"
  if [[ -n "$MINE_LINE" ]]; then
    MINE_END=$((MINE_LINE + 200))
    sed -n "${MINE_LINE},${MINE_END}p" cmd/switch/switch.go
  else
    echo "mineBlockHandler declaration not found"
  fi
fi
echo "--- Database open / dialect guard ---"
grep -n -A34 -B4 -E 'func openDB|func configureSQLite' cmd/switch/db_open.go cmd/switch/db.go 2>/dev/null || true

echo "--- Genesis constants from source artifact (public fields only) ---"
if [[ -f GENESIS.json ]]; then
  grep -nE 'chain_id|genesis_hash|timestamp|locked_at' GENESIS.json || true
  sha256sum GENESIS.json
else
  echo "GENESIS.json not found at repository root"
fi

section "10. PATCH AND TEST STATUS (NO MUTATIONS)"
git diff --check || true
git status --short

echo ""
echo "===== AUDIT COMPLETE ====="
echo "No database writes were issued. No source files were modified by this script."
echo "Report: $REPORT"
