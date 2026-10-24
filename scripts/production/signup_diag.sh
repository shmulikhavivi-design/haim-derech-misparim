#!/usr/bin/env bash
# signupdiag — קריאה בלבד: לקוחה שלא קיבלה מייל אישור הרשמה. בלי שינוי, בלי שליחת מייל, בלי אישור משתמש.
# הריפו ציבורי: שם, כתובת מייל ומזהה מלא לא מודפסים. ההתאמה לשם נעשית לפי md5 של מילים בלבד.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
scrub(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/<IP>/g; s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uuid>/g'; }
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
FN="'0d7760623b21f1ef2983c13bd1e32d44','c2299ce780cedb670a127bc1fe68ff3f','dd0780f10d9b30ab04f9cb9dc89ae1f1'"
LN="'4132d456adc95b0b9a79f28aef874d6b','ade8702ec193b1df50b931cb44d1d129','e365d9bac36802a27a6131ee502f42bf','98f6a2c4222e6292a3c8c2750f0a3d6a'"
# 1. החשבון ב-Production — חיפוש לפי שם (במטא-דאטה, בפרופיל ובחלק המקומי של המייל), כולל משתמשים שנמחקו/נחסמו
Q="with t as (
 select u.id, u.email, u.created_at, u.email_confirmed_at, u.confirmation_sent_at, u.last_sign_in_at, u.banned_until, u.deleted_at,
  (select count(*) from auth.identities i where i.user_id=u.id) idn,
  exists(select 1 from public.hdm_accounts a where a.auth_user_id=u.id) acct,
  coalesce(u.raw_user_meta_data::text,'') || ' ' || coalesce((select string_agg(d.data::text,' ') from public.hdm_accounts a join public.docs d on d.collection='profiles' and d.id=a.profile_id where a.auth_user_id=u.id),'') txt
 from auth.users u),
s as (select t.*,
 exists(select 1 from regexp_split_to_table(lower(txt),'[^a-z0-9א-ת]+') w where md5(w) in ($FN)) fn_meta,
 exists(select 1 from regexp_split_to_table(lower(txt),'[^a-z0-9א-ת]+') w where md5(w) in ($LN)) ln_meta,
 exists(select 1 from regexp_split_to_table(lower(split_part(email,'@',1)),'[^a-z]+') w where md5(w) in ($FN) or md5(w) in ($LN) ) em_tok
 from t)
