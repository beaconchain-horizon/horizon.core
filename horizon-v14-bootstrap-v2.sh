#!/usr/bin/env bash
# Horizon Core v1.4 — Genesis-anchored registry + ledger-only PostgreSQL archive
# Go 1.24.x is required. Source DB is never modified. Existing target DBs are never overwritten.
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
PUBLIC_GENESIS_FILE="${HORIZON_PUBLIC_GENESIS_FILE:-$ROOT/docs/immutable/artifacts/GENESIS-public.json}"
BACKUP_ROOT="${HORIZON_BACKUP_ROOT:-$HOME/horizon-v14-backups}"
EXPECTED_CHAIN_ID="horizon-core-v1.4"
EXPECTED_GENESIS_HASH="8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"

log() { printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
on_error() {
  local rc=$?
  printf '\nERROR: command failed at line %s (exit %s). No source database was modified.\n' "${BASH_LINENO[0]:-unknown}" "$rc" >&2
  exit "$rc"
}
trap on_error ERR

for tool in psql pg_dump pg_restore createdb; do
  [[ -x "$PG_BIN/$tool.exe" ]] || die "Missing PostgreSQL tool: $PG_BIN/$tool.exe"
done
command -v go >/dev/null 2>&1 || die "Go is not available in PATH. Go 1.24.x is required."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."
command -v git >/dev/null 2>&1 || die "git is required."
[[ -f "$ROOT/go.mod" ]] || die "Run this script from inside the Horizon Core repository."
[[ -f "$GENESIS_FILE" ]] || die "Genesis file not found: $GENESIS_FILE"
[[ -f "$PUBLIC_GENESIS_FILE" ]] || die "Public Genesis reference not found: $PUBLIC_GENESIS_FILE"

GO_VERSION="$(go version)"
case "$GO_VERSION" in *"go1.24."*) ;; *) die "Go 1.24.x is required by project policy. Detected: $GO_VERSION" ;; esac

GENESIS_JSON="$(cat "$GENESIS_FILE")"
PUBLIC_GENESIS_JSON="$(cat "$PUBLIC_GENESIS_FILE")"
GENESIS_SHA256="$(sha256sum "$GENESIS_FILE" | cut -d ' ' -f 1)"
GENESIS_BYTES="$(wc -c < "$GENESIS_FILE" | tr -d '[:space:]')"
PUBLIC_GENESIS_SHA256="$(sha256sum "$PUBLIC_GENESIS_FILE" | cut -d ' ' -f 1)"
PUBLIC_GENESIS_BYTES="$(wc -c < "$PUBLIC_GENESIS_FILE" | tr -d '[:space:]')"
GENESIS_REL="${GENESIS_FILE#"$ROOT"/}"
PUBLIC_GENESIS_REL="${PUBLIC_GENESIS_FILE#"$ROOT"/}"
[[ "$GENESIS_REL" != "$GENESIS_FILE" ]] || GENESIS_REL="$GENESIS_FILE"
[[ "$PUBLIC_GENESIS_REL" != "$PUBLIC_GENESIS_FILE" ]] || PUBLIC_GENESIS_REL="$PUBLIC_GENESIS_FILE"
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
GIT_BRANCH="$(git branch --show-current 2>/dev/null || printf 'unknown')"
STAMP="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="$BACKUP_ROOT/$STAMP"
mkdir -p "$RUN_DIR"

PSQL=("$PG_BIN/psql.exe" -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -v ON_ERROR_STOP=1 -P pager=off)

log "1/8 — Preflight PostgreSQL and source database"
"${PSQL[@]}" -d "$SOURCE_DB" -Atqc "SELECT 1" >/dev/null || die "Cannot connect to source database $SOURCE_DB"
REQUIRED_TABLE_COUNT="$("${PSQL[@]}" -d "$SOURCE_DB" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' AND table_name IN ('blocks','chain_blocks','chain_txes','transactions','blocks_bak_1794548568','blocks_bak_1794548606','chain_blocks_bak_1794548568','chain_blocks_bak_1794548606')")"
[[ "$REQUIRED_TABLE_COUNT" == "8" ]] || die "Expected 8 known ledger tables in $SOURCE_DB; found $REQUIRED_TABLE_COUNT. No target database was created."

