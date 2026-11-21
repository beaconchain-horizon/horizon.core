#!/usr/bin/env bash
# Horizon Core v1.4 — network / Genesis / customer-node preflight
# Read-only with respect to repositories, PostgreSQL data, WireGuard keys/configs,
# and runtime services. It writes only its own report under $HOME/horizon-v14-backups.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
if [[ ! -f "$ROOT/go.mod" ]]; then
  ROOT="$(pwd)"
fi
if [[ ! -f "$ROOT/go.mod" ]]; then
  printf 'ERROR: Run this script from inside the horizon-core repository.\n' >&2
  exit 1
fi

SCAN_ROOT="${HORIZON_SCAN_ROOT:-$(dirname "$ROOT")}"
PG_BIN="${PG_BIN:-/c/Program Files/PostgreSQL/18/bin}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
EXPECTED_CHAIN_ID="horizon-core-v1.4"
EXPECTED_GENESIS="8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"

REPORT_DIR="$HOME/horizon-v14-backups"
mkdir -p "$REPORT_DIR"
STAMP="$(date '+%Y%m%d_%H%M%S')"
REPORT="$REPORT_DIR/network-preflight-$STAMP.txt"

section() {
  printf '\n============================================================\n%s\n============================================================\n' "$1"
}

safe_grep_paths() {
  local pattern="$1"
  shift
  grep -RIlE --include='*.go' --include='*.sql' --include='*.sh' \
    --include='*.bat' --include='*.ps1' --include='*.yaml' --include='*.yml' \
    --include='*.toml' --include='*.json' \
    --exclude-dir=.git --exclude-dir=vendor --exclude-dir=node_modules \
    --exclude-dir=.next --exclude='*.env' --exclude='*.conf' \
    --exclude='*.key' --exclude='*.pem' --exclude='*.p12' \
    "$pattern" "$@" 2>/dev/null | sort -u || true
}

exec > >(tee "$REPORT") 2>&1

section "0. SAFETY AND EXECUTION CONTEXT"
echo "Mode: READ-ONLY PREFLIGHT"
echo "Repo: $ROOT"
echo "Scan root: $SCAN_ROOT"
echo "Report: $REPORT"
echo "No source files, database rows, WireGuard settings, or private keys will be changed/read."
echo "Only the report file is created; no other persistent artifacts are written."

section "1. REPOSITORY AND TOOLCHAIN"
echo "Branch: $(git -C "$ROOT" branch --show-current 2>/dev/null || echo unknown)"
echo "Commit: $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "Go: $(go version 2>&1 || true)"
echo "Git status:"
git -C "$ROOT" status --short --branch 2>/dev/null || true

section "2. DISCOVER GIT REPOSITORIES UNDER BEACONCHAIN"
if [[ -d "$SCAN_ROOT" ]]; then
  find "$SCAN_ROOT" -type d \( -name .git -o -name vendor -o -name node_modules -o -name .next \) -prune -print 2>/dev/null \
    | while IFS= read -r marker; do
        [[ "$(basename "$marker")" == ".git" ]] || continue
        repo="$(dirname "$marker")"
        printf 'REPO: %s' "$repo"
        [[ -f "$repo/go.mod" ]] && printf ' | Go'
        [[ -f "$repo/package.json" ]] && printf ' | Node'
        [[ -f "$repo/GENESIS.json" ]] && printf ' | root GENESIS.json'
        printf '\n'
      done
else
  echo "Scan root not found: $SCAN_ROOT"
fi

