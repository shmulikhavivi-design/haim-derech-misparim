#!/usr/bin/env bash
# livecheck2 — מריץ את live_check2.py
set +e +o pipefail
python3 -m pip install -q playwright >/dev/null 2>&1 && timeout 420 python3 -m playwright install --with-deps chromium >/dev/null 2>&1
case "${COMMIT_MSG:-}" in *diagonly*) OUT="diag"; RC=1;; *) OUT=$(PROD_REF="$PROD_REF" TOK="$TOK" BREVO_API_KEY="$GH_BREVO_API" timeout 900 python3 "$HERE/live_check2.py" 2>&1); RC=$?;; esac
echo "$OUT" | tail -60
ann notice "lv2-result" "$(echo "$OUT" | grep -E '^(PASS|FAIL|ERROR|SUMMARY|INFO|חשבונות)' | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email>/g' | tail -n 40)"
ann notice "lv2-diag" "$(echo "$OUT" | grep -E "^(DIAG|PAYBTN|PAYCLICK|PAYMSG|CONSOLE)" | cut -c1-1500)"
ann notice "lv2-testusers" "$(curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d '{"query":"select count(*) n, count(*) filter (where email_confirmed_at is not null) confirmed from auth.users where email like '"'"'life.through.numbers333+golive-%'"'"'"}')"
[ $RC -eq 0 ] || stop "livecheck2: נמצאה תקלה — עוצר (ראו פירוט)"
ann notice "prod-result" "✅ livecheck2: $(echo "$OUT" | grep '^SUMMARY' | tail -1)"
