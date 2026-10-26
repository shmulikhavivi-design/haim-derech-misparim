#!/usr/bin/env bash
# tokaudit (26.10) — אילו טוקנים/כתובות קיימים ב-GitHub (סביבת production + רמת הריפו) ומה כל אחד מסוגל לעשות.
# בדיקת כתיבה למסד = יצירת טבלה זמנית (temporary) שנעלמת מיד בסוף הבקשה — שום דבר לא נשמר. ערכים לא מודפסים.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; OUT=""
for n in PRODUCTION_SUPABASE_TOKEN PRODUCTION_FUNCTIONS_TOKEN PRODUCTION_DB_WRITE_TOKEN SUPABASE_ACCESS_TOKEN SUPABASE_TOKEN SUPABASE_PAT SUPABASE_MANAGEMENT_TOKEN PRODUCTION_DB_URL PROD_DB_URL SUPABASE_DB_URL DATABASE_URL DB_URL SUPABASE_DB_PASSWORD PRODUCTION_DB_PASSWORD SUPABASE_SERVICE_ROLE_KEY SUPABASE_SECRET_KEY; do
  v="${!n:-}"; [ -n "$v" ] || continue; echo "::add-mask::$v"
  case "$v" in
    sbp_*)
      f=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $v" "$A/functions")
      r=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $v" -H 'Content-Type: application/json' "$A/database/query/read-only" -d '{"query":"select 1"}')
      wr=$(curl -sS -m 30 -w '\n%{http_code}' -X POST -H "Authorization: Bearer $v" -H 'Content-Type: application/json' "$A/database/query" -d '{"query":"create temporary table hdm_probe_tmp(x int); select 1 ok"}')
      wc=$(echo "$wr" | tail -n1); wm=$(echo "$wr" | sed '$d' | jq -r '.message // empty' 2>/dev/null | grep -o 'read-only transaction\|permission[^"]*' | head -1)
      w=$([ "$wc" = 201 ] && echo "✅ כתיבה" || echo "❌ HTTP $wc ${wm}")
      OUT="$OUT
$n: טוקן Supabase | פונקציות: $([ "$f" = 200 ] && echo ✅ || echo "❌ $f") | קריאת מסד: $([ "$r" = 201 ] && echo ✅ || echo "❌ $r") | כתיבה למסד: $w";;
    postgres*://*)
      case "$v" in *"$PROD_REF"*) ;; *) OUT="$OUT
$n: כתובת מסד שאינה של Production — לא נבדקה"; continue;; esac
      x=$(PGCONNECT_TIMEOUT=10 psql "$v" -X -At -c "create temporary table hdm_probe_tmp(x int); select current_user || ' ro=' || current_setting('transaction_read_only')" 2>&1 | tail -1 | cut -c1-80)
      OUT="$OUT
$n: כתובת מסד Production | $x";;
    *) OUT="$OUT
$n: קיים (מפתח שאינו טוקן ניהול — לא מתאים להתקנת פונקציות במסד)";;
  esac
done
ann notice "tok-audit" "${OUT:-לא נמצא אף טוקן}"
ann notice "prod-result" "✅ tokaudit: בלי שינויים"
