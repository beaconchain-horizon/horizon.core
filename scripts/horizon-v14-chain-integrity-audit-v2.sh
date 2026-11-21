#!/usr/bin/env bash
set -Eeuo pipefail

# Horizon v1.4 chain integrity audit
# READ-ONLY: opens PostgreSQL transactions in READ ONLY mode and writes only a local report.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$ROOT/go.mod" ]]; then
  echo "ERROR: run this script from scripts/ or place it under the repository scripts/ directory." >&2
  exit 1
fi
cd "$ROOT"

PG="${PG:-/c/Program Files/PostgreSQL/18/bin/psql.exe}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
OUT="$HOME/horizon-v14-backups/chain-integrity-audit-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
REPORT="$OUT/chain-integrity-report.txt"

exec > >(tee "$REPORT") 2>&1

echo "===== HORIZON v1.4 CHAIN INTEGRITY AUDIT ====="
echo "Started: $(date --iso-8601=seconds 2>/dev/null || date)"
echo "Repository: $(pwd)"
echo "Branch: $(git branch --show-current 2>/dev/null || echo UNKNOWN)"
echo "Commit: $(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
echo "Report: $REPORT"
echo "DATABASE MODE: READ ONLY"
echo "SOURCE MODE: READ ONLY"
echo ""

if [[ ! -x "$PG" ]]; then
  echo "ERROR: psql not found or not executable: $PG"
  exit 2
fi

PSQL=("$PG" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -v ON_ERROR_STOP=1 -P pager=off -P footer=on)

for DB in horizon_switch horizon_v14_registry horizon_v14_archive; do
  echo "===== CONNECTION CHECK: $DB ====="
  "${PSQL[@]}" -d "$DB" -c "SELECT current_database() AS database, current_user AS role, current_setting('default_transaction_read_only') AS default_read_only;"
done

echo ""
echo "===== 1. ACTIVE SWITCH DATABASE: STRUCTURE AND COUNTS ====="
"${PSQL[@]}" -d horizon_switch <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '2s';
SELECT current_database() AS database, current_setting('transaction_read_only') AS transaction_read_only;

SELECT 'blocks' AS table_name, count(*) AS rows, min(block_num) AS min_height, max(block_num) AS max_height, count(DISTINCT block_num) AS distinct_heights FROM public.blocks
UNION ALL
SELECT 'chain_blocks', count(*), min(block_num), max(block_num), count(DISTINCT block_num) FROM public.chain_blocks
UNION ALL
SELECT 'chain_txes', count(*), min(block_num), max(block_num), count(DISTINCT block_num) FROM public.chain_txes
UNION ALL
SELECT 'transactions', count(*), min(block_index), max(block_index), count(DISTINCT block_index) FROM public.transactions
ORDER BY table_name;

SELECT tablename AS table_name, indexname, indexdef
FROM pg_indexes
WHERE schemaname='public' AND tablename IN ('blocks','chain_blocks','chain_txes','transactions')
ORDER BY tablename, indexname;

COMMIT;
SQL

echo ""
echo "===== 2. CHAIN_BLOCKS: GENESIS AND LINKAGE ====="
"${PSQL[@]}" -d horizon_switch <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '2s';

SELECT block_num, prev_hash, merkle_root, hash,
       (hash = merkle_root) AS hash_equals_merkle_root,
       (prev_hash = repeat('0',64)) AS zero_previous_hash,
       timestamp,
       to_timestamp(timestamp) AT TIME ZONE 'UTC' AS timestamp_utc,
       length(signature) AS signature_chars,
       (signer_addr IS NOT NULL AND signer_addr <> '') AS has_signer
FROM public.chain_blocks
WHERE block_num = 0;

SELECT
  count(*) AS total_blocks,
  count(*) FILTER (WHERE length(hash)=64 AND hash ~ '^[0-9a-fA-F]{64}$') AS valid_format_hashes,
  count(*) FILTER (WHERE length(prev_hash)=64 AND prev_hash ~ '^[0-9a-fA-F]{64}$') AS valid_format_prev_hashes,
  count(*) FILTER (WHERE length(signature)=128) AS 128_char_signatures,
  count(*) FILTER (WHERE signer_addr IS NULL OR signer_addr='') AS missing_signer,
  count(*) - count(DISTINCT block_num) AS duplicate_heights,
  count(*) - count(DISTINCT hash) AS duplicate_hashes
FROM public.chain_blocks;

SELECT b.block_num,
       left(b.prev_hash,16) AS actual_prev_prefix,
       left(p.hash,16) AS expected_prev_prefix,
       CASE WHEN p.block_num IS NULL THEN 'MISSING_PREVIOUS_HEIGHT'
            WHEN b.prev_hash IS DISTINCT FROM p.hash THEN 'PREV_HASH_MISMATCH'
            ELSE 'OK' END AS link_status
FROM public.chain_blocks b
LEFT JOIN public.chain_blocks p ON p.block_num = b.block_num - 1
WHERE b.block_num > 0
  AND (p.block_num IS NULL OR b.prev_hash IS DISTINCT FROM p.hash)
ORDER BY b.block_num
LIMIT 100;

SELECT gs.block_num AS missing_height
FROM generate_series(
       (SELECT min(block_num) FROM public.chain_blocks),
       (SELECT max(block_num) FROM public.chain_blocks)
     ) AS gs(block_num)
LEFT JOIN public.chain_blocks b USING (block_num)
WHERE b.block_num IS NULL
ORDER BY gs.block_num
LIMIT 100;

SELECT block_num, tx_count, timestamp,
       left(hash,16) AS hash_prefix,
       length(signature) AS signature_chars
FROM public.chain_blocks
ORDER BY block_num DESC
LIMIT 12;

COMMIT;
SQL

