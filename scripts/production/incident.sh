#!/usr/bin/env bash
# incident — תקלת כניסה (22.10 16:01): קריאה בלבד + משתמש בדיקה אחד בתיבת האפליקציה. לא מוחק, לא מחייב, לא משנה הגדרות.
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"; AU="https://$PROD_REF.supabase.co/auth/v1"
PUB='sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP'
clean(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g'; }
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
# 1. האתר
S1=$(curl -sS -m 30 -o /tmp/gh.html -w '%{http_code} %{time_total}s' https://shmulikhavivi-design.github.io/haim-derech-misparim/ || echo 000)
S2=$(curl -sS -m 30 -o /tmp/cf.html -w '%{http_code} %{time_total}s' https://haim-derech-misparim.pages.dev/ || echo 000)
K1=$(grep -c "$PROD_REF" /tmp/gh.html 2>/dev/null); K2=$(grep -c "$PROD_REF" /tmp/cf.html 2>/dev/null)
P1=$(grep -o "sb_publishable_[A-Za-z0-9_-]*" /tmp/gh.html | sort -u | tr '\n' ' '); P2=$(grep -o "sb_publishable_[A-Za-z0-9_-]*" /tmp/cf.html | sort -u | tr '\n' ' ')
M1=$(md5sum < /tmp/gh.html | cut -c1-8); M2=$(md5sum < /tmp/cf.html | cut -c1-8)
ann notice "i-site" "GitHub Pages: $S1 (Production ref ×$K1, מפתח: ${P1:-אין}, md5 $M1) | Cloudflare: $S2 (ref ×$K2, מפתח: ${P2:-אין}, md5 $M2) | המפתח הצפוי: $( [ "${P1% }" = "$PUB" ] && echo תואם || echo 'לא תואם!')"
# 2. Auth
H=$(curl -sS -m 20 -o /tmp/h.json -w '%{http_code}' -H "apikey: $PUB" "$AU/health" || echo 000)
ST=$(curl -sS -m 20 -H "apikey: $PUB" "$AU/settings" | jq -c '{email: .external.email, disable_signup, autoconfirm: .mailer_autoconfirm}' 2>/dev/null)
C=$(curl -sS -m 30 -o /tmp/cfg.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$A/config/auth" || echo 000)
CF=$(jq -c '{site_url, uri_allow_list, confirm_email: (.mailer_autoconfirm == false), smtp_host, smtp_user_set: ((.smtp_user//"")!=""), smtp_pass_set: ((.smtp_pass // "") != ""), sender_name: .smtp_sender_name, rate_limit_email_sent, rate_limit_verify, rate_limit_token_refresh, rate_limit_otp, smtp_max_frequency, disable_signup, external_email_enabled, mailer_secure_email_change_enabled, password_min_length, password_required_characters, jwt_exp, hook_send_email_enabled, hook_custom_access_token_enabled, hook_password_verification_attempt_enabled, hook_mfa_verification_attempt_enabled, security_captcha_enabled, sessions_timebox, sessions_inactivity_timeout}' /tmp/cfg.json 2>/dev/null | clean)
ann notice "i-auth" "health HTTP $H $(head -c 150 /tmp/h.json | clean) | settings: $ST | config HTTP $C: $CF"
# 3. מסד: הרשמות והתחברויות
DBQ="select json_build_object(
 'users_total', (select count(*) from auth.users),
 'created_24h', (select count(*) from auth.users where created_at > now()-interval '24 hours'),
 'created_24h_confirmed', (select count(*) from auth.users where created_at > now()-interval '24 hours' and email_confirmed_at is not null),
 'unconfirmed_total', (select count(*) from auth.users where email_confirmed_at is null),
 'signin_24h', (select count(*) from auth.users where last_sign_in_at > now()-interval '24 hours'),
 'signin_3h', (select count(*) from auth.users where last_sign_in_at > now()-interval '3 hours'),
 'recovery_sent_24h', (select count(*) from auth.users where recovery_sent_at > now()-interval '24 hours'),
 'confirmation_sent_24h', (select count(*) from auth.users where confirmation_sent_at > now()-interval '24 hours'),
 'banned', (select count(*) from auth.users where banned_until > now()),
 'deleted_flag', (select count(*) from auth.users where deleted_at is not null),
 'sessions_3h', (select count(*) from auth.sessions where created_at > now()-interval '3 hours'),
 'refresh_3h', (select count(*) from auth.refresh_tokens where created_at > now()-interval '3 hours'),
 'accounts', (select count(*) from public.hdm_accounts),
 'users_without_account', (select count(*) from auth.users u where not exists (select 1 from public.hdm_accounts a where a.auth_user_id = u.id)),
 'profiles', (select count(*) from public.docs where collection='profiles'),
 'consents', (select count(*) from public.hdm_consents),
 'required_terms', (select public.hdm_required_terms_version()),
 'audit_24h', (select coalesce(json_object_agg(a, n), '{}') from (select payload->>'action' a, count(*) n from auth.audit_log_entries where created_at > now()-interval '24 hours' group by 1) x),
 'markers_today', (select coalesce(json_agg(version order by installed_at), '[]') from public.hdm_release_marker where installed_at > now()-interval '30 hours'),
 'auth_triggers', (select coalesce(json_agg(tgname), '[]') from pg_trigger where tgrelid = 'auth.users'::regclass and not tgisinternal)
) r"
ann notice "i-db" "$(roq "$DBQ" | jq -c '.[0].r // .' | clean | cut -c1-1800)"
# 4. לוגים (6 שעות)
lq(){ curl -sS -m 60 -G -H "Authorization: Bearer $TOK" "$A/analytics/endpoints/logs.all" --data-urlencode "sql=$1" --data-urlencode "iso_timestamp_start=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ)" --data-urlencode "iso_timestamp_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
L1=$(lq "select count(*) n, metadata.level lvl, metadata.status st, metadata.path p, metadata.msg m, metadata.error e from auth_logs cross join unnest(metadata) as metadata group by lvl, st, p, m, e order by n desc limit 25")
ann notice "i-logs-auth" "$(echo "$L1" | jq -c '.result // .error // .' 2>/dev/null | clean | cut -c1-1900)"
L2=$(lq "select count(*) n, parsed.error_severity sev, event_message m from postgres_logs cross join unnest(metadata) as md cross join unnest(md.parsed) as parsed where parsed.error_severity in ('ERROR','FATAL','PANIC') group by sev, m order by n desc limit 15")
ann notice "i-logs-pg" "$(echo "$L2" | jq -c '.result // .error // .' 2>/dev/null | clean | cut -c1-1900)"
L3=$(lq "select count(*) n, r.status_code st, req.method me, req.path p from edge_logs cross join unnest(metadata) as m cross join unnest(m.response) as r cross join unnest(m.request) as req where r.status_code >= 400 group by st, me, p order by n desc limit 20")
ann notice "i-logs-edge" "$(echo "$L3" | jq -c '.result // .error // .' 2>/dev/null | clean | cut -c1-1900)"
# 5. משתמש בדיקה בתיבת האפליקציה (+כינוי): הרשמה, כניסה לפני אישור, איפוס סיסמה. לא נמחק (לבקשת הבעלים — בלי מחיקות).
T="${GITHUB_RUN_ID:-x}"; EM="life.through.numbers333+inc$T@gmail.com"; PW="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PW"
SITE='https://shmulikhavivi-design.github.io/haim-derech-misparim/'
R1=$(curl -sS -m 40 -o /tmp/su.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/signup?redirect_to=$(jq -rn --arg s "$SITE" '$s|@uri')" -d "$(jq -nc --arg e "$EM" --arg p "$PW" '{email:$e,password:$p,data:{name:"בדיקת תקלה"}}')" || echo 000)
SU=$(jq -c '{has_user: (.id != null or .user.id != null), confirmed: ((.email_confirmed_at // .user.email_confirmed_at) != null), session: (.access_token != null), code: (.code // .error_code), msg: (.msg // .message // .error_description)}' /tmp/su.json 2>/dev/null | clean)
R2=$(curl -sS -m 40 -o /tmp/li.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/token?grant_type=password" -d "$(jq -nc --arg e "$EM" --arg p "$PW" '{email:$e,password:$p}')" || echo 000)
LI=$(jq -c '{session: (.access_token != null), code: (.error_code // .code), msg: (.msg // .error_description // .message)}' /tmp/li.json 2>/dev/null | clean)
R3=$(curl -sS -m 40 -o /tmp/li2.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/token?grant_type=password" -d '{"email":"no-such-user-hdm@example.invalid","password":"Wrong-pass-123!"}' || echo 000)
LI2=$(jq -c '{code: (.error_code // .code), msg: (.msg // .error_description // .message)}' /tmp/li2.json 2>/dev/null | clean)
sleep 3
R4=$(curl -sS -m 40 -o /tmp/rc.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/recover?redirect_to=$(jq -rn --arg s "$SITE" '$s|@uri')" -d "$(jq -nc --arg e "$EM" '{email:$e}')" || echo 000)
RC=$(jq -c '{code: (.error_code // .code), msg: (.msg // .message)}' /tmp/rc.json 2>/dev/null | clean)
sleep 4
TU=$(roq "select json_build_object('exists', count(*), 'confirmation_sent', bool_or(confirmation_sent_at is not null), 'recovery_sent', bool_or(recovery_sent_at is not null), 'account', (select count(*) from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where u.email='$EM')) r from auth.users where email = '$EM'" | jq -c '.[0].r // .')
ann notice "i-test" "משתמש בדיקה (תיבת האפליקציה +inc$T): הרשמה HTTP $R1 $SU | כניסה לפני אישור HTTP $R2 $LI | כניסה עם משתמש לא קיים HTTP $R3 $LI2 | איפוס סיסמה HTTP $R4 $RC | במסד: $TU"
ann notice "prod-result" "incident הסתיים — קריאה בלבד + משתמש בדיקה אחד; לא נמחק ולא שונה כלום אחר"
