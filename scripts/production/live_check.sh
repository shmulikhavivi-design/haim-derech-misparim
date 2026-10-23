#!/usr/bin/env bash
# livecheck — מריץ את live_check.py (אתר חי + Production, בלי תשלום). ראו הסבר בקובץ.
set +e +o pipefail
python3 -m pip install -q playwright >/dev/null 2>&1 && timeout 420 python3 -m playwright install --with-deps chromium >/dev/null 2>&1
OUT=$(PROD_REF="$PROD_REF" TOK="$TOK" BREVO_API_KEY="$GH_BREVO_API" timeout 900 python3 "$HERE/live_check.py" 2>&1); RC=$?
echo "$OUT" | tail -60
ann notice "lv-result" "$(echo "$OUT" | grep -E '^(PASS|FAIL|ERROR|SUMMARY|משתמש)' | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email>/g' | tail -n 40)"
[ $RC -eq 0 ] || stop "livecheck: נמצאה תקלה — עוצר (ראו פירוט)"
ann notice "prod-result" "✅ livecheck: $(echo "$OUT" | grep '^SUMMARY' | tail -1)"
