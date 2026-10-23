#!/usr/bin/env bash
# mailtest — שליחת מייל בדיקה אחד בלבד (אישור ביטול מנוי) לבעלים, באישורו 23.10 11:32. בלי פריסה, בלי משימות, בלי התראות.
# לוקחים מהתור רק את המייל של חשבון הבעלים (לפי טביעת האימייל), שולחים דרך Brevo, ומסמנים רק אותו כנשלח.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"; RW="$A/database/query"
OWNER_MD5='162e004328485070b0af8b256ad2e798'; FROM='life.through.numbers333@gmail.com'
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
[ -n "${GH_BREVO_API:-}" ] || stop "אין מפתח Brevo לתהליך. לא נשלח כלום."
echo "::add-mask::$GH_BREVO_API"
K=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -H "api-key: $GH_BREVO_API" "https://api.brevo.com/v3/smtp/templates?limit=1" || echo 000)
[ "$K" = 200 ] || stop "מפתח Brevo לא תקף לשליחה (HTTP $K). לא נשלח כלום."
ann notice "mt-1-key" "✅ מפתח Brevo תקף לשליחה טרנזקציונית"
Q="select json_agg(json_build_object('id', e.id, 'kind', e.kind, 'subject', e.subject, 'body', e.body_text, 'to', u.email, 'owner', md5(lower(u.email)) = '$OWNER_MD5')) r
   from public.hdm_email_outbox e join auth.users u on u.id = e.user_id where e.sent_at is null"
roq "$Q" > /tmp/q.json
ALL=$(jq -r '.[0].r | length' /tmp/q.json); OWN=$(jq -c '[.[0].r[] | select(.owner)]' /tmp/q.json)
[ "$(echo "$OWN" | jq length)" = 1 ] || stop "לא נמצא בדיוק מייל אחד של הבעלים בתור (נמצאו $(echo "$OWN" | jq length)). לא נשלח כלום."
TO=$(echo "$OWN" | jq -r '.[0].to'); echo "::add-mask::$TO"
[ "$(printf '%s' "$TO" | tr 'A-Z' 'a-z' | md5sum | cut -d' ' -f1)" = "$OWNER_MD5" ] || stop "הנמען אינו הבעלים. לא נשלח כלום."
ID=$(echo "$OWN" | jq -r '.[0].id'); KIND=$(echo "$OWN" | jq -r '.[0].kind')
ann notice "mt-2-recipient" "✅ נמען: חשבון הבעלים בלבד (אומת לפי טביעת האימייל) | סוג: $KIND | בתור סה״כ: $ALL (רק של הבעלים נשלח)"
BODY=$(echo "$OWN" | jq -c --arg from "$FROM" '.[0] | {sender: {name: "חיים דרך מספרים", email: $from}, to: [{email: .to}], replyTo: {email: $from}, subject: .subject, textContent: .body, tags: ["hdm-cancel-test-owner"]}')
C=$(curl -sS -m 30 -o /tmp/send.json -w '%{http_code}' -X POST -H "api-key: $GH_BREVO_API" -H 'content-type: application/json' -H 'accept: application/json' https://api.brevo.com/v3/smtp/email -d "$BODY" || echo 000)
MID=$(jq -r '.messageId // empty' /tmp/send.json)
if [ "$C" = 201 ] || [ "$C" = 200 ]; then
  ann notice "mt-3-send" "✅ Brevo קיבל את המייל לשליחה (HTTP $C, מזהה הודעה התקבל: $([ -n "$MID" ] && echo כן || echo לא))"
  U=$(curl -sS -m 60 -o /tmp/u.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "update public.hdm_email_outbox set sent_at = now(), attempts = attempts + 1, last_error = null where id = $ID and sent_at is null returning id" '{query:$q}')")
  ann notice "mt-4-mark" "המייל סומן בתור כנשלח: HTTP $U $(jq -c '.' /tmp/u.json | cut -c1-60)"
else
  ann error "mt-3-send" "❌ Brevo לא קיבל (HTTP $C): $(jq -c '{code, message}' /tmp/send.json | cut -c1-200). המייל נשאר בתור."
fi
sleep 45
if [ -n "$MID" ]; then
  EV=$(curl -sS -m 30 -G -H "api-key: $GH_BREVO_API" "https://api.brevo.com/v3/smtp/statistics/events" --data-urlencode "messageId=$MID" --data-urlencode "limit=20" | jq -c '[.events[]? | {event, at: (.date|.[11:19]), reason: ((.reason // "")|.[0:80])}]')
  ann notice "mt-5-status" "סטטוס במסירה לפי Brevo (אחרי 45 שניות): $EV"
fi
ann notice "mt-6-scope" "לא נפרס דבר, לא הותקנו משימות או התראות, לא נשלח לאף משתמש אחר, לא בוצע חיוב"
ann notice "prod-result" "mailtest הסתיים"