section "3. GENESIS ARTIFACT INVENTORY (NO SIGNATURE OR KEY MATERIAL PRINTED)"
GENESIS_FOUND=0
if [[ -d "$SCAN_ROOT" ]]; then
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    GENESIS_FOUND=1
    sha="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
    chain="$(grep -m1 -E '\"chain_id\"[[:space:]]*:' "$file" | sed -E 's/.*\"chain_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/' || true)"
    gh="$(grep -m1 -E '\"genesis_hash\"[[:space:]]*:' "$file" | sed -E 's/.*\"genesis_hash\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/' || true)"
    ts="$(grep -m1 -E '\"(timestamp|genesis_timestamp)\"[[:space:]]*:' "$file" | sed -E 's/.*:[[:space:]]*\"?([^\",}]+)\"?.*/\1/' || true)"
    printf 'FILE: %s\n  SHA256: %s\n  chain_id: %s\n  genesis_hash: %s\n  timestamp: %s\n' "$file" "$sha" "${chain:-NOT_FOUND}" "${gh:-NOT_FOUND}" "${ts:-NOT_FOUND}"
    if [[ "$chain" != "$EXPECTED_CHAIN_ID" || "$gh" != "$EXPECTED_GENESIS" ]]; then
      echo "  ANCHOR_STATUS: DOES_NOT_MATCH_EXPECTED_V1.4_ANCHOR_OR_FIELDS_MISSING"
    else
      echo "  ANCHOR_STATUS: DECLARED_FIELDS_MATCH_V1.4"
    fi
  done < <(find "$SCAN_ROOT" -type d \( -name .git -o -name vendor -o -name node_modules -o -name .next \) -prune -o \
    -type f \( -iname 'GENESIS.json' -o -iname 'GENESIS-public.json' -o -iname 'genesis.json' -o -iname 'genesis-public.json' \) -print 2>/dev/null | sort -u)
fi
if [[ "$GENESIS_FOUND" -eq 0 ]]; then
  echo "No Genesis JSON artifacts found under $SCAN_ROOT"
fi

section "4. DATABASE CONFIGURATION REFERENCES (PATHS / VARIABLE NAMES ONLY; VALUES REDACTED)"
CONFIG_PATHS="$(safe_grep_paths 'DATABASE_URL|DB_DSN|DB_ENGINE|DB_HOST|DB_NAME|POSTGRES_DB|PGHOST|HORIZON_GENESIS_FILE|GENESIS_FILE|horizon_switch|horizon_v14_registry|horizon_v14_archive|sqlite|postgres(ql)?://' "$SCAN_ROOT")"
if [[ -n "$CONFIG_PATHS" ]]; then
  printf '%s\n' "$CONFIG_PATHS"
else
  echo "No matching configuration references found."
fi

section "5. GENESIS / CHAIN / DATABASE INITIALIZATION REFERENCES"
safe_grep_paths 'GenesisHash|GenesisChainID|EnsureGenesis|createGenesisBlock|initLicenseChain|ensureChainGenesis|AutoMigrate|gorm.Open|sql.Open|DB_DSN|DATABASE_URL|protocol_anchor|protocol_manifest' "$ROOT" || true

echo "\nMatched initialization symbols (source lines; no secret files scanned):"
grep -Rni --include='*.go' --exclude-dir=.git --exclude-dir=vendor \
  -E 'GenesisHash|GenesisChainID|EnsureGenesis|createGenesisBlock|initLicenseChain|ensureChainGenesis|AutoMigrate|gorm\.Open|sql\.Open|protocol_anchor|protocol_manifest' \
  "$ROOT/cmd" "$ROOT/internal" 2>/dev/null | head -n 220 || true

section "6. POSTGRESQL DATABASE AND LEDGER-TABLE INVENTORY"
PSQL="$PG_BIN/psql.exe"
if [[ -x "$PSQL" ]]; then
  DB_LIST="$("$PSQL" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -Atqc \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname" 2>/dev/null || true)"
  if [[ -z "$DB_LIST" ]]; then
    echo "Could not enumerate PostgreSQL databases. Check connection and permissions."
  else
    while IFS= read -r dbname; do
      [[ -n "$dbname" ]] || continue
      echo "\nDATABASE: $dbname"
      "$PSQL" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$dbname" -Atqc \
        "SELECT 'READ_ONLY_DEFAULT=' || current_setting('default_transaction_read_only')" 2>/dev/null || echo "  CONNECTION/SETTING: UNAVAILABLE"
      "$PSQL" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$dbname" -Atqc \
        "SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema') AND (table_name ILIKE '%block%' OR table_name ILIKE '%chain%' OR table_name ILIKE '%genesis%' OR table_name ILIKE '%license%' OR table_name ILIKE '%transaction%' OR table_name ILIKE '%anchor%' OR table_name ILIKE '%protocol%' OR table_name ILIKE '%membership%' OR table_name ILIKE '%node%') ORDER BY 1" 2>/dev/null || true
    done <<< "$DB_LIST"
  fi
