#!/usr/bin/env bash
# incident7 — הרשמה מלאה דרך הטופס באתר החי (Chrome + אייפון, שתי הכתובות). משתמשי בדיקה בתיבת האפליקציה; בלי אישור מייל → בלי פרופיל גלוי.
set +e +o pipefail
python3 -m pip install -q playwright >/dev/null && python3 -m playwright install --with-deps chromium webkit >/dev/null 2>&1 || stop "התקנת הדפדפנים נכשלה"
OUT=$(T="${GITHUB_RUN_ID:-x}" timeout 900 python3 "$HERE/incident_ui_signup.py" 2>&1 | tail -c 6000)
for k in chrome-gh chrome-cf iphone-gh iphone-cf; do ann notice "i7-$k" "$(echo "$OUT" | jq -c --arg k "$k" '.[$k]' 2>/dev/null | cut -c1-2500)"; done
echo "$OUT" | jq -e . >/dev/null 2>&1 || ann warning "i7-raw" "$(echo "$OUT" | tail -c 1500)"
ann notice "prod-result" "incident7 הסתיים — משתמשי בדיקה בלבד, בלי פרופיל גלוי"
