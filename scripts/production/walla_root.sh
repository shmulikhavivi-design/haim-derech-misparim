#!/usr/bin/env bash
# walla_root — READ ONLY root-cause check for Walla 554. Sends no email, changes nothing anywhere.
# Public repo: recipient addresses masked (6-char id + domain); no secrets printed.
set +e +o pipefail
BUF=/tmp/wr_buf.txt; : > $BUF
w(){ printf '%s\n' "$*" >> $BUF; }
flush(){ python3 -I - "$BUF" <<'PY'
import sys
t=open(sys.argv[1],encoding='utf-8').read(); n=3300; parts=[t[i:i+n] for i in range(0,len(t),n)] or ['']
for i,c in enumerate(parts[:12],1):
    c=c.replace('%','%25').replace('\r','%0D').replace('\n','%0A')
    print(f'::notice title=wr-part-{i}-of-{len(parts)}::{c}')
PY
}
trap flush EXIT
A="https://api.supabase.com/v1/projects/$PROD_REF"
D=haimderechmisparim.com
dq(){ dig +short @1.1.1.1 "$@" 2>/dev/null | tr '\n' ' '; }
command -v dig >/dev/null || sudo apt-get install -y -qq dnsutils >/dev/null 2>&1
K=$(printf '%s' "${GH_BREVO_API:-}" | tr -d '[:space:]"'"'")
w "== 1. BREVO — full 554 text + sending IP, Walla events (last 7 days) =="
if [ -n "$K" ]; then
  bv(){ curl -sS -m 60 -G -H "api-key: $K" -H 'accept: application/json' "https://api.brevo.com/v3/$1" "${@:2}"; }
  bv smtp/statistics/events --data-urlencode "days=7" --data-urlencode "limit=2500" --data-urlencode "sort=desc" > /tmp/ev.json
  jq -r '[.events[]? | select(((.email//"")|ascii_downcase|test("@walla\\.(com|co\\.il)$")))] | .[]
    | (.date|.[0:16]) + " " + .event + " | from=" + (.from//"?") + " | ip=" + (.ip//"-") + " | tag=" + (.tag//"-") + " | msgid-domain=" + ((.messageId//"")|split("@")[1]//"-" ) + (if (.reason//"")!="" then "\n   REASON: " + .reason else "" end)' /tmp/ev.json | sed -E 's/[A-Za-z0-9._%+-]+@(walla\.[a-z.]+)/<user>@\1/g' >> $BUF
  w "== 1b. Same IPs/domains delivering OK to other domains? (last 7 days, delivered by sender domain) =="
  jq -c '[.events[]? | select(.event=="delivered") | {f:((.from//"?")|split("@")[1]), d:((.email//"")|split("@")[1]|ascii_downcase)}] | group_by(.f) | map({from:.[0].f, n:length, domains:([.[].d]|unique|.[0:8])})' /tmp/ev.json >> $BUF
  w "== 1c. Brevo account / senders / domains =="
  bv account | jq -c '{plan:[.plan[]?|{type,credits}], relay:.relay.enabled}' >> $BUF 2>&1
  bv senders | jq -c '[.senders[]?|{email,name,active,ips:(.ips//[]|length)}]' >> $BUF 2>&1
  bv senders/domains | jq -c '[.domains[]?|{domain_name,authenticated,verified,ip}]' >> $BUF 2>&1
  bv "senders/domains/$D" | jq -c '{domain,verified,authenticated,dns_records:(.dns_records|to_entries|map({k:.key,status:.value.status,host:.value.host_name}))}' >> $BUF 2>&1
  rm -f /tmp/ev.json
else w "BREVO_API_KEY not available"; fi

w "== 2. DNS of sender domain (1.1.1.1) =="
w "root TXT: $(dq TXT $D)"
w "root MX : $(dq MX $D)"
w "root A  : $(dq A $D)"
w "_dmarc  : $(dq TXT _dmarc.$D)"
w "brevo1 DKIM CNAME: $(dq CNAME brevo1._domainkey.$D)"
w "NS: $(dq NS $D)"
w "== 2b. Domain age (RDAP) =="
curl -sS -m 30 "https://rdap.verisign.com/com/v1/domain/$D" | jq -c '[.events[]?|{(.eventAction):.eventDate}]|add' >> $BUF 2>&1
w "== 2c. Walla MX (who filters) =="
w "walla.com: $(dq MX walla.com) | walla.co.il: $(dq MX walla.co.il)"

w "== 3. SUPABASE Production auth config (mail-related, no secrets) =="
AC=$(curl -sS -m 30 -o /tmp/ac.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$A/config/auth")
w "config/auth HTTP $AC"
[ "$AC" = 200 ] && jq -c '{site_url, smtp_host, smtp_port, smtp_admin_email, smtp_sender_name, smtp_user_set:((.smtp_user//"")!=""), smtp_max_frequency, rate_limit_email_sent, mailer_autoconfirm, external_email_enabled, mailer_secure_email_change_enabled, hook_send_email_enabled, confirm_subject:.mailer_subjects_confirmation, confirm_tpl_len:((.mailer_templates_confirmation_content//"")|length), confirm_tpl_links:([(.mailer_templates_confirmation_content//"")|scan("https?://[^\"<> ]+")]|unique)}' /tmp/ac.json >> $BUF
rm -f /tmp/ac.json

w "== 4. SUPABASE Production — Walla accounts (read-only endpoint) =="
RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
roq "select substr(encode(convert_to(lower(email),'UTF8'),'base64'),1,6) id, split_part(email,'@',2) dom,
  to_char(created_at at time zone 'Asia/Jerusalem','YYYY-MM-DD HH24:MI') created,
  coalesce(to_char(confirmation_sent_at at time zone 'Asia/Jerusalem','YYYY-MM-DD HH24:MI'),'-') conf_sent,
  coalesce(to_char(email_confirmed_at at time zone 'Asia/Jerusalem','YYYY-MM-DD HH24:MI'),'NO') confirmed,
  coalesce(to_char(last_sign_in_at at time zone 'Asia/Jerusalem','YYYY-MM-DD HH24:MI'),'never') last_login,
  exists(select 1 from public.profiles p where p.id=u.id) has_profile
  from auth.users u where lower(email) ~ '@walla\\.(com|co\\.il)\$' order by created_at" | jq -c '.[]?' >> $BUF 2>&1 || w "query failed"
roq "select count(*) total, count(*) filter (where email_confirmed_at is null) unconfirmed, max(created_at) at time zone 'Asia/Jerusalem' last_signup from auth.users" | jq -c . >> $BUF 2>&1
w "walla_root — read only. Nothing changed, no email sent."
