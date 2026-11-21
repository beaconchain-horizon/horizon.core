#!/usr/bin/env bash
set -Eeuo pipefail

# Horizon Core v1.4 - Phase 4H
# Freeze the known protocol identity, preserve archived datasets separately,
# and inventory the two observed ledger tables without merging or rewriting.
# Reads ONLY the already-restored Phase 4G clones from the FIRST run.
# No source DB writes, no source edits, no runtime restart, no deployment.

ROOT="$HOME/Beaconchain/horizon-core"
PG_BIN="/c/Program Files/PostgreSQL/18/bin"
PSQL="$PG_BIN/psql.exe"
BASE="$HOME/horizon-v14-backups/phase4g-full-ledger-audit-20261120_155646"
CLONE_SWITCH="hzn4g_20261120155646sw"
CLONE_REGISTRY="hzn4g_20261120155646rg"
CLONE_ARCHIVE="hzn4g_20261120155646ar"
EXPECTED_CHAIN="horizon-core-v1.4"
EXPECTED_GENESIS="8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
EXPECTED_SWITCH_DUMP="db88435a305f0e0a7b1b7ff990ff3e299cc52c4c37421658c9442024af2cbd4a"
EXPECTED_REGISTRY_DUMP="9844bf98c7f389c4dbf821acbe1d3e23d4ce62452ba0d6e0ddbc1f2fbf5173c1"
EXPECTED_ARCHIVE_DUMP="b481011645bc4cd63920f46632898df840f2810ff2e9876826ee90a126adc3d0"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$HOME/horizon-v14-protocol/phase4h-separation-lock-$STAMP"

mkdir -p "$OUT"
LOG="$OUT/phase4h-report.txt"
exec > >(tee "$LOG") 2>&1

say() { printf '\n===== %s =====\n' "$1"; }
fail() { echo "RESULT=FAIL"; echo "No source database or running service was intentionally modified."; echo "Artifacts retained: $OUT"; exit 1; }

say "HORIZON v1.4 PHASE 4H - PROTOCOL + NETWORK SEPARATION LOCK"
echo "Started: $(date -Iseconds)"
echo "Repo: $ROOT"
echo "Phase4G source archive: $BASE"
echo "Read-only clones: $CLONE_SWITCH ; $CLONE_REGISTRY ; $CLONE_ARCHIVE"
echo "Protocol ID: $EXPECTED_CHAIN"
echo "Locked Genesis: $EXPECTED_GENESIS"
echo "SOURCE DB WRITE: NONE"
echo "SOURCE CODE EDIT: NONE"
echo "RUNTIME RESTART/DEPLOY: NONE"
echo "OUTPUT: $OUT"

[[ -d "$ROOT" ]] || { echo "Repository not found"; fail; }
[[ -d "$BASE/dumps" ]] || { echo "Phase 4G dump directory not found"; fail; }
for tool in "$PSQL"; do [[ -x "$tool" ]] || { echo "Missing PostgreSQL client: $tool"; fail; }; done

say "VERIFY PRESERVED PHASE 4G DUMP ARTIFACTS"
verify_dump() {
  local name="$1" expected="$2" file="$BASE/dumps/$1.dump" actual
  [[ -s "$file" ]] || { echo "Missing or empty dump: $file"; return 1; }
  actual="$(sha256sum "$file" | awk '{print $1}')"
  echo "$name SHA256=$actual"
  [[ "$actual" == "$expected" ]] || { echo "Dump hash mismatch: $name"; return 1; }
}
verify_dump horizon_switch "$EXPECTED_SWITCH_DUMP" || fail
verify_dump horizon_v14_registry "$EXPECTED_REGISTRY_DUMP" || fail
verify_dump horizon_v14_archive "$EXPECTED_ARCHIVE_DUMP" || fail

say "DATABASE READ-ONLY PREFLIGHT"
read -r -s -p "PostgreSQL password for postgres (input hidden): " PGPASSWORD
printf '\n'
[[ -n "$PGPASSWORD" ]] || { echo "Empty password"; fail; }
export PGPASSWORD
export PGOPTIONS="-c default_transaction_read_only=on"
PSQL_BASE=("$PSQL" -X -w -h 127.0.0.1 -p 5432 -U postgres -v ON_ERROR_STOP=1 -P pager=off)