log "2/8 — Refuse to overwrite existing target databases"
EXISTING="$("${PSQL[@]}" -d postgres -Atqc "SELECT datname FROM pg_database WHERE datname IN ('$REGISTRY_DB','$ARCHIVE_DB') ORDER BY datname")"
[[ -z "$EXISTING" ]] || die "Target database already exists: $EXISTING. Inspect it manually; this script never drops or overwrites it."

log "3/8 — Verify the actual Genesis JSON and its ECDSA signature"
# This helper parses the real file, checks consistency against the published anchor,
# and verifies the raw 64-byte R||S signature over the declared 32-byte Genesis hash.
VERIFY_GO="$RUN_DIR/verify_genesis.go"
cat > "$VERIFY_GO" <<'GO'
package main

import (
    "encoding/hex"
    "encoding/json"
    "fmt"
    "os"
    "time"

    k256 "github.com/decred/dcrd/dcrec/secp256k1/v4"
    k256ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
)

type Genesis struct {
    ChainID        string `json:"chain_id"`
    GenesisHash    string `json:"genesis_hash"`
    GenesisNumber  int64  `json:"genesis_number"`
    MerkleRoot     string `json:"merkle_root"`
    MerkleType     string `json:"merkle_type"`
    PreviousHash   string `json:"previous_hash"`
    TxCount        int64  `json:"tx_count"`
    Timestamp      string `json:"timestamp"`
    LockedAt       string `json:"locked_at"`
    AuthorityPub   string `json:"authority_pub_key"`
    AuthoritySig   string `json:"authority_sig"`
}

type PublicGenesis struct {
    ChainID       string `json:"chain_id"`
    GenesisHash   string `json:"genesis_hash"`
    Block1Hash    string `json:"block_1_hash"`
    AuthorityPub  string `json:"authority_pubkey_hex"`
    Curve         string `json:"curve"`
    Hash          string `json:"hash"`
}

func fail(s string) { fmt.Fprintln(os.Stderr, "GENESIS VERIFY: FAIL:", s); os.Exit(1) }