else
  echo "psql.exe not found at $PSQL"
fi

section "7. CONSENSUS CLIENT AND NODE ROLE IMPLEMENTATION"
if [[ -f "$ROOT/cmd/switch/consensus_client.go" ]]; then
  grep -nE 'ports :=|client :=|Timeout|json\.NewDecoder|resp\.StatusCode|votes\[|criticalAccept|majorityAccept|AgentGuardian|case "' \
    "$ROOT/cmd/switch/consensus_client.go" || true
fi
if [[ -f "$ROOT/cmd/angel-node/main.go" ]]; then
  grep -nE 'NODE_ROLE|NODE_PORT|ListenAndServe|case "Merkle"|case "Hash"|case "ECDSA"|case "Type"|case "Volume"|case "Time"|case "User"|WOTSSignature|wots\.Verify|MerkleRoot|TxID' \
    "$ROOT/cmd/angel-node/main.go" || true
fi
if [[ -f "$ROOT/cmd/agent-node/main.go" ]]; then
  grep -nE 'AGENT_NODE_PORT|9008|TxCount|1000000|Vote:|AgentGuardian' "$ROOT/cmd/agent-node/main.go" || true
fi

section "8. CUSTOMER LICENSE QUOTA AND NODE-MEMBERSHIP IMPLEMENTATION"
safe_grep_paths 'remaining_tx|tx_remaining|consumed_tx|license.*volume|Volume.*Used|voting_right|voting_weight|membership_epoch|membership_certificate|customer.node|node.enroll|WireGuard|wireguard|wg set|AllowedIPs' "$ROOT" || true
echo "\nRelevant license / node membership symbols:"
grep -Rni --include='*.go' --exclude-dir=.git --exclude-dir=vendor \
  -E 'Volume|Used|LicenseID|remaining_tx|consumed_tx|membership|voting|WireGuard|wireguard|AllowedIPs' \
  "$ROOT/cmd/switch" "$ROOT/internal" 2>/dev/null | head -n 260 || true

section "9. MERKLE PROFILES AND PROOF IMPLEMENTATIONS"
grep -Rni --include='*.go' --exclude-dir=.git --exclude-dir=vendor \
  -E 'BinaryRootNoPrefix|TernaryRootNoPrefix|RootFromData|RootFromHashes|GenerateProof|VerifyProof|MerkleProof|ternaryRoot|binaryRoot|MerkleType' \
  "$ROOT/internal" "$ROOT/cmd" 2>/dev/null | head -n 300 || true

section "10. WIREGUARD INVENTORY (NO CONFIG FILES OR PRIVATE KEYS READ)"
if command -v wg >/dev/null 2>&1; then
  echo "wg executable: $(command -v wg)"
  echo "Interfaces:"
  wg show interfaces 2>/dev/null || echo "No interfaces reported / insufficient privileges."
elif [[ -x "/c/Program Files/WireGuard/wg.exe" ]]; then
  echo "wg executable: /c/Program Files/WireGuard/wg.exe"
  "/c/Program Files/WireGuard/wg.exe" show interfaces 2>/dev/null || echo "No interfaces reported / insufficient privileges."
else
  echo "WireGuard CLI not found in standard PATH or Program Files."