for db in "$CLONE_SWITCH" "$CLONE_REGISTRY" "$CLONE_ARCHIVE"; do
  exists="$("${PSQL_BASE[@]}" -d postgres -A -t -c "SELECT count(*) FROM pg_database WHERE datname='$db';")" || fail
  [[ "$exists" == "1" ]] || { echo "Required Phase 4G clone missing: $db"; fail; }
  ro="$("${PSQL_BASE[@]}" -d "$db" -A -t -c "SHOW default_transaction_read_only;")" || fail
  echo "$db default_transaction_read_only=$ro"
  [[ "$ro" == "on" ]] || { echo "Clone is not configured read-only: $db"; fail; }
done

say "CRITICAL LEDGER INVENTORY - READ ONLY CLONE"
"${PSQL_BASE[@]}" -d "$CLONE_SWITCH" -A -t -F '|' > "$OUT/critical-ledger-counts.tsv" <<'SQL'
SELECT 'public.blocks', count(*)::bigint FROM public.blocks;
SELECT 'public.chain_blocks', count(*)::bigint FROM public.chain_blocks;
SELECT 'public.chain_txes', count(*)::bigint FROM public.chain_txes;
SELECT 'public.transactions', count(*)::bigint FROM public.transactions;
SQL
cat "$OUT/critical-ledger-counts.tsv"

# Record only column metadata for the observed ledger streams; no transaction
# payloads, customer data, private keys, or full signatures are exported.
"${PSQL_BASE[@]}" -d "$CLONE_SWITCH" -A -t -F '|' -c \
  "SELECT table_name,column_name,data_type FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('blocks','chain_blocks','chain_txes','transactions') ORDER BY table_name,ordinal_position;" \
  > "$OUT/ledger-column-inventory.tsv" || fail

"${PSQL_BASE[@]}" -d "$CLONE_SWITCH" -c \
  "SELECT table_name,column_name,data_type FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('blocks','chain_blocks','chain_txes','transactions') ORDER BY table_name,ordinal_position;" \
  > "$OUT/ledger-column-inventory.txt" || fail

say "CHAIN CONFIG CANDIDATE SCAN"
PS_SCAN="$OUT/scan-chain-configs.ps1"
cat > "$PS_SCAN" <<'PS1'
$ErrorActionPreference = 'Stop'
$expectedChain = 'horizon-core-v1.4'
$expectedGenesis = '8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603'
$files = @(
  "$env:USERPROFILE\Beaconchain\angel-agents\horizon-benchmark\config\chain.json",
  "$env:USERPROFILE\Beaconchain\horizon-security-assessment\config\chain.json",
  "$env:USERPROFILE\Beaconchain\_hold_merged_20261103-111925\deliveries\bank-melli-test\config\chain.json",
  "$env:USERPROFILE\Beaconchain\_hold_merged_20261103-111925\horizon-core-feature-sync-20261030-084328\config\chain.json",
  "$env:USERPROFILE\Beaconchain\_hold_merged_20261103-111925\horizon-core-feature-sync-20261030-084328\deliveries\bank-melli-test\config\chain.json",
  "$env:USERPROFILE\Beaconchain\_hold_merged_20261103-111925\horizon-core-feature-sync-20261030-084328\horizon-benchmark\config\chain.json"
)
function Get-Strings($x) {
  $out = @()
  if ($null -eq $x) { return $out }
  if ($x -is [string]) { return @($x) }
  if ($x -is [System.Collections.IDictionary]) { foreach ($v in $x.Values) { $out += Get-Strings $v }; return $out }
  if ($x -is [System.Collections.IEnumerable] -and $x -isnot [string]) { foreach ($v in $x) { $out += Get-Strings $v }; return $out }
  if ($x -is [pscustomobject]) { foreach ($p in $x.PSObject.Properties) { $out += Get-Strings $p.Value }; return $out }
  return $out
}
$rows = @()
foreach ($f in $files) {
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
  try {
    $json = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    $strings = @(Get-Strings $json)
    $hasChain = $strings -contains $expectedChain
    $hasGenesis = $strings -contains $expectedGenesis
    $hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()
    $rows += [pscustomobject]@{ path=$f; sha256=$hash; chain_id_match=$hasChain; genesis_hash_match=$hasGenesis; exact_locked_match=($hasChain -and $hasGenesis) }
  } catch {
    $rows += [pscustomobject]@{ path=$f; sha256=''; chain_id_match=$false; genesis_hash_match=$false; exact_locked_match=$false; parse_error=$_.Exception.Message }
  }
}
$rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:PHASE4H_CONFIG_REPORT -Encoding UTF8
$rows | Format-Table -AutoSize | Out-String -Width 300 | Write-Output
$matched = @($rows | Where-Object { $_.exact_locked_match })
"EXACT_LOCKED_CONFIG_MATCHES=$($matched.Count)"
PS1
WIN_SCAN="$(cygpath -w "$PS_SCAN")"
WIN_CONFIG_REPORT="$(cygpath -w "$OUT/config-candidates.json")"
PHASE4H_CONFIG_REPORT="$WIN_CONFIG_REPORT" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_SCAN" | tee "$OUT/config-candidates.txt"

