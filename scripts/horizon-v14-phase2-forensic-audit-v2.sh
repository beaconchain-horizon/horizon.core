#!/usr/bin/env bash
# Horizon v1.4 Phase 2 forensic audit v2 — read-only only.
# Fixes the v1 CTE projection bug and inspects actual registry schemas safely.
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
OUT="$BACKUP_ROOT/phase2-forensic-audit-v2-$STAMP"
mkdir -p "$OUT"
REPORT="$OUT/phase2-forensic-report-v2.txt"
exec > >(tee "$REPORT") 2>&1

PSQL_BASE=("$PG" -X -v ON_ERROR_STOP=1 -P pager=off -P footer=on -h localhost -p 5432 -U postgres)
run_sql() {
  local db="$1"; shift
  "${PSQL_BASE[@]}" -d "$db" "$@"
}
section() { printf '\n\n===== %s =====\n' "$1"; }

section "HORIZON v1.4 PHASE 2 FORENSIC AUDIT v2"
echo "Started: $(date -Is)"
echo "Repository: $ROOT"
echo "Branch: $(git branch --show-current 2>/dev/null || echo unknown)"
echo "Commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
echo "Go: $(go version 2>/dev/null || echo unavailable)"
echo "Output: $OUT"
echo "SOURCE MODE: READ ONLY"
echo "DATABASE MODE: READ ONLY TRANSACTIONS"
echo "GENESIS REFERENCE: horizon-core-v1.4 / 8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"

section "1. DATABASE CONNECTION CHECK"
for DB in horizon_switch horizon_v14_registry horizon_v14_archive; do
  echo "--- $DB ---"
  run_sql "$DB" -c "SELECT current_database() AS database, current_user AS role, current_setting('default_transaction_read_only') AS default_read_only;"
done

section "2. REGISTRY — REAL ROW COUNTS AND COLUMN INVENTORY"
run_sql horizon_v14_registry <<'SQL'
BEGIN READ ONLY;
SELECT n.nspname AS schema_name, c.relname AS relation_name,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned_table'
         WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized_view' ELSE c.relkind::text END AS relation_type
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname IN ('v14','archive') AND c.relkind IN ('r','p','v','m')
ORDER BY n.nspname,c.relname;
DO $audit$
DECLARE r record; n bigint;
BEGIN
  FOR r IN
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_schema IN ('v14','archive') AND table_type='BASE TABLE'
    ORDER BY table_schema,table_name
  LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I',r.table_schema,r.table_name) INTO n;
    RAISE NOTICE 'REGISTRY_ROW_COUNT|%.%|%',r.table_schema,r.table_name,n;
  END LOOP;
END
$audit$;
SELECT table_schema,table_name,ordinal_position,column_name,data_type
FROM information_schema.columns
WHERE table_schema IN ('v14','archive')
ORDER BY table_schema,table_name,ordinal_position;
COMMIT;
SQL

section "3. REGISTRY — SAFE GENESIS AND PROTOCOL METADATA ONLY"
run_sql horizon_v14_registry <<'SQL'
BEGIN READ ONLY;
SELECT 'protocol_manifest' AS source,
       COALESCE(j->>'chain_id','') AS chain_id,
       COALESCE(j->>'genesis_hash','') AS genesis_hash,
       COALESCE(j->>'protocol_version',j->>'version','') AS protocol_version,
       COALESCE(j->>'status',j->>'verification_status','') AS status,
       COALESCE(j->>'timestamp',j->>'created_at','') AS recorded_time
FROM (SELECT to_jsonb(t) AS j FROM v14.protocol_manifest t) q;
SELECT 'canonical_blocks' AS source,
       COALESCE(j->>'block_num',j->>'block_number',j->>'number',j->>'height','') AS block_number,
       COALESCE(j->>'hash',j->>'block_hash','') AS block_hash,
       COALESCE(j->>'prev_hash',j->>'previous_hash','') AS previous_hash,
       COALESCE(j->>'merkle_root','') AS merkle_root,
       COALESCE(j->>'timestamp','') AS block_timestamp,
       COALESCE(j->>'verification_status',j->>'status','') AS verification_status,
       COALESCE(length(j->>'signature'),length(j->>'ecdsa_signature'),length(j->>'ecdsa_sig'),0) AS signature_length
FROM (SELECT to_jsonb(t) AS j FROM v14.canonical_blocks t) q;
SELECT 'genesis_artifact' AS source,
       COALESCE(j->>'chain_id','') AS chain_id,
       COALESCE(j->>'genesis_hash','') AS genesis_hash,
       COALESCE(j->>'artifact_sha256',j->>'sha256','') AS artifact_sha256,
       COALESCE(j->>'timestamp',j->>'genesis_timestamp','') AS genesis_timestamp,
       COALESCE(j->>'locked_at','') AS locked_at,
       COALESCE(j->>'verification_status',j->>'status','') AS verification_status,
       COALESCE(length(j->>'signature'),length(j->>'ecdsa_signature'),length(j->>'ecdsa_sig'),0) AS signature_length