fi
if command -v powershell.exe >/dev/null 2>&1; then
  echo "WireGuard Windows service status (names and status only):"
  powershell.exe -NoProfile -Command \
    "Get-Service -Name 'WireGuard*' -ErrorAction SilentlyContinue | Select-Object Name,Status | Format-Table -HideTableHeaders" 2>/dev/null || true
fi

section "11. LIVE SERVICE PORTS"
echo "TCP listeners (8080, 8091, 9001-9008):"
netstat -ano -p tcp 2>/dev/null | grep -E ':(8080|8091|900[1-8])[[:space:]]' | grep LISTENING || true
echo "UDP listeners (WireGuard common default 51820 only; configured port may differ):"
netstat -ano -p udp 2>/dev/null | grep -E ':51820[[:space:]]' || true

section "12. EXISTING NODE LAW / CANONICAL DOC REFERENCES"
for file in \
  "$ROOT/ANGEL-NODE-LAW.md" \
  "$ROOT/docs/immutable/HORIZON-CORE-v1.4-CANONICAL.md" \
  "$ROOT/docs/immutable/HORIZON-CORE-v1.4-SECURITY-DESIGN.md"; do
  if [[ -f "$file" ]]; then
    echo "DOC: $file"
    grep -nEi '900[1-8]|critical|majority|agent|Merkle|license|volume|vote|fail.closed|WireGuard|customer node|membership' "$file" | head -n 100 || true
  fi
done

section "13. FOCUSED CRYPTO TESTS (NO KEY MATERIAL)"
if command -v go >/dev/null 2>&1; then
  echo "Go version: $(go version)"
  GOTOOLCHAIN=local go test -count=1 ./internal/crypto/wots || echo "WOTS_TEST_STATUS=FAIL"
  GOTOOLCHAIN=local go test -count=1 ./internal/crypto || echo "ECDSA_TEST_STATUS=FAIL"
  GOTOOLCHAIN=local go test -count=1 ./internal/merkle || echo "MERKLE_TEST_STATUS=FAIL"
else
  echo "Go not available; focused tests skipped."
fi

section "14. REQUIRED DESIGN / IMPLEMENTATION GAPS TO RESOLVE"
cat <<'GAPS'
1. Customer voting eligibility must be derived from a valid, unexpired, non-revoked license with remaining transaction quota > 0.
2. Each unique finalized TxID consumes exactly one quota unit atomically; duplicate/replayed TxIDs must not consume twice.
3. Quota exhaustion suspends that customer's consensus voting eligibility; historical read/proof access can remain available.
4. License volume controls eligibility, not voting weight, unless a separately approved policy defines weighting.
5. Customer API must expose only its own node/license/usage/block/proof data; validator roles, internal IPs, signing internals and private key material stay private.
6. WireGuard keys are a separate key domain from ECDSA mykey.txt and WOTS+ pqkey.txt. Never reuse either signing secret as a WireGuard key.
7. WireGuard AllowedIPs and host firewall must expose only required private API routes; do not expose every internal validator port to customers.
8. Current Switch consensus client uses localhost ports and role strings returned by nodes; customer peers and authenticated remote membership are not implemented by that path.
9. Current AgentGuardian is described as inspector in v1.4 docs but RequestConsensus allows it to veto; policy and code must be reconciled.
10. Current block Merkle commits transactions but not the license set; TxID is absent from ConsensusTx. Composite TX+License commitment is required before claiming every block covers both.
11. Binary/Ternary root formulas and proof generation must use the same versioned leaf encoding, domain separation and padding rules.
12. Every operational database must pin the same chain_id, genesis_hash, protocol_version and merkle profile; startup must fail closed on mismatch.
13. This preflight intentionally does not edit application code, change DB schemas, provision WireGuard peers or change consensus policy.
GAPS

section "15. AUDIT COMPLETE"
echo "Report: $REPORT"
echo "Mode: READ-ONLY PREFLIGHT"
echo "No PostgreSQL rows, schemas, source files, WireGuard configs/keys, or service states were changed."
echo "Next step: use this inventory to generate a reviewed migration for the actual discovered databases and repositories."
