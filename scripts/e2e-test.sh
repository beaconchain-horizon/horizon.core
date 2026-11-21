#!/bin/bash
set -e
export ADMIN_TOKEN="bench0000000000000000000000000000000000000000000000000000000bench"
export HORIZON_LICENSE_PUBLIC_KEY="04cf6aaaba8e7a6fddde63a2e2588553dc95503d2de6b2a5c78f4a30a0b91b0aca4d28d06fc1ccbaf730abe1dcda7c29726dab18008353b521c9253c04b1641214"
export PGPASSWORD=postgres

LIC="E2E-$(date +%s)"
echo "→ 1) صدور لایسنس: $LIC"
curl -s -X POST http://localhost:8091/api/v1/admin/license/issue \
  -H "Content-Type: application/json" -H "X-Admin-Token: $ADMIN_TOKEN" \
  -d "{\"license_id\":\"$LIC\",\"user_id\":\"e2e_user\",\"product_id\":\"horizon-core\",\"volume\":100,\"duration\":365}" > /dev/null

echo "→ 2) گرفتن session"
SES=$(curl -s -X POST http://localhost:8091/api/v1/signing/session -H "X-Admin-Token: $ADMIN_TOKEN" | grep -oE '"session_token":"[^"]*"' | cut -d'"' -f4)
echo "   session: ${SES:0:24}..."

echo "→ 3) ثبت تراکنش"
curl -s -X POST http://localhost:8091/api/v1/tx \
  -H "Content-Type: application/json" -H "X-Admin-Token: $ADMIN_TOKEN" \
  -H "X-License-ID: $LIC" -H "X-Session-Token: $SES" \
  -d '{"from":"e2e_user","to":"e2e_rcv","amount":1,"type":"e2e"}' > /dev/null

echo "→ 4) ماین"
MINE=$(curl -s -X POST http://localhost:8091/api/v1/block/mine \
  -H "Content-Type: application/json" -H "X-Admin-Token: $ADMIN_TOKEN" -d '{}')
echo "   $MINE"
NEW_BLOCK=$(echo "$MINE" | grep -oE '"block_num":[0-9]+' | cut -d: -f2)

echo
echo "→ 5) Verify فقط بلاک جدید ($NEW_BLOCK)"
./horizon-verifier.exe -v 2>&1 | grep -E "B${NEW_BLOCK}|hash-${NEW_BLOCK}|→ [0-9]+/"