say "WRITE PROTOCOL LOCK DOCUMENTS"
cat > "$OUT/protocol-lock.json" <<JSON
{
  "document_type": "Horizon Core protocol and network-separation lock",
  "document_state": "RECOVERY_BASELINE_FROZEN_NOT_PRODUCTION_ACTIVATED",
  "created_at_local": "$(date -Iseconds)",
  "protocol": {
    "name": "Horizon Core",
    "version": "1.4",
    "chain_id": "$EXPECTED_CHAIN",
    "locked_genesis_hash": "$EXPECTED_GENESIS",
    "locked_genesis_timestamp_utc": "2026-10-31T18:43:01.8552524Z",
    "genesis_signature_profile": "ECDSA_secp256k1_RFC6979_lowS_raw_R||S_64_bytes",
    "historical_signature_policy": "PRESERVE_EXISTING_SIGNATURES_AND_BLOCK_BYTES; DO_NOT_RESIGN_OR_REWRITE_HISTORY",
    "full_history_crypto_verification": "PENDING_INDEPENDENT_VERIFICATION"
  },
  "post_quantum_extension": {
    "candidate": "WOTS+",
    "purpose": "additional_hash_based_post_quantum_signature_layer",
    "activation": "NOT_ACTIVE",
    "scope": "FUTURE_BLOCKS_OR_NEW_CHECKPOINTS_ONLY_AFTER_EXPLICIT_ACTIVATION",
    "requirements_before_activation": [
      "RFC8391-compatible algorithm and test vectors independently verified",
      "one-time private key use enforced and persisted without rollback",
      "public-key commitment and authority transition defined without changing locked Genesis",
      "signature serialization, hash function, address encoding, and verification rules frozen",
      "dual-signature verification tests cover valid, invalid, replayed, and reused one-time keys"
    ],
    "compliance_claim": "NO_POST_QUANTUM_SECURITY_OR_CERTIFICATION_CLAIM_UNTIL_ALL_REQUIREMENTS_PASS"
  },
  "network_separation": {
    "rule": "NO_CROSS_NETWORK_MERGE; NO_CROSS_NETWORK_TRANSACTION_REPLAY; NO_SHARED_GENESIS; NO_SIGNATURE_PROFILE_INFERENCE",
    "primary_network": {
      "chain_id": "$EXPECTED_CHAIN",
      "genesis_hash": "$EXPECTED_GENESIS",
      "historical_signature_profile": "ECDSA_secp256k1",
      "status": "IDENTITY_LOCKED; FULL_HISTORY_VERIFICATION_PENDING"
    },
    "secondary_network": {
      "chain_id": null,
      "genesis_hash": null,
      "signature_profile": null,
      "status": "DECLARED_BY_OWNER_AS_SEPARATE_NETWORK; TECHNICAL_IDENTITY_NOT_YET_MAPPED",
      "handling": "KEEP_IN_SEPARATE_ARCHIVE; DO_NOT_IMPORT_INTO_PRIMARY_NETWORK"
    },
    "observed_storage_streams": [
      {"database":"horizon_switch clone", "table":"public.blocks", "role":"LEDGER_STREAM_A_UNCLASSIFIED"},
      {"database":"horizon_switch clone", "table":"public.chain_blocks", "role":"LEDGER_STREAM_B_UNCLASSIFIED"},
      {"database":"horizon_v14_archive clone", "role":"SEPARATE_ARCHIVE_DATASET_NETWORK_OWNERSHIP_NOT_INFERRED"}
    ]
  },
  "archive_artifacts": {
    "horizon_switch_dump_sha256": "$EXPECTED_SWITCH_DUMP",
    "horizon_v14_registry_dump_sha256": "$EXPECTED_REGISTRY_DUMP",
    "horizon_v14_archive_dump_sha256": "$EXPECTED_ARCHIVE_DUMP",
    "archive_policy": "IMMUTABLE_SEPARATE_ARTIFACTS; NO DATA MERGING OR DELETION"
  },
  "runtime_policy": {
    "recovery_write_gate": "CLOSED",
    "automatic_genesis_creation": "PROHIBITED",
    "automatic_schema_migration": "PROHIBITED",
    "production_activation": "NOT_AUTHORIZED_BY_THIS_DOCUMENT"
  }
}
JSON