func main() {
    if len(os.Args) != 3 { fail("usage: verify_genesis GENESIS.json GENESIS-public.json") }
    raw, err := os.ReadFile(os.Args[1]); if err != nil { fail(err.Error()) }
    var g Genesis
    if err := json.Unmarshal(raw, &g); err != nil { fail("parse Genesis JSON: " + err.Error()) }
    pubRaw, err := os.ReadFile(os.Args[2]); if err != nil { fail(err.Error()) }
    var p PublicGenesis
    if err := json.Unmarshal(pubRaw, &p); err != nil { fail("parse public Genesis JSON: " + err.Error()) }

    const expectedChain = "horizon-core-v1.4"
    const expectedHash = "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"
    if g.ChainID != expectedChain || p.ChainID != expectedChain { fail("chain_id does not match locked protocol identifier") }
    if g.GenesisHash != expectedHash || p.GenesisHash != expectedHash { fail("Genesis hash does not match locked v1.4 anchor") }
    if g.GenesisHash != p.GenesisHash { fail("canonical and public Genesis hashes differ") }
    if g.AuthorityPub == "" || g.AuthorityPub != p.AuthorityPub { fail("authority public key differs or is missing") }
    if g.GenesisNumber != 0 || g.TxCount != 0 { fail("Genesis number or transaction count is not zero") }
    if g.MerkleRoot != g.GenesisHash { fail("Genesis merkle_root differs from declared Genesis hash") }
    if g.MerkleType != "genesis" { fail("unexpected Genesis merkle_type") }
    if len(g.PreviousHash) != 64 || g.PreviousHash != "0000000000000000000000000000000000000000000000000000000000000000" { fail("previous_hash is not 32 zero bytes") }
    if p.Curve != "secp256k1" || p.Hash != "SHA-256" { fail("public Genesis cryptographic profile mismatch") }

    ts, err := time.Parse(time.RFC3339Nano, g.Timestamp); if err != nil { fail("invalid Genesis timestamp: " + err.Error()) }
    locked, err := time.Parse(time.RFC3339, g.LockedAt); if err != nil { fail("invalid locked_at: " + err.Error()) }
    _ = locked

    pubBytes, err := hex.DecodeString(g.AuthorityPub); if err != nil { fail("authority public key is not valid hex") }
    if len(pubBytes) != 65 || pubBytes[0] != 0x04 { fail("authority public key is not uncompressed 65-byte SEC1") }
    pub, err := k256.ParsePubKey(pubBytes); if err != nil { fail("parse secp256k1 public key: " + err.Error()) }
    hashBytes, err := hex.DecodeString(g.GenesisHash); if err != nil || len(hashBytes) != 32 { fail("Genesis hash is not 32-byte hex") }
    sigBytes, err := hex.DecodeString(g.AuthoritySig); if err != nil || len(sigBytes) != 64 { fail("authority_sig is not 64-byte R||S hex") }
    var r, s k256.ModNScalar
    if r.SetByteSlice(sigBytes[:32]) || s.SetByteSlice(sigBytes[32:]) { fail("ECDSA signature scalar overflows curve order") }
    sig := k256ecdsa.NewSignature(&r, &s)
    if !sig.Verify(hashBytes, pub) { fail("ECDSA signature does not verify against Genesis hash and authority key") }

    fmt.Println("GENESIS JSON: PASS")
    fmt.Println("PUBLIC GENESIS CROSS-CHECK: PASS")
    fmt.Println("ECDSA secp256k1 signature over declared Genesis hash: VALID")
    fmt.Printf("Genesis timestamp: %s\n", g.Timestamp)
    fmt.Printf("Genesis Unix seconds: %d\n", ts.Unix())
    fmt.Printf("Genesis nanoseconds: %d\n", ts.Nanosecond())
    fmt.Printf("Genesis locked_at: %s\n", g.LockedAt)
    fmt.Println("Block #1 hash: declared in public Genesis; not verified by this Genesis-only signature check")
}
GO
GOTOOLCHAIN=local go run "$VERIFY_GO" "$GENESIS_FILE" "$PUBLIC_GENESIS_FILE" | tee "$RUN_DIR/genesis_verify.log"

log "4/8 — Print source and target details"
printf 'Repository: %s\nBranch/commit: %s (%s)\nGo: %s\nGenesis: %s\nGenesis file SHA-256: %s\nPublic Genesis: %s\nPublic Genesis file SHA-256: %s\nSource DB: %s@%s:%s/%s\nRegistry DB: %s@%s:%s/%s\nArchive DB: %s@%s:%s/%s\n' \
  "$ROOT" "$GIT_BRANCH" "$GIT_COMMIT" "$GO_VERSION" "$GENESIS_REL" "$GENESIS_SHA256" \
  "$PUBLIC_GENESIS_REL" "$PUBLIC_GENESIS_SHA256" "$PGUSER" "$PGHOST" "$PGPORT" "$SOURCE_DB" \
  "$PGUSER" "$PGHOST" "$PGPORT" "$REGISTRY_DB" "$PGUSER" "$PGHOST" "$PGPORT" "$ARCHIVE_DB"

DUMP_FILE="$RUN_DIR/${SOURCE_DB}_${STAMP}.dump"
DUMP_LIST="$RUN_DIR/${SOURCE_DB}_${STAMP}.dump.list"
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

log "5/8 — Create and inspect a ledger-only source backup"
"$PG_BIN/pg_dump.exe" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$SOURCE_DB" -Fc -f "$DUMP_FILE" "${TABLE_ARGS[@]}"
[[ -s "$DUMP_FILE" ]] || die "Backup dump is empty."
"$PG_BIN/pg_restore.exe" --list "$DUMP_FILE" > "$DUMP_LIST"
[[ -s "$DUMP_LIST" ]] || die "Backup archive listing is empty."
DUMP_SHA256="$(sha256sum "$DUMP_FILE" | cut -d ' ' -f 1)"
printf 'Backup: %s\nBackup SHA-256: %s\n' "$DUMP_FILE" "$DUMP_SHA256"

