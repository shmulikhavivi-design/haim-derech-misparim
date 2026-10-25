#!/usr/bin/env bash
# walla_log — READ ONLY. Brevo event logs + Supabase auth records for Walla recipients.
# Sends no email, changes nothing in Supabase/DB/Brevo/DNS. Public repo: addresses are masked (6-char id + domain).
set +e +o pipefail
BUF=/tmp/wl_buf.txt; : > $BUF
w(){ printf '%s\n' "$*" >> $BUF; }
flush(){ python3 -I - "$BUF" <<'PY'
import sys
t=open(sys.argv[1],encoding='utf-8').read(); n=3300; parts=[t[i:i+n] for i in range(0,len(t),n)] or ['']
for i,c in enumerate(parts[:9],1):
    c=c.replace('%','%25').replace('\r','%0D').replace('\n','%0A')
    print(f'::notice title=wl-part-{i}-of-{len(parts)}::{c}')
PY
}
trap flush EXIT
K=$(printf '%s' "${GH_BREVO_API:-}" | tr -d '[:space:]"'"'")
if [ -n "$K" ]; then
  bv(){ curl -sS -m 60 -G -H "api-key: $K" -H 'accept: application/json' "https://api.brevo.com/v3/$1" "${@:2}"; }
  : > /tmp/all.json
  for off in 0 2500 5000; do
    bv smtp/statistics/events --data-urlencode "days=90" --data-urlencode "limit=2500" --data-urlencode "offset=$off" --data-urlencode "sort=asc" > /tmp/e.json
    jq -c '.events[]?' /tmp/e.json >> /tmp/all.json
    [ "$(jq '.events|length' /tmp/e.json 2>/dev/null || echo 0)" -lt 2500 ] && break
  done
  w "== BREVO (90 days) — all events to Walla, per recipient (masked id) =="
  jq -s -r '
    [.[] | select(((.email//"")|ascii_downcase|test("@walla\\.(com|co\\.il)$")))]
    | group_by(.email|ascii_downcase)
    | .[] | "R " + ((.[0].email|ascii_downcase|@base64)|.[0:6]) + " @" + (.[0].email|split("@")[1]) + "\n"
      + ( [ .[] | "  " + (.date|.[0:16]) + " " + .event + " | " + ((.subject//"")|.[0:26]) + " | from " + ((.from//"?")|split("@")[1]) + ( if (.reason//"")!="" then " | " + (.reason|.[0:95]) else "" end) ] | join("\n") )
  ' /tmp/all.json >> $BUF
  w "== BREVO totals Walla by event =="
  jq -s -c '[.[] | select(((.email//"")|ascii_downcase|test("@walla\\.(com|co\\.il)$"))) | .event] | group_by(.) | map({(.[0]):length}) | add' /tmp/all.json >> $BUF
  w "== BREVO any Walla 'delivered' ever? =="
  jq -s -c '[.[] | select(((.email//"")|ascii_downcase|test("@walla\\.(com|co\\.il)$")) and .event=="delivered")] | length' /tmp/all.json >> $BUF
  w "== BREVO other Cisco-filtered/IL domains (non-gmail) summary =="
  jq -s -c '[.[] | {d:((.email//"")|split("@")[1]|ascii_downcase), e:.event}] | group_by(.d) | map({d:.[0].d, ev:(group_by(.e)|map({(.[0].e):length})|add)}) | map(select(.d!="gmail.com"))' /tmp/all.json | cut -c1-900 >> $BUF
  rm -f /tmp/all.json /tmp/e.json
else
  w "BREVO_API_KEY not available"
fi
if [ -n "${DB:-}" ]; then
  w "== SUPABASE Production auth.users — Walla accounts (read-only) =="
  PGOPTIONS='-c default_transaction_read_only=on' psql "$DB" -X -At -F ' | ' -c "
    select substr(encode(convert_to(lower(email),'UTF8'),'base64'),1,6) as id, split_part(email,'@',2),
      'created '||to_char(created_at at time zone 'Asia/Jerusalem','YYYY-MM-DD HH24:MI'),
      'conf_sent '||coalesce(to_char(confirmation_sent_at at time zone 'Asia/Jerusalem','YYYY-MM-DD HH24:MI'),'-'),
      'confirmed '||coalesce(to_char(email_confirmed_at at time zone 'Asia/Jerusalem','YYYY-MM-DD HH24:MI'),'NO'),
      'recovery_sent '||coalesce(to_char(recovery_sent_at at time zone 'Asia/Jerusalem','YYYY-MM-DD HH24:MI'),'-'),
      'last_login '||coalesce(to_char(last_sign_in_at at time zone 'Asia/Jerusalem','YYYY-MM-DD HH24:MI'),'never'),
      'profile '||case when exists(select 1 from public.profiles p where p.id=u.id) then 'yes' else 'no' end
    from auth.users u where lower(email) ~ '@walla\.(com|co\.il)$' order by created_at;" >> $BUF 2>&1 || w "DB query failed"
  w "== SUPABASE all users: unconfirmed by domain =="
  PGOPTIONS='-c default_transaction_read_only=on' psql "$DB" -X -At -F ' | ' -c "select split_part(lower(email),'@',2), count(*), count(*) filter (where email_confirmed_at is null) from auth.users group by 1 order by 2 desc limit 15;" >> $BUF 2>&1
else
  w "PRODUCTION_DB_URL not available"
fi
LC=$(curl -sS -m 30 -o /tmp/lg.json -w '%{http_code}' -G -H "Authorization: Bearer $TOK" "https://api.supabase.com/v1/projects/$PROD_REF/analytics/endpoints/logs.all" --data-urlencode "sql=select timestamp, event_message from auth_logs where event_message like '%mail%' order by timestamp desc limit 30")
w "== SUPABASE auth logs API: HTTP $LC =="
[ "$LC" = 200 ] && jq -r '.result[]? | "  " + (.timestamp|tostring) + " " + (.event_message|.[0:160])' /tmp/lg.json | sed -E 's/[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+)/<user>@\1/g' >> $BUF
rm -f /tmp/lg.json
w "walla_log — read only. Nothing changed, no email sent."