FROM (SELECT to_jsonb(t) AS j FROM v14.genesis_artifact t) q;
COMMIT;
SQL

section "4. ARCHIVE — EXACT COUNTS (READ ONLY)"
run_sql horizon_v14_archive <<'SQL'
BEGIN READ ONLY;
SELECT current_database() AS database,
       current_setting('transaction_read_only') AS transaction_read_only;
SELECT 'blocks' AS table_name,count(*) AS rows FROM public.blocks
UNION ALL SELECT 'chain_blocks',count(*) FROM public.chain_blocks
UNION ALL SELECT 'chain_txes',count(*) FROM public.chain_txes
UNION ALL SELECT 'transactions',count(*) FROM public.transactions
ORDER BY table_name;
COMMIT;
SQL

section "5. SWITCH — blocks HEIGHTS, GENESIS, AND LINKAGE"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout='180s';
SELECT 'blocks' AS table_name,count(*) AS rows,min(block_num) AS min_height,
       max(block_num) AS max_height,
       count(*) FILTER (WHERE block_num BETWEEN 0 AND 326) AS rows_0_326,
       count(*) FILTER (WHERE block_num >= 1000000000) AS timestamp_like_heights
FROM public.blocks;
SELECT block_num,prev_hash,hash,merkle_root,tx_count,timestamp,
       length(signature) AS signature_length,
       (coalesce(signer_addr,'')<>'') AS has_signer
FROM public.blocks WHERE block_num=0;
WITH ordered AS (
  SELECT block_num,hash,prev_hash,
         lag(block_num) OVER (ORDER BY block_num) AS prior_num,
         lag(hash) OVER (ORDER BY block_num) AS prior_hash
  FROM public.blocks WHERE block_num BETWEEN 0 AND 326
)
SELECT count(*) AS rows_0_326,min(block_num) AS min_height,max(block_num) AS max_height,
       count(DISTINCT block_num) AS distinct_heights,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1) AS adjacent_pairs,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1 AND prev_hash=prior_hash) AS linked_pairs,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1 AND prev_hash IS DISTINCT FROM prior_hash) AS broken_pairs
FROM ordered;
WITH ordered AS (
  SELECT block_num,hash,prev_hash,
         lag(block_num) OVER (ORDER BY block_num) AS prior_num,
         lag(hash) OVER (ORDER BY block_num) AS prior_hash
  FROM public.blocks WHERE block_num BETWEEN 0 AND 326
)
SELECT block_num,prior_num,left(prev_hash,16) AS stored_prev_prefix,
       left(prior_hash,16) AS expected_prev_prefix,left(hash,16) AS hash_prefix
FROM ordered
WHERE prior_num IS NOT NULL AND block_num=prior_num+1 AND prev_hash IS DISTINCT FROM prior_hash
ORDER BY block_num;
SELECT block_num,left(prev_hash,16) AS prev_prefix,left(hash,16) AS hash_prefix,
       tx_count,timestamp,length(signature) AS signature_length
FROM public.blocks WHERE block_num>=1000000000 ORDER BY block_num;
COMMIT;
SQL

section "6. SWITCH — chain_blocks GENESIS, SIGNATURE SHAPE, AND LINKAGE"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout='120s';
SELECT block_num,hash,merkle_root,(hash=merkle_root) AS hash_equals_merkle_root,
       prev_hash,(prev_hash=repeat('0',64)) AS zero_previous_hash,
       timestamp,to_timestamp(timestamp) AT TIME ZONE 'UTC' AS timestamp_utc,
       length(signature) AS signature_length,(coalesce(signer_addr,'')<>'') AS has_signer
FROM public.chain_blocks WHERE block_num=0;
WITH ordered AS (
  SELECT block_num,hash,prev_hash,signature,signer_addr,
         lag(block_num) OVER (ORDER BY block_num) AS prior_num,
         lag(hash) OVER (ORDER BY block_num) AS prior_hash
  FROM public.chain_blocks
)
SELECT count(*) AS total_blocks,
       count(*) FILTER (WHERE hash ~ '^[0-9a-fA-F]{64}$') AS valid_hash_formats,
       count(*) FILTER (WHERE prev_hash ~ '^[0-9a-fA-F]{64}$') AS valid_prev_hash_formats,
       count(*) FILTER (WHERE length(signature)=128) AS sig_128_chars,
       count(*) FILTER (WHERE coalesce(signer_addr,'')='') AS missing_signer,
       count(DISTINCT block_num) AS distinct_heights,
       count(DISTINCT hash) AS distinct_hashes,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1 AND prev_hash=prior_hash) AS linked_adjacent_pairs,
       count(*) FILTER (WHERE prior_num IS NOT NULL AND block_num=prior_num+1 AND prev_hash IS DISTINCT FROM prior_hash) AS broken_adjacent_pairs
FROM ordered;
SELECT block_num,left(prev_hash,16) AS actual_prev_prefix,
       left(hash,16) AS current_hash_prefix