cat > "$OUT/PROTOCOL-DECISIONS.md" <<'MD'
# Horizon Core v1.4 — Protocol and Network Separation Lock

## Locked primary protocol

- Chain ID: `horizon-core-v1.4`
- Locked Genesis hash: `8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603`
- Locked Genesis timestamp: `2026-10-31T18:43:01.8552524Z`
- Existing historical signature scheme: ECDSA secp256k1 (RFC6979, low-S, raw 64-byte R||S as declared by the locked design).

The existing history is immutable. No block, transaction, signature, timestamp, hash, Merkle root, or Genesis artifact is to be rewritten to add a new signature scheme.

## WOTS+ extension

WOTS+ is recorded as a proposed additional hash-based signature layer, not as an already activated or verified property of the running network. It applies only to future blocks/checkpoints after a separately authorized activation rule. Before activation, RFC 8391 compatibility, test vectors, one-time-key non-reuse, persistent usage tracking, public-key commitment, serialization, and dual-signature verification must be proven. The locked Genesis is not modified.

## Second network

The owner has declared a second, separate blockchain using a different signature scheme. Its chain ID, Genesis hash, and exact signature profile must not be inferred from names or database layout. Its data remains separately archived. It must not be merged into Horizon Core v1.4, and its transactions must not be replayed into the primary chain.

## Observed database streams

`public.blocks` and `public.chain_blocks` are reported independently in the inventory. This document deliberately does not assume which stream belongs to which network until chain identity evidence is matched. The `horizon_v14_archive` database dump remains a separate archive artifact; a database name alone is not proof that it represents the owner's second network.

## Operational state

Recovery write gate remains closed. Automatic Genesis creation and automatic schema migration remain prohibited. This document does not authorize production runtime restart, deployment, or write activation.
MD

# Include a deterministic index of all generated files.
(
  cd "$OUT"
  find . -maxdepth 1 -type f ! -name 'SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

say "FINAL SUMMARY"
echo "Protocol lock: $OUT/protocol-lock.json"
echo "Decision document: $OUT/PROTOCOL-DECISIONS.md"
echo "Config scan: $OUT/config-candidates.txt"
echo "Ledger schema inventory: $OUT/ledger-column-inventory.txt"
echo "Critical counts: $OUT/critical-ledger-counts.tsv"
echo "Artifact checksums: $OUT/SHA256SUMS"
echo ""
echo "IMPORTANT: WOTS+ is recorded as NOT ACTIVE; second network remains separate and unidentified until its Chain ID/Genesis/signature profile are proven."
echo "No production DB or source files were modified."
echo "RESULT=PASS"
echo "Meaning: existing Phase 4G archives and read-only clones passed hash/availability checks; protocol identity and separation policy documents were generated. This is not cryptographic verification of every historical block and is not production activation."
