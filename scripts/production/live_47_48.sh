#!/usr/bin/env bash
# live4748 (26.10) — READ ONLY: הגרסה החיה בשלוש הכתובות כוללת את #47 ו-#48. רק הורדת הדף הציבורי. אין שינוי.
set +e +o pipefail
OUT=""
for u in https://haimderechmisparim.com/ https://haim-derech-misparim.pages.dev/ https://shmulikhavivi-design.github.io/haim-derech-misparim/; do
  ok=""
  for t in 1 2 3 4 5 6 7 8 9 10 11 12; do
    curl -sS -m 30 -A 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' "${u}?v=$(date +%s%N)" -o /tmp/l.html
    if grep -q hdmPendSet /tmp/l.html && grep -q hdm-age-range-btn /tmp/l.html; then ok=1; break; fi
    sleep 20
  done
  OUT="$OUT
$u → #47: $(grep -q hdmPendSet /tmp/l.html && echo ✅ || echo ❌) | #48: $(grep -q hdm-age-range-btn /tmp/l.html && echo ✅ || echo ❌) | בלי עקיפת גיל: $(grep -q 'matchQueueRelaxed = true' /tmp/l.html && echo ❌ || echo ✅) | 🎯 נשאר מסומן: $(grep -q hdmSetTargetMark /tmp/l.html && echo ✅ || echo ❌) | עדכון אוטומטי: $(grep -q hdmAutoUpdate /tmp/l.html && echo ✅ || echo ❌)"
done
ann notice "live-4748" "$OUT"
ann notice "prod-result" "✅ live4748: קריאה בלבד"
