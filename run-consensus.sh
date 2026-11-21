cat << 'EOF' > run-consensus.sh
#!/bin/bash

# ==========================================
# Horizon Core - Distributed Consensus Launcher
# ==========================================

# Environment variables (must match Switch settings)
export HORIZON_LICENSE_PUBLIC_KEY="04cf6aaaba8e7a6fddde63a2e2588553dc95503d2de6b2a5c78f4a30a0b91b0aca4d28d06fc1ccbaf730abe1dcda7c29726dab18008353b521c9253c04b1641214"
export ADMIN_TOKEN="bench0000000000000000000000000000000000000000000000000000000bench"
export GENESIS_HASH="8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603"

# Create logs directory
mkdir -p logs

echo "Starting 8 consensus nodes..."
echo "----------------------------------------"

# Start 7 specialty nodes
NODE_ROLE=MERKLE NODE_PORT=9001 go run ./cmd/angel-node > logs/node-9001.log 2>&1 &
echo "Node 9001 (Merkle) started."

NODE_ROLE=HASH NODE_PORT=9002 go run ./cmd/angel-node > logs/node-9002.log 2>&1 &
echo "Node 9002 (Hash) started."

NODE_ROLE=ECDSA NODE_PORT=9003 go run ./cmd/angel-node > logs/node-9003.log 2>&1 &
echo "Node 9003 (ECDSA) started."

NODE_ROLE=TYPE NODE_PORT=9004 go run ./cmd/angel-node > logs/node-9004.log 2>&1 &
echo "Node 9004 (Type) started."

NODE_ROLE=VOLUME NODE_PORT=9005 go run ./cmd/angel-node > logs/node-9005.log 2>&1 &
echo "Node 9005 (Volume) started."

NODE_ROLE=TIME NODE_PORT=9006 go run ./cmd/angel-node > logs/node-9006.log 2>&1 &
echo "Node 9006 (Time) started."

NODE_ROLE=USER NODE_PORT=9007 go run ./cmd/angel-node > logs/node-9007.log 2>&1 &
echo "Node 9007 (User) started."

# Start 1 inspector node
go run ./cmd/agent-node > logs/node-9008.log 2>&1 &
echo "Node 9008 (Agent/Inspector) started."

echo "----------------------------------------"
echo "Waiting 5 seconds for nodes to initialize..."
sleep 5

# Check status
echo "Checking listening ports:"
netstat -ano | grep LISTENING | grep -E "900[1-8]" || echo "No ports in range 9001-9008 are listening. Check logs."

echo "----------------------------------------"
echo "Done. 8 nodes are running in background."
echo "Logs are in the logs/ directory."
echo "To stop all nodes, use: taskkill /F /IM angel-node.exe"
EOF

chmod +x run-consensus.sh
./run-consensus.sh
