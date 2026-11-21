#!/bin/bash
set -u
echo "═══ HORIZON HEALTH CHECK — $(date '+%Y-%m-%d %H:%M:%S') ═══"

declare -A SVC=([8091]="Switch-Online" [8092]="Switch-Offline" [9001]="Angel-Merkle" [9002]="Angel-Hash" [9003]="Angel-ECDSA" [9004]="Angel-Type" [9005]="Angel-Volume" [9006]="Angel-Time" [9007]="Angel-User" [9008]="Agent-Guardian")
CRIT=(8091 9001 9002 9003 9004 9005 9006 9007 9008)
UP=0; DOWN=0; CDOWN=0
for port in 8091 8092 9001 9002 9003 9004 9005 9006 9007 9008; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:$port/health" 2>/dev/null || echo "000")
  crit=0; for c in "${CRIT[@]}"; do [[ "$c" == "$port" ]] && crit=1; done
  if [[ "$code" == "200" ]]; then printf "  ✅ %-5s %-18s [OK]\n" "$port" "${SVC[$port]}"; UP=$((UP+1))
  elif [[ $crit -eq 1 ]]; then printf "  ❌ %-5s %-18s [DOWN ⚠]\n" "$port" "${SVC[$port]}"; DOWN=$((DOWN+1)); CDOWN=$((CDOWN+1))
  else printf "  ⚪ %-5s %-18s [off]\n" "$port" "${SVC[$port]}"; DOWN=$((DOWN+1)); fi
done
echo "  خلاصه: $UP up | $DOWN down | $CDOWN critical-down"

export PGPASSWORD="${PGPASSWORD:-postgres}"
BI=$(psql -U postgres -h localhost -d horizon_switch -t -A -c "SELECT COUNT(*),MIN(block_num),MAX(block_num) FROM chain_blocks;" 2>/dev/null)
if [[ -n "$BI" ]]; then
  C=$(echo "$BI"|cut -d'|' -f1); MN=$(echo "$BI"|cut -d'|' -f2); MX=$(echo "$BI"|cut -d'|' -f3)
  echo "  📦 بلاک‌ها: $C | بازه: $MN→$MX"
else echo "  ❌ PostgreSQL وصل نشد"; fi
G=$(psql -U postgres -h localhost -d horizon_switch -t -A -c "SELECT hash FROM chain_blocks WHERE block_num=0;" 2>/dev/null)
if [[ "$G" == "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603" ]]; then echo "  ✅ جنسیس سالم"
elif [[ -z "$G" ]]; then echo "  ⚠ جنسیس یافت نشد"
else echo "  ❌ جنسیس مطابقت ندارد"; fi

for exe in horizon-switch.exe horizon-angel.exe horizon-agent.exe; do
  n=$(tasklist //FI "IMAGENAME eq $exe" 2>/dev/null | grep -c "$exe")
  [[ "$n" -gt 0 ]] && printf "  ✅ %-25s (%s proc)\n" "$exe" "$n" || printf "  ❌ %-25s (not running)\n" "$exe"
done

if [[ $CDOWN -eq 0 ]] && [[ -n "$BI" ]] && [[ "$G" == "8c0763dd5b1345cba0782f03163e8a69de49bede54c91bb878126742c7990603" ]]; then
  echo "  🟢 سالم"; exit 0
elif [[ $CDOWN -gt 0 ]]; then echo "  🔴 خراب — ری‌استارت لازم"; exit 1
else echo "  🟡 هشدار"; exit 2; fi