FROM public.chain_blocks
WHERE block_num>0 AND NOT EXISTS (
  SELECT 1 FROM public.chain_blocks p
  WHERE p.block_num=public.chain_blocks.block_num-1
    AND p.hash=public.chain_blocks.prev_hash
)
ORDER BY block_num;
COMMIT;
SQL

section "7. blocks VS chain_blocks — HEIGHT-BY-HEIGHT CONFLICT SUMMARY"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SELECT count(*) AS overlapping_heights,
       count(*) FILTER (WHERE b.hash=c.hash) AS same_hash,
       count(*) FILTER (WHERE b.hash IS DISTINCT FROM c.hash) AS different_hash,
       count(*) FILTER (WHERE b.prev_hash IS DISTINCT FROM c.prev_hash) AS different_prev_hash,
       count(*) FILTER (WHERE b.tx_count IS DISTINCT FROM c.tx_count) AS different_tx_count
FROM public.blocks b JOIN public.chain_blocks c USING(block_num);
SELECT b.block_num,left(b.hash,16) AS blocks_hash_prefix,
       left(c.hash,16) AS chain_blocks_hash_prefix,
       b.tx_count AS blocks_tx_count,c.tx_count AS chain_tx_count
FROM public.blocks b JOIN public.chain_blocks c USING(block_num)
WHERE b.hash IS DISTINCT FROM c.hash OR b.prev_hash IS DISTINCT FROM c.prev_hash
ORDER BY b.block_num LIMIT 50;
COMMIT;
SQL

section "8. chain_txes — HEIGHT RANGE AND COUNTS VS chain_blocks"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout='180s';
SELECT count(*) AS total_rows,count(DISTINCT tx_id) AS distinct_tx_ids,
       count(DISTINCT block_num) AS distinct_block_numbers,
       min(block_num) AS min_block_num,max(block_num) AS max_block_num,
       count(*) FILTER (WHERE block_num BETWEEN 1 AND 42) AS rows_1_42,
       count(*) FILTER (WHERE block_num NOT BETWEEN 1 AND 42) AS rows_outside_1_42,
       count(*) FILTER (WHERE block_num>=1000000000) AS timestamp_like_block_numbers
FROM public.chain_txes;
SELECT t.block_num,count(*) AS stored_tx_rows,max(c.tx_count) AS declared_tx_count,
       count(*)-max(c.tx_count) AS delta
FROM public.chain_txes t JOIN public.chain_blocks c ON c.block_num=t.block_num
GROUP BY t.block_num ORDER BY t.block_num;
SELECT count(*) AS tx_rows_without_matching_chain_block
FROM public.chain_txes t LEFT JOIN public.chain_blocks c ON c.block_num=t.block_num
WHERE c.block_num IS NULL;
COMMIT;
SQL

section "9. transactions QUEUE — COUNTS ONLY"
run_sql horizon_switch <<'SQL'
BEGIN READ ONLY;
SELECT count(*) AS transaction_rows,count(DISTINCT tx_id) AS distinct_tx_ids,
       count(*) FILTER (WHERE synced) AS synced_rows,
       count(*) FILTER (WHERE NOT synced) AS unsynced_rows,
       count(*) FILTER (WHERE block_index=-1) AS unassigned_rows,
       min(block_index) AS min_block_index,max(block_index) AS max_block_index
FROM public.transactions;
SELECT block_index,synced,count(*) AS rows
FROM public.transactions GROUP BY block_index,synced ORDER BY block_index,synced;
COMMIT;
SQL

section "10. SOURCE — MODELS AND WRITE PATHS (READ ONLY)"
echo "--- model declarations ---"
grep -Rni --include='*.go' --exclude-dir=vendor -E 'type (Block|ChainBlock|ChainTx) struct' cmd/switch internal 2>/dev/null || true
echo "--- database opening and dialect guard ---"
grep -n -A34 -B4 -E 'func openDB|func configureSQLite' cmd/switch/db_open.go cmd/switch/db.go 2>/dev/null || true
echo "--- license-chain genesis and block write callsites ---"
grep -n -A12 -B5 -E 'func createGenesisBlock|func addChainBlock|func appendChainTx|func initLicenseChain|func ensureChainGenesis|db\.Create\(block\)' cmd/switch/license_chain.go 2>/dev/null || true
echo "--- mining handler and block persistence callsites ---"
grep -n -A18 -B5 -E 'func mineBlockHandler|db\.Create\(&block\)|db\.Create\(block\)|Updates\(map\[string\]interface\{\}\)' cmd/switch/switch.go 2>/dev/null | head -n 240 || true
echo "--- canonical Genesis public fields ---"
if [[ -f GENESIS.json ]]; then
  grep -nE 'chain_id|genesis_hash|timestamp|locked_at' GENESIS.json || true
  sha256sum GENESIS.json
else
  echo "GENESIS.json not found at repository root"
fi

section "11. FINAL SOURCE STATUS"
git diff --check || true
git status --short

echo ""
echo "===== AUDIT COMPLETE ====="
echo "No database writes were issued. No source files were modified."
echo "Report: $REPORT"