echo ""
echo "===== 3. CHAIN_TXES AGAINST CANONICAL HEIGHT RANGE 0..42 ====="
"${PSQL[@]}" -d horizon_switch <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '2s';

SELECT t.block_num,
       count(*) AS stored_chain_txs,
       COALESCE(b.tx_count,0) AS declared_block_tx_count,
       count(*)::bigint - COALESCE(b.tx_count,0)::bigint AS count_delta
FROM public.chain_txes t
LEFT JOIN public.chain_blocks b ON b.block_num=t.block_num
WHERE t.block_num BETWEEN 0 AND 42
GROUP BY t.block_num, b.tx_count
ORDER BY t.block_num;

SELECT
  count(*) FILTER (WHERE block_num BETWEEN 0 AND 42) AS tx_rows_in_chain_0_42,
  count(DISTINCT tx_id) FILTER (WHERE block_num BETWEEN 0 AND 42) AS distinct_tx_ids_in_chain_0_42,
  count(*) FILTER (WHERE tx_id IS NULL OR tx_id='') AS missing_tx_ids,
  count(*) FILTER (WHERE tx_hash IS NULL OR tx_hash='') AS missing_tx_hashes,
  count(*) - count(DISTINCT tx_id) AS duplicate_tx_ids
FROM public.chain_txes;

SELECT block_num, count(*) AS tx_rows
FROM public.chain_txes
WHERE block_num BETWEEN 0 AND 42
GROUP BY block_num
ORDER BY block_num;

COMMIT;
SQL

echo ""
echo "===== 4. LEGACY blocks VS chain_blocks: OVERLAP AND CONFLICTS ====="
"${PSQL[@]}" -d horizon_switch <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '2s';

SELECT
  count(*) AS overlapping_heights,
  count(*) FILTER (WHERE b.hash IS NOT NULL AND c.hash IS NOT NULL AND b.hash=c.hash) AS same_hash,
  count(*) FILTER (WHERE b.hash IS DISTINCT FROM c.hash) AS different_or_missing_hash,
  count(*) FILTER (WHERE b.prev_hash IS DISTINCT FROM c.prev_hash) AS different_or_missing_prev_hash,
  count(*) FILTER (WHERE b.tx_count IS DISTINCT FROM c.tx_count) AS different_tx_count
FROM public.blocks b
JOIN public.chain_blocks c ON c.block_num=b.block_num;

SELECT b.block_num,
       left(b.hash,16) AS blocks_hash_prefix,
       left(c.hash,16) AS chain_blocks_hash_prefix,
       left(b.prev_hash,16) AS blocks_prev_prefix,
       left(c.prev_hash,16) AS chain_prev_prefix,
       b.tx_count AS blocks_tx_count,
       c.tx_count AS chain_tx_count
FROM public.blocks b
JOIN public.chain_blocks c ON c.block_num=b.block_num
WHERE b.hash IS DISTINCT FROM c.hash
   OR b.prev_hash IS DISTINCT FROM c.prev_hash
   OR b.tx_count IS DISTINCT FROM c.tx_count
ORDER BY b.block_num
LIMIT 100;

SELECT block_num, left(prev_hash,16) AS prev_prefix,
       left(hash,16) AS hash_prefix, left(merkle_root,16) AS merkle_prefix,
       tx_count, timestamp, length(signature) AS signature_chars,
       (signer_addr IS NOT NULL AND signer_addr<>'') AS has_signer
FROM public.blocks
ORDER BY block_num DESC
LIMIT 15;

COMMIT;
SQL

echo ""
echo "===== 5. SEPARATE transactions TABLE: COUNTS ONLY ====="
"${PSQL[@]}" -d horizon_switch <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '2s';

SELECT count(*) AS transaction_rows,
       count(DISTINCT tx_id) AS distinct_tx_ids,
       count(*) FILTER (WHERE tx_id IS NULL OR tx_id='') AS missing_tx_ids,
       count(*) FILTER (WHERE synced IS TRUE) AS synced_rows,
       count(*) FILTER (WHERE synced IS FALSE) AS unsynced_rows,
       count(*) FILTER (WHERE block_index < 0) AS negative_block_index_rows,
       min(block_index) AS min_block_index,
       max(block_index) AS max_block_index
FROM public.transactions;

SELECT block_index, synced, count(*) AS rows
FROM public.transactions
GROUP BY block_index, synced
ORDER BY block_index, synced
LIMIT 100;

COMMIT;
SQL

echo ""
echo "===== 6. ARCHIVE SNAPSHOT COMPARISON (COUNTS ONLY) ====="
"${PSQL[@]}" -d horizon_v14_archive <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '2s';
SELECT current_database() AS database, current_setting('transaction_read_only') AS transaction_read_only;
SELECT 'blocks' AS table_name, count(*) AS rows FROM public.blocks
UNION ALL SELECT 'chain_blocks', count(*) FROM public.chain_blocks
UNION ALL SELECT 'chain_txes', count(*) FROM public.chain_txes
UNION ALL SELECT 'transactions', count(*) FROM public.transactions
ORDER BY table_name;
COMMIT;
SQL

echo ""
echo "===== 7. v1.4 REGISTRY TABLE INVENTORY ====="
"${PSQL[@]}" -d horizon_v14_registry <<'SQL'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '2s';
SELECT table_name
FROM information_schema.tables
WHERE table_schema='public' AND table_type='BASE TABLE'
ORDER BY table_name;
COMMIT;
SQL

echo ""
echo "===== 8. SOURCE DIFF / PATCH STATUS (READ ONLY) ====="
git diff --check || true
git status --short

echo ""
echo "===== AUDIT COMPLETE ====="
echo "No database writes were issued. No source files were modified."
echo "Report: $REPORT"