select json_build_object(
 'candidates',(select coalesce(json_agg(json_build_object('email',email,'id',id,'score',(fn_meta::int+ln_meta::int)*2+em_tok::int,'fn',fn_meta,'ln',ln_meta,'email_token',em_tok,
   'created_il',to_char(created_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI'),
   'confirmed',email_confirmed_at is not null,
   'confirmation_sent_il',to_char(confirmation_sent_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI'),
   'last_sign_in_il',to_char(last_sign_in_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI'),
   'banned',banned_until is not null and banned_until>now(),'deleted',deleted_at is not null,'identities',idn,'hdm_account',acct,
   'domain',split_part(email,'@',2)) order by created_at desc),'[]') from s where fn_meta or ln_meta or em_tok),
 'recent_7d',(select coalesce(json_agg(json_build_object('created_il',to_char(created_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI'),'confirmed',email_confirmed_at is not null,'sent',confirmation_sent_at is not null,'domain',split_part(email,'@',2)) order by created_at desc),'[]') from auth.users where created_at>now()-interval '7 days' and email not like 'life.through.numbers333+%' and email not like '%example.invalid'),
 'conf_sent_24h',(select count(*) from auth.users where confirmation_sent_at>now()-interval '24 hours'),
 'conf_sent_1h',(select count(*) from auth.users where confirmation_sent_at>now()-interval '1 hour'),
 'last_confirmed_il',(select to_char(max(email_confirmed_at) at time zone 'Asia/Jerusalem','DD.MM HH24:MI') from auth.users where email not like 'life.through.numbers333+%' and email not like '%example.invalid')
) r"
R=$(roq "$Q" | jq -c 'if type=="array" then .[0].r else . end')
EMAILS=$(echo "$R" | jq -r '.candidates[]?.email // empty'); for e in $EMAILS; do echo "::add-mask::$e"; done
IDS=$(echo "$R" | jq -r '.candidates[]?.id // empty')
ann notice "sd-1-account" "1. Production — מועמדות לפי שם (בלי שם/מייל/מזהה): $(echo "$R" | jq -c '[.candidates[]? | del(.email,.id)]' | cut -c1-1400)"
ann notice "sd-1-recent" "הרשמות 7 ימים אחרונים (בלי משתמשי בדיקה): $(echo "$R" | jq -c '{recent_7d, conf_sent_24h, conf_sent_1h, last_confirmed_il}' | cut -c1-1600)"

# 2+3. יומני Auth של Supabase (שגיאות + אירועי מייל) — למועמדות ובכלל
ST=$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ); EN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
lg(){ curl -sS -m 60 -o /tmp/lg.json -w '%{http_code}' -G -H "Authorization: Bearer $TOK" "$A/analytics/endpoints/logs.all" --data-urlencode "iso_timestamp_start=$1" --data-urlencode "iso_timestamp_end=$EN" --data-urlencode "sql=$2" || echo 000; }
SQLE="select timestamp, event_message from auth_logs where regexp_contains(lower(event_message), 'error|fail|smtp|mail|rate|limit|confirm|signup|\"status\":4|\"status\":5') order by timestamp desc limit 100"
C=$(lg "$ST" "$SQLE"); [ "$C" = 200 ] || { ST=$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ); C=$(lg "$ST" "$SQLE"); }
cp /tmp/lg.json /tmp/lg_all.json 2>/dev/null
ann notice "sd-2-logs-http" "יומני Auth: HTTP $C (מ-$ST) $( [ "$C" = 200 ] || jq -r '.message // .error // empty' /tmp/lg.json 2>/dev/null | scrub | cut -c1-200)"
if [ "$C" = 200 ]; then
  ERR=$(jq -r '(.result // [])[] | .event_message' /tmp/lg_all.json | python3 -I -c '
import sys,json,collections
c=collections.Counter(); ex={}
for line in sys.stdin:
    try: m=json.loads(line)
    except Exception: m={"msg":line.strip()}
    lvl=str(m.get("level","")); st=str(m.get("status","")); msg=str(m.get("msg") or m.get("error") or "")[:110]; path=str(m.get("path",""))
    if lvl in ("error","warning") or st[:1] in ("4","5") or "mail" in msg.lower() or "smtp" in msg.lower():
        er=str(m.get("error",""))[:110]; k="|".join([lvl,st,path,er,msg]); c[k]+=1; ex.setdefault(k,str(m.get("time") or m.get("timestamp") or ""))
print(json.dumps([{"n":n,"last":ex[k][:16],"what":k} for k,n in c.most_common(25)],ensure_ascii=False))' | scrub)
  ann notice "sd-2-logs-errors" "שגיאות/אזהרות/מייל ביומן Auth (מקובץ): $(echo "$ERR" | cut -c1-2500)"
  for u in $IDS; do
    C2=$(lg "$ST" "select timestamp, event_message from auth_logs where regexp_contains(event_message, '$u') order by timestamp desc limit 50")
    ann notice "sd-2-logs-user-${u:0:4}" "יומן Auth למועמדת ${u:0:4}…: HTTP $C2 $(jq -c '[(.result // [])[] | .event_message | (try fromjson catch {msg:.}) | {t:(.time // "")[0:19], lvl:.level, st:.status, path, action:(.action // .auth_event.action // null), msg:((.msg // "")|.[0:100]), err:((.error // "")|tostring|.[0:140])}]' /tmp/lg.json 2>/dev/null | scrub | cut -c1-2200)"
  done
fi

# הגדרות Auth (אם לטוקן יש הרשאה)
AC=$(curl -sS -m 30 -o /tmp/ac.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$A/config/auth" || echo 000)
ann notice "sd-auth-config" "הגדרות Auth: HTTP $AC $( [ "$AC" = 200 ] && jq -c '{confirm_email_on:(.mailer_autoconfirm==false), smtp_host, smtp_port, smtp_user_set:((.smtp_user//"")!=""), smtp_pass_set:((.smtp_pass//"")!=""), sender_domain:((.smtp_admin_email//"")|split("@")[1]), rate_limit_email_sent, mailer_otp_exp, site_url}' /tmp/ac.json )"

# 4. Brevo — אירועים למועמדות + חסימות + מצב כללי
K=$(printf '%s' "${GH_BREVO_API:-}" | tr -d '[:space:]"'"'")
if [ -n "$K" ]; then
  bv(){ curl -sS -m 40 -G -H "api-key: $K" -H 'accept: application/json' "https://api.brevo.com/v3/$1" "${@:2}"; }
  i=0
  for e in $EMAILS; do i=$((i+1))
    EV=$(bv smtp/statistics/events --data-urlencode "email=$e" --data-urlencode "days=30" --data-urlencode "limit=100" --data-urlencode "sort=desc" | jq -c '[.events[]? | {at:(.date|.[0:16]), ev:.event, subj:((.subject//"")|.[0:40]), reason:((.reason//"")|.[0:160])}]')
    EM=$(bv smtp/emails --data-urlencode "email=$e" --data-urlencode "limit=20" --data-urlencode "sort=desc" | jq -c '{count, msgs:[.transactionalEmails[]? | {at:(.date|.[0:16]), subj:((.subject//"")|.[0:40])}]}')
    BL=$(bv smtp/blockedContacts --data-urlencode "senders=life.through.numbers333@gmail.com" --data-urlencode "limit=100" | jq -c --arg e "$(printf '%s' "$e" | tr 'A-Z' 'a-z')" '[.contacts[]? | select((.email|ascii_downcase)==$e) | {reason:.reason, at:(.blockedAt|.[0:16])}]')
    BL2=$(bv smtp/blockedContacts --data-urlencode "limit=100" | jq -c --arg e "$(printf '%s' "$e" | tr 'A-Z' 'a-z')" '[.contacts[]? | select((.email|ascii_downcase)==$e) | {reason:.reason, at:(.blockedAt|.[0:16]), sender:(.senderEmail|split("@")[1])}]')
    ann notice "sd-4-brevo-cand$i" "Brevo למועמדת $i — אירועים: $(echo "$EV" | scrub | cut -c1-1400) | מיילים שנרשמו: $(echo "$EM" | scrub | cut -c1-500) | ברשימת חסומים: ${BL2:-?}"
  done
  AG=$(bv smtp/statistics/aggregatedReport --data-urlencode "days=3" | jq -c '{requests,delivered,hardBounces,softBounces,blocked,invalid,spamReports,deferred:(.deferred//null)}')
  CF=$(bv smtp/statistics/events --data-urlencode "days=3" --data-urlencode "limit=300" --data-urlencode "sort=desc" | jq -c '[.events[]? | select((.email|test("example\\.invalid|^life\\.through\\.numbers333\\+"))|not)] | {by_event:(group_by(.event)|map({(.[0].event):length})|add), problems:[.[] | select(.event|test("ounce|locked|pam|nvalid|eferred|error";"i")) | {at:(.date|.[0:16]), ev:.event, subj:((.subject//"")|.[0:30]), domain:(.email|split("@")[1]), reason:((.reason//"")|.[0:140])}][0:15]}' | scrub)
  ACC=$(bv account | jq -c '{plan:[.plan[]? | {type, credits, creditsType}], relay_enabled:(.relay.enabled // null)}')
  ann notice "sd-4-brevo-general" "Brevo כללי (3 ימים): $AG | אירועים: $(echo "$CF" | cut -c1-1500) | חשבון: $ACC"
else
  ann warning "sd-4-brevo" "BREVO_API_KEY לא זמין לתהליך"
fi
rm -f /tmp/lg.json /tmp/lg_all.json /tmp/ac.json
ann notice "prod-result" "signupdiag — קריאה בלבד. לא שונה כלום, לא נשלח מייל, לא אושר משתמש."

# 5. Brevo לפי דומיין נמען (30 יום) + האם ההחזרות שייכות לשם הלקוחה (התאמת md5 בלבד, בלי להדפיס כתובות)
if [ -n "$K" ]; then
  curl -sS -m 60 -G -H "api-key: $K" -H 'accept: application/json' "https://api.brevo.com/v3/smtp/statistics/events" --data-urlencode "days=30" --data-urlencode "limit=2500" --data-urlencode "sort=desc" > /tmp/ev30.json
  OUT=$(python3 -I - /tmp/ev30.json <<'PY'
import json,sys,hashlib,re,collections
d=json.load(open(sys.argv[1])); ev=d.get("events") or []
FN={'0d7760623b21f1ef2983c13bd1e32d44','c2299ce780cedb670a127bc1fe68ff3f','dd0780f10d9b30ab04f9cb9dc89ae1f1'}
LN={'4132d456adc95b0b9a79f28aef874d6b','ade8702ec193b1df50b931cb44d1d129','e365d9bac36802a27a6131ee502f42bf','98f6a2c4222e6292a3c8c2750f0a3d6a'}
def toks(e):
    lp=e.split('@')[0].lower(); ws=set(re.split(r'[^a-z]+',lp)); ws|={lp[i:j] for i in range(len(lp)) for j in range(i+4,min(len(lp),i+9)+1)}
    return {hashlib.md5(w.encode()).hexdigest() for w in ws if w}
ev=[e for e in ev if not re.search(r'example\.invalid|^life\.through\.numbers333\+',e.get('email',''))]
dom=collections.defaultdict(lambda: collections.Counter())
for e in ev: dom[e['email'].split('@')[-1].lower()][e['event']]+=1
rcpt=collections.defaultdict(list)
for e in ev: rcpt[e['email'].lower()].append(e)
cands=[]
for i,(em,es) in enumerate(rcpt.items()):
    t=toks(em); s=(2 if t&FN else 0)+(2 if t&LN else 0)
    bounced=[x for x in es if 'ounce' in x['event'] or 'locked' in x['event']]
    if s or (bounced and 'walla' in em):
        cands.append({'r':f'#{i}','name_match':s,'domain':em.split('@')[-1],
          'events':sorted([(x['date'][:16],x['event'],(x.get('subject') or '')[:28],(x.get('reason') or '')[:60]) for x in es])})
print(json.dumps({'events_30d':len(ev),'by_domain':{k:dict(v) for k,v in sorted(dom.items(),key=lambda kv:-sum(kv[1].values()))[:12]},
 'tz_sample':(ev[0]['date'] if ev else None),'walla_or_name_recipients':cands},ensure_ascii=False))
PY
)
  ann notice "sd-5-brevo-domains" "$(echo "$OUT" | scrub | cut -c1-3800)"
  rm -f /tmp/ev30.json
fi
