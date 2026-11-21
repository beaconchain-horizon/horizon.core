#!/usr/bin/env bash

set +e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

REPORT_DIR="$HOME/horizon-v14-backups"
mkdir -p "$REPORT_DIR"

STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="$REPORT_DIR/consensus-node-audit-$STAMP.txt"

exec > >(tee "$REPORT") 2>&1

section() {
    echo ""
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

show_file() {
    local file="$1"
    local start="${2:-1}"
    local end="${3:-500}"

    if test -f "$file"; then
        echo ""
        echo "----- $file ($start-$end) -----"
        sed -n "${start},${end}p" "$file"
    else
        echo "NOT FOUND: $file"
    fi
}

section "1. REPOSITORY AND TOOLCHAIN"
echo "ROOT: $ROOT"
echo "BRANCH: $(git branch --show-current)"
echo "COMMIT: $(git rev-parse HEAD)"
go version

section "2. NODE SOURCE FILES"
find cmd/angel-node cmd/agent-node internal/consensus \
    -maxdepth 3 -type f \
    \( -name '*.go' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) \
    -print 2>/dev/null

section "3. SWITCH CONSENSUS CLIENT"
show_file cmd/switch/consensus_client.go 1 240

section "4. CONSENSUS NODE MAIN SOURCE"
show_file cmd/angel-node/main.go 1 500

section "5. AGENT NODE SOURCE"
show_file cmd/agent-node/main.go 1 400

section "6. ALL NODE ROUTES AND LISTENERS"
grep -Rni --include='*.go' \
    --exclude-dir=vendor --exclude-dir=.git \
    -E 'func main|HandleFunc|http\.Handle|ListenAndServe|\.Run\(|router\.(GET|POST)|900[1-8]' \
    cmd/angel-node cmd/agent-node cmd/switch internal/consensus \
    2>/dev/null | head -n 350

section "7. CONSENSUS VOTE AND DECISION LOGIC"
grep -Rni --include='*.go' \
    --exclude-dir=vendor --exclude-dir=.git \
    -E 'Vote|vote|Accept|Reject|accepted|rejected|critical|majority|consensus|Validate|validate|fail.closed' \
    cmd/angel-node cmd/agent-node cmd/switch internal/consensus \
    2>/dev/null | head -n 400

section "8. MERKLE, TXID, HASH AND LICENSE VALIDATION"
grep -Rni --include='*.go' \
    --exclude-dir=vendor --exclude-dir=.git \
    -E 'MerkleRoot|MerkleProof|Proof|TxID|TxHash|BlockHash|PrevHash|WOTSSignature|WOTSPubKey|LicenseID|Volume|ExpiresAt|UserID|MerkleType' \
    cmd/angel-node cmd/agent-node cmd/switch internal/consensus \
    2>/dev/null | head -n 450

section "9. MERKLE IMPLEMENTATIONS"
show_file internal/merkle/merkle.go 1 300
show_file internal/merkle/ternary.go 1 300

section "10. BLOCK PAYLOAD AND SIGNATURE FLOW"
show_file cmd/switch/switch.go 580 700
show_file cmd/switch/consensus_client.go 1 160

section "11. WOTS LICENSE PATH — SECURITY REVIEW"
show_file cmd/switch/admin.go 260 305
show_file internal/crypto/wots/wots.go 1 140

section "12. CONSENSUS LAW AND NODE DOCUMENTS"
find . -type f \
    \( -iname '*ANGEL*LAW*.md' \
       -o -iname '*CONSENSUS*.md' \
       -o -iname '*NODE*.md' \) \
    -not -path './.git/*' \
    -not -path './vendor/*' \
    -print

grep -Rni --include='*.md' \
    --exclude-dir=.git --exclude-dir=vendor \
    -E '9001|9002|9003|9004|9005|9006|9007|9008|Merkle Proof|Merkle Root|TxID|PBFT|FAIL.CLOSED|MAJORITY' \
    docs cmd/angel-node cmd/agent-node \
    2>/dev/null | head -n 350

section "13. LIVE WINDOWS LISTENERS"
netstat -ano -p tcp 2>/dev/null \
    | grep -E ':(8080|8091|9001|9002|9003|9004|9005|9006|9007|9008)[[:space:]]' \
    | grep LISTENING

section "14. SWITCH AND CONSENSUS CONFIG REFERENCES"
grep -Rni \
    --include='*.go' --include='*.json' --include='*.yaml' --include='*.yml' \
    --exclude-dir=.git --exclude-dir=vendor \
    -E '9001|9002|9003|9004|9005|9006|9007|9008|consensus_nodes|angel_nodes|node_urls' \
    cmd internal config 2>/dev/null | head -n 350

section "15. WOTS AND ECDSA TEST STATUS"
GOTOOLCHAIN=local go test -count=1 ./internal/crypto/wots
GOTOOLCHAIN=local go test -count=1 ./internal/crypto

section "AUDIT COMPLETED"
echo "Report: $REPORT"
echo "This report is source inspection only."
echo "No database rows, USB files, private keys, or source files were modified."