log "6/8 — Create isolated Archive and Registry databases"
"$PG_BIN/createdb.exe" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -T template0 -E UTF8 "$ARCHIVE_DB"
"$PG_BIN/pg_restore.exe" --exit-on-error --no-owner --no-acl -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$ARCHIVE_DB" "$DUMP_FILE"
"$PG_BIN/createdb.exe" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -T template0 -E UTF8 "$REGISTRY_DB"

INIT_SQL="$RUN_DIR/init_registry.sql"
cat > "$INIT_SQL" <<'SQL'
BEGIN;
CREATE SCHEMA v14;
CREATE SCHEMA archive;

CREATE TABLE v14.protocol_manifest (
  chain_id text PRIMARY KEY,
  protocol_version text NOT NULL,
  genesis_locked_at timestamptz NOT NULL,
  declared_genesis_hash char(64) NOT NULL,
  declared_block1_hash char(64) NOT NULL,
  authority_pubkey_hex text NOT NULL,
  authority_signature_rs_hex char(128) NOT NULL,
  genesis_timestamp timestamptz NOT NULL,
  genesis_timestamp_unix_seconds bigint NOT NULL,
  genesis_file_path text NOT NULL,
  genesis_file_sha256 char(64) NOT NULL,
  registry_database text NOT NULL,
  archive_database text NOT NULL,
  ecdsa_verification_status text NOT NULL,
  wotsplus_status text NOT NULL,
  fips205_status text NOT NULL,
  standards_review_status text NOT NULL,
  source_git_commit text NOT NULL,
  notes text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (declared_genesis_hash ~ '^[0-9a-f]{64}$'),
  CHECK (declared_block1_hash ~ '^[0-9a-f]{64}$'),
  CHECK (authority_signature_rs_hex ~ '^[0-9a-f]{128}$'),
  CHECK (genesis_file_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE TABLE v14.genesis_artifact (
  chain_id text PRIMARY KEY REFERENCES v14.protocol_manifest(chain_id),
  artifact_file_name text NOT NULL,
  artifact_json jsonb NOT NULL,
  artifact_sha256 char(64) NOT NULL,
  artifact_size_bytes bigint NOT NULL,
  signature_verification text NOT NULL,
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
  block_timestamp bigint NOT NULL,
  block_timestamp_raw text NOT NULL,
  prev_hash char(64) NOT NULL,
  merkle_root char(64) NOT NULL,
  tx_count bigint NOT NULL,
  block_hash char(64) NOT NULL,
  ecdsa_signature_rs_hex char(128) NOT NULL,
  wotsplus_signature_hex text,
  wotsplus_ots_key_id text,
  signer_public_key_hex text NOT NULL,
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

CREATE TABLE v14.one_time_signature_usage (
  ots_key_id text PRIMARY KEY,
  chain_id text NOT NULL REFERENCES v14.protocol_manifest(chain_id),
  algorithm text NOT NULL CHECK (algorithm IN ('WOTS+', 'XMSS-WOTS+', 'OTHER_OTS')),
  key_index bigint NOT NULL,
  target_type text NOT NULL CHECK (target_type IN ('GENESIS','BLOCK','LICENSE')),
  target_id text NOT NULL,
  message_digest_sha256 char(64) NOT NULL CHECK (message_digest_sha256 ~ '^[0-9a-f]{64}$'),
  public_key_hex text,
  signature_hex text,
  usage_status text NOT NULL,
  signed_at timestamptz,
  UNIQUE (chain_id, algorithm, key_index),
  UNIQUE (chain_id, target_type, target_id)
);

CREATE TABLE v14.signature_policy (
  chain_id text PRIMARY KEY REFERENCES v14.protocol_manifest(chain_id),
  ecdsa_required boolean NOT NULL,
  wotsplus_required boolean NOT NULL,
  fips205_required boolean NOT NULL,
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

WITH g AS (SELECT :'genesis_json'::jsonb AS j), p AS (SELECT :'public_genesis_json'::jsonb AS j)
INSERT INTO v14.protocol_manifest (
  chain_id, protocol_version, genesis_locked_at,
  declared_genesis_hash, declared_block1_hash, authority_pubkey_hex,
  authority_signature_rs_hex, genesis_timestamp, genesis_timestamp_unix_seconds,
  genesis_file_path, genesis_file_sha256, registry_database, archive_database,
  ecdsa_verification_status, wotsplus_status, fips205_status,
  standards_review_status, source_git_commit, notes
)
SELECT
  g.j->>'chain_id', '1.4', (g.j->>'locked_at')::timestamptz,
  g.j->>'genesis_hash', p.j->>'block_1_hash', g.j->>'authority_pub_key',
  g.j->>'authority_sig', (g.j->>'timestamp')::timestamptz,
  floor(extract(epoch FROM (g.j->>'timestamp')::timestamptz))::bigint,
  :'genesis_path', :'genesis_sha256', 'horizon_v14_registry', 'horizon_v14_archive',
  'VALIDATED_BY_DYNAMIC_GENESIS_GO_VERIFIER',
  'NOT_PRESENT_IN_LOCKED_GENESIS_ARTIFACT; ONE-TIME KEY IMPLEMENTATION REQUIRED',
  'REFERENCE_ONLY_NOT_IMPLEMENTED_OR_CLAIMED', 'PENDING_FULL_STANDARDS_AUDIT',
  :'git_commit',
  'Genesis JSON stored in full. Signature validates the declared Genesis hash; this does not by itself prove the preimage/hash-construction procedure.'
FROM g, p;

INSERT INTO v14.genesis_artifact (
  chain_id, artifact_file_name, artifact_json, artifact_sha256,
  artifact_size_bytes, signature_verification
)
VALUES (
  'horizon-core-v1.4', :'genesis_path', :'genesis_json'::jsonb,
  :'genesis_sha256', :genesis_bytes,
  'ECDSA_VALID_FOR_DECLARED_GENESIS_HASH; FULL_JSON_STORED'
);

INSERT INTO v14.artifact_registry (artifact_type, repository_path, sha256, size_bytes, status)
VALUES
  ('GENESIS_JSON', :'genesis_path', :'genesis_sha256', :genesis_bytes, 'FULL_CONTENT_STORED_ECDSA_SIGNATURE_VERIFIED'),
  ('GENESIS_PUBLIC_JSON', :'public_genesis_path', :'public_genesis_sha256', :public_genesis_bytes, 'REFERENCE_ARTIFACT_HASH_RECORDED');

INSERT INTO v14.canonical_blocks (
  chain_id, block_num, block_timestamp, block_timestamp_raw, prev_hash,
  merkle_root, tx_count, block_hash, ecdsa_signature_rs_hex,
  wotsplus_signature_hex, wotsplus_ots_key_id, signer_public_key_hex,
  verification_status, source_kind, evidence
)
SELECT
  j->>'chain_id', (j->>'genesis_number')::bigint,
  floor(extract(epoch FROM (j->>'timestamp')::timestamptz))::bigint,
  j->>'timestamp', j->>'previous_hash', j->>'merkle_root',
  (j->>'tx_count')::bigint, j->>'genesis_hash', j->>'authority_sig',
  NULL, NULL, j->>'authority_pub_key',
  'ECDSA_SIGNATURE_VALID_FOR_DECLARED_HASH; GENESIS_FIELDS_CROSS_CHECKED; HASH_PREIMAGE_RULE_NOT_RECONSTRUCTED',
  'LOCKED_GENESIS_JSON',
  jsonb_build_object(
    'locked_at', j->>'locked_at',
    'merkle_type', j->>'merkle_type',
    'genesis_file_sha256', :'genesis_sha256',
    'signature_encoding', 'R||S',
    'signature_bytes', 64,
    'wotsplus_signature_present', false,
    'timestamp_precision_preserved_in_block_timestamp_raw', true
  )
FROM (SELECT :'genesis_json'::jsonb AS j) s;

INSERT INTO v14.checkpoints (chain_id, block_num, expected_hash, checkpoint_status, evidence)
SELECT 'horizon-core-v1.4', 1, j->>'block_1_hash',
       'DECLARED_CHECKPOINT_NOT_VERIFIED; FULL_BLOCK_1_HEADER_AND_SIGNATURE_NOT_SUPPLIED',
       jsonb_build_object('source', :'public_genesis_path', 'signature_excerpt', j #>> '{block_1_signature,r_s_hex}')
FROM (SELECT :'public_genesis_json'::jsonb AS j) s;

INSERT INTO v14.hash_profiles (profile_id, algorithm, formula, byte_encoding, status, source_reference, notes) VALUES
('GENESIS_LOCKED_HASH_V14','SHA-256','Locked declared Genesis hash; canonical preimage construction is not inferred from the hash alone','32-byte digest represented as lowercase hex','SIGNATURE_VERIFIED; PREIMAGE_RECONSTRUCTION_PENDING','GENESIS.json + cmd/genesis-verify','ECDSA verifies the declared hash, not the derivation of that hash from fields.'),
('BLOCK_HASH_HZBLK1_CODE_CANDIDATE','SHA-256','SHA256(UTF8("HZBLK1|" || block_num || "|" || prev_hash || "|" || merkle_root || "|" || timestamp))','UTF-8 decimal fields; hash values represented as lowercase hex text','CODE_OBSERVED_NOT_PROVEN_CANONICAL','cmd/switch/license_chain.go canonicalBlockMessage/computeBlockHash','Must reproduce a known canonical block before approval.'),
('TX_HASH_HZTXH1_CODE_CANDIDATE','SHA-256','SHA256(UTF8("HZTXH1|" || tx_type || "|" || payload || "|" || timestamp))','UTF-8','CODE_OBSERVED_NOT_PROVEN_CANONICAL','cmd/switch/license_chain.go computeTxHash','Payload serialization and field ordering must match the verifier.'),
('MERKLE_BINARY_DECLARED','SHA-256','SHA256(left_node_bytes || right_node_bytes)','Raw 32-byte child hashes; odd-leaf rule pending pinning','OWNER_DECLARED_PROFILE_PENDING_VERIFICATION','README: internal/merkle/merkle.go','Must be checked against implementation and test vectors.'),
('MERKLE_TERNARY_DECLARED','SHA-256','SHA256(child_a_bytes || child_b_bytes || child_c_bytes)','Raw 32-byte child hashes; incomplete final group rule pending pinning','OWNER_DECLARED_PROFILE_PENDING_VERIFICATION','README: internal/merkle/ternary.go','Project-specific profile; independent test vectors required.'),
('TIMESTAMP_UNIX_SECONDS_DECLARED','POSIX time','timestamp = seconds since 1970-01-01T00:00:00Z','Signed 64-bit seconds; exact source RFC3339 timestamp preserved separately','DECLARED_PROFILE','GENESIS.json timestamp + source code','Timestamp is not block height.');

INSERT INTO v14.signature_profiles (profile_id, algorithm, standard_reference, parameters, key_usage_model, signature_size_bytes, status, notes) VALUES
('ECDSA_SECP256K1_RAW64','ECDSA secp256k1','SEC 2 + project signature encoding',jsonb_build_object('curve','secp256k1','encoding','R||S','signature_bytes',64),'Key custody and rotation policy required',64,'GENESIS_SIGNATURE_VERIFIED; RFC6979_AND_LOW_S_IMPLEMENTATION_AUDIT_PENDING','The Genesis signature validates. Deterministic nonce and Low-S behavior must be audited separately.'),
('WOTS_PLUS_SHA256_N32_W16_RFC8391','WOTS+','RFC 8391 section 3.1',jsonb_build_object('n_bytes',32,'w',16,'len_1',64,'len_2',3,'chain_count',67,'signature_bytes',2144,'hash_family','SHA-256'),'ONE-TIME: a private OTS key signs exactly one message',2144,'PROFILE_ONLY_NO_OTS_KEY_OR_SIGNATURE_IN_GENESIS','A unique one-time private key is required for each separately signed target; reuse is prohibited.'),
('SLH_DSA_FIPS205_NOT_CONFIGURED','SLH-DSA','NIST FIPS 205',jsonb_build_object('parameter_set','NOT_SELECTED','mode','NOT_CONFIGURED'),'Stateless hash-based signature standard',NULL,'REFERENCE_ONLY_NOT_IMPLEMENTED','Do not claim FIPS 205 conformance from WOTS+ alone.');

INSERT INTO v14.signature_policy (
  chain_id, ecdsa_required, wotsplus_required, fips205_required,
  enforcement_status, policy_notes
) VALUES (
  'horizon-core-v1.4', true, true, false,
  'DECLARED_POLICY_NOT_ENFORCED_BY_RUNNING_SWITCH',
  'ECDSA Genesis signature verified. WOTS+ is a declared future dual-signature requirement, but there is no WOTS+ signature/key in GENESIS.json. Implementation must use a one-time key per message, atomic key-use tracking, independent test vectors, and protected key generation/custody. FIPS 205 is a separate profile and is not implemented by this record.'
);

INSERT INTO archive.import_manifest (
  source_database, archive_database, source_tables, backup_file_path,
  backup_sha256, import_status, source_git_commit, notes
) VALUES (
  'horizon_switch', 'horizon_v14_archive',
  ARRAY['public.blocks','public.chain_blocks','public.chain_txes','public.transactions','public.blocks_bak_1794548568','public.blocks_bak_1794548606','public.chain_blocks_bak_1794548568','public.chain_blocks_bak_1794548606'],
  :'dump_path', :'dump_sha256', 'RESTORED_LEDGER_TABLE_SNAPSHOT', :'git_commit',
  'Only the eight identified ledger/block tables were copied. Customer, bank-account, tenant, key-vault, license, and unrelated application tables were excluded. Source database was not modified.'
);
COMMIT;
SQL

DUMP_SHA256="$(sha256sum "$DUMP_FILE" | cut -d ' ' -f 1)"
"${PSQL[@]}" -d "$REGISTRY_DB" \
  -v "genesis_json=$GENESIS_JSON" \
  -v "public_genesis_json=$PUBLIC_GENESIS_JSON" \
  -v "genesis_path=$GENESIS_REL" \
  -v "genesis_sha256=$GENESIS_SHA256" \
  -v "genesis_bytes=$GENESIS_BYTES" \
  -v "public_genesis_path=$PUBLIC_GENESIS_REL" \
  -v "public_genesis_sha256=$PUBLIC_GENESIS_SHA256" \
  -v "public_genesis_bytes=$PUBLIC_GENESIS_BYTES" \
  -v "git_commit=$GIT_COMMIT" \
  -v "dump_path=$DUMP_FILE" \
  -v "dump_sha256=$DUMP_SHA256" \
  -f "$INIT_SQL"

log "7/8 — Verify archived row counts against source"
COUNTS_SQL="SELECT 'blocks' || ':' || count(*) FROM public.blocks UNION ALL SELECT 'chain_blocks' || ':' || count(*) FROM public.chain_blocks UNION ALL SELECT 'chain_txes' || ':' || count(*) FROM public.chain_txes UNION ALL SELECT 'transactions' || ':' || count(*) FROM public.transactions UNION ALL SELECT 'blocks_bak_1794548568' || ':' || count(*) FROM public.blocks_bak_1794548568 UNION ALL SELECT 'blocks_bak_1794548606' || ':' || count(*) FROM public.blocks_bak_1794548606 UNION ALL SELECT 'chain_blocks_bak_1794548568' || ':' || count(*) FROM public.chain_blocks_bak_1794548568 UNION ALL SELECT 'chain_blocks_bak_1794548606' || ':' || count(*) FROM public.chain_blocks_bak_1794548606 ORDER BY 1"
SOURCE_COUNTS="$("${PSQL[@]}" -d "$SOURCE_DB" -Atqc "$COUNTS_SQL")"
ARCHIVE_COUNTS="$("${PSQL[@]}" -d "$ARCHIVE_DB" -Atqc "$COUNTS_SQL")"
printf 'SOURCE COUNTS:\n%s\nARCHIVE COUNTS:\n%s\n' "$SOURCE_COUNTS" "$ARCHIVE_COUNTS"
[[ "$SOURCE_COUNTS" == "$ARCHIVE_COUNTS" ]] || die "Archive row counts differ from source. Keep both databases; investigate before proceeding."

"${PSQL[@]}" -d postgres -v archive_db="$ARCHIVE_DB" -v db_user="$PGUSER" <<'SQL'
REVOKE CONNECT, TEMPORARY ON DATABASE :"archive_db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"archive_db" TO :"db_user";
ALTER DATABASE :"archive_db" SET default_transaction_read_only = on;
SQL

log "8/8 — Run repository Go tests (Go toolchain remains fixed at 1.24.x)"
TEST_LOG="$RUN_DIR/go_test.log"
set +e
GOTOOLCHAIN=local go test -count=1 ./... 2>&1 | tee "$TEST_LOG"
TEST_STATUS=${PIPESTATUS[0]}
set -e

REPORT="$RUN_DIR/bootstrap_report.txt"
cat > "$REPORT" <<REPORT_EOF
HORIZON CORE v1.4 BOOTSTRAP REPORT
Run: $STAMP
Repository: $ROOT
Git branch: $GIT_BRANCH
Git commit: $GIT_COMMIT
Go: $GO_VERSION
Genesis file: $GENESIS_REL
Genesis file SHA-256: $GENESIS_SHA256
Genesis bytes: $GENESIS_BYTES
Public Genesis: $PUBLIC_GENESIS_REL
Public Genesis SHA-256: $PUBLIC_GENESIS_SHA256
Source database: $SOURCE_DB (eight ledger tables only; source unchanged)
Registry database: $REGISTRY_DB
Archive database: $ARCHIVE_DB
Backup dump: $DUMP_FILE
Backup SHA-256: $DUMP_SHA256
Genesis signature: dynamically verified from the actual JSON using secp256k1 ECDSA
Genesis timestamp: 2026-10-31T18:43:01.8552524Z (raw value preserved; Unix seconds stored as 1793472181)
Genesis locked_at: 2026-11-03T04:15:32Z
WOTS+: profile/policy recorded; no WOTS+ key or signature exists in provided Genesis JSON
SLH-DSA FIPS 205: reference only; not implemented or claimed
Archive row counts: source and archive matched
Go test exit code: $TEST_STATUS

Registry URL (no password embedded): postgresql://$PGUSER@$PGHOST:$PGPORT/$REGISTRY_DB
Archive URL (no password embedded): postgresql://$PGUSER@$PGHOST:$PGPORT/$ARCHIVE_DB

Canonical promotion: only the locked Genesis artifact is registered as canonical.
Block #1 remains a declared checkpoint; its full header/signature were not supplied for independent verification.
Historical source records remain in separate archive database without renumbering or rewriting.
REPORT_EOF

printf '\n===== BOOTSTRAP REPORT =====\n'
cat "$REPORT"
printf '\nRun artifacts: %s\n' "$RUN_DIR"
printf 'Go test log: %s\n' "$TEST_LOG"

if [[ "$TEST_STATUS" -ne 0 ]]; then
  printf '\nWARNING: PostgreSQL Registry and Archive were created and row counts matched, but Go tests FAILED (exit %s). Review %s\n' "$TEST_STATUS" "$TEST_LOG" >&2
  exit 2
fi

log "SUCCESS — Genesis verified, full artifact registered, eight ledger tables archived, row counts matched, and Go tests passed."
