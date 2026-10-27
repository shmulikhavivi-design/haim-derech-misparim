#!/usr/bin/env bash
# signupdiagtwo — READ-ONLY (27.10): a Gmail customer who registered and got no confirmation email.
# No setting changed, no email sent, no user touched. Public repo: no name, email, id or IP is printed;
# the name is matched only by md5 of name tokens. Uses only GET calls and the read-only SQL endpoint.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
scrub(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/<IP>/g; s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uuid>/g'; }
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export HASH_FN='3490c9841bb8ed00d4993e67162f4cc5 cde2b3ee42ef3680379b6aec1e1e6a53 0174a3ca65ea88796562c3a6dc58b03c'
export HASH_LN='a63c7fb7a3f3e377e35feb908283495f a50e215daa23bb0bf3034e189f2f5b8f aeb92d920e84542aca98ee7631ba6df7 7408e25668fd4eae8b418d2f1ad4c829 c7d43086dd6bbf5fe593cb6c640af99e 63d5e54452e8b6b9ed854dd5dbbf7ae2 c16cc864ddc51d8d2a71fc8ad4eb6709 8c4dbea6094d640fa0f659704c084b79 d460337d475e9496123cbd3230069fa0 aac0db813eaae96839cab085fd5b220e f4f48ba7e9c189c8a48ebdaa1e345fcd 64e535114c0d17eac8795f730d0f1320'

# ---------- 1+2. auth.users (read-only SQL) ----------
Q="select coalesce(json_agg(json_build_object('id',u.id,'email',u.email,
 'created',u.created_at,'confirmed',u.email_confirmed_at,'sent',u.confirmation_sent_at,'last_in',u.last_sign_in_at,
 'banned',(u.banned_until is not null and u.banned_until>now()),'deleted',u.deleted_at is not null,
 'providers',(select coalesce(json_agg(i.provider),'[]') from auth.identities i where i.user_id=u.id),
 'acct',exists(select 1 from public.hdm_accounts a where a.auth_user_id=u.id),
 'txt',coalesce(u.raw_user_meta_data::text,'')||' '||coalesce((select string_agg(d.data::text,' ') from public.hdm_accounts a join public.docs d on d.collection='profiles' and d.id=a.profile_id where a.auth_user_id=u.id),'')
)),'[]') r from auth.users u"
roq "$Q" | jq -c 'if type=="array" then .[0].r else . end' > "$W/users.json"
for e in $(jq -r '.[]?.email // empty' "$W/users.json" 2>/dev/null); do echo "::add-mask::$e"; done
python3 -I - "$W/users.json" "$W/cand.json" > "$W/u_out.txt" <<'PY'
import json,sys,os,hashlib,re
from datetime import datetime,timezone,timedelta
FN=set(os.environ['HASH_FN'].split()); LN=set(os.environ['HASH_LN'].split())
try: U=json.load(open(sys.argv[1]))
except Exception as e: print(json.dumps({"error":"users query failed "+str(e)[:80]})); json.dump([],open(sys.argv[2],'w')); sys.exit()
if not isinstance(U,list): print(json.dumps({"error":str(U)[:200]})); json.dump([],open(sys.argv[2],'w')); sys.exit()
h=lambda w: hashlib.md5(w.encode()).hexdigest()
def toks(s): return {w for w in re.split(r'[^a-z0-9א-ת]+',(s or '').lower()) if w}
def subs(lp):
    lp=re.sub(r'[^a-z]','',lp.lower()); return {lp[i:j] for i in range(len(lp)) for j in range(i+4,min(len(lp),i+14)+1)}
IL=timezone(timedelta(hours=2))
def t(x):
    if not x: return None
    try: return datetime.fromisoformat(x.replace('Z','+00:00')).astimezone(IL).strftime('%d.%m %H:%M')
    except Exception: return str(x)[:16]
now=datetime.now(timezone.utc)
cands=[]
for u in U:
    mt={h(w) for w in toks(u.get('txt'))}; lp=(u.get('email') or '').split('@')[0]
    et={h(w) for w in toks(lp)|subs(lp)}
    fn=bool((mt|et)&FN); ln=bool((mt|et)&LN)
    if fn and ln or ln:
        cands.append({'id':u['id'],'email':u['email'],'match':('first+last' if fn and ln else 'last'),'domain':(u['email'] or '').split('@')[-1],
          'created':t(u['created']),'confirmation_sent':t(u['sent']),'confirmed':t(u['confirmed']),'last_sign_in':t(u['last_in']),
          'providers':u['providers'],'hdm_account':u['acct'],'banned':u['banned'],'deleted':u['deleted']})
json.dump([{'id':c['id'],'email':c['email']} for c in cands],open(sys.argv[2],'w'))
def rec(days):
    r=[u for u in U if u.get('created') and datetime.fromisoformat(u['created'].replace('Z','+00:00'))>now-timedelta(days=days)
       and not re.search(r'example\.invalid|^life\.through\.numbers333\+',u.get('email') or '')]
    return r
r3=rec(3)
gen={'total_users':len(U),'signups_3d':len(r3),
 'signups_3d_detail':[{'created':t(u['created']),'domain':(u['email'] or '').split('@')[-1],'sent':bool(u['sent']),'confirmed':bool(u['confirmed']),'prov':u['providers']} for u in sorted(r3,key=lambda u:u['created'],reverse=True)][:20],
 'last_confirmation_sent':t(max([u['sent'] for u in U if u.get('sent')] or [None]) ) if any(u.get('sent') for u in U) else None,
 'last_confirmed':t(max([u['confirmed'] for u in U if u.get('confirmed')] or [None])) if any(u.get('confirmed') for u in U) else None}
print(json.dumps({'candidates':[{k:v for k,v in c.items() if k not in('id','email')} for c in cands],'general':gen},ensure_ascii=False))
PY
UO=$(cat "$W/u_out.txt")
ann notice "s2-1-user" "1-2. Production auth.users — מועמדות לפי שם (בלי שם/מייל): $(echo "$UO" | jq -c '.candidates // .error' | scrub | cut -c1-1500)"
ann notice "s2-5-general" "5. הרשמות 3 ימים אחרונים (בלי משתמשי בדיקה): $(echo "$UO" | jq -c '.general' | scrub | cut -c1-2500)"

# ---------- 3. Auth logs (analytics, read) ----------
EN=$(date -u +%Y-%m-%dT%H:%M:%SZ); ST=$(date -u -d '-72 hours' +%Y-%m-%dT%H:%M:%SZ)
lg(){ curl -sS -m 60 -o "$W/$1" -w '%{http_code}' -G -H "Authorization: Bearer $TOK" "$A/analytics/endpoints/logs.all" --data-urlencode "iso_timestamp_start=$ST" --data-urlencode "iso_timestamp_end=$EN" --data-urlencode "sql=$2" || echo 000; }
C=$(lg lg.json "select timestamp, event_message from auth_logs order by timestamp desc limit 1000")
[ "$C" = 200 ] || { ST=$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ); C=$(lg lg.json "select timestamp, event_message from auth_logs order by timestamp desc limit 1000"); }
if [ "$C" = 200 ]; then
  LO=$(python3 -I - "$W/lg.json" "$W/cand.json" <<'PY'
import json,sys,os,re,hashlib,collections
FN=set(os.environ['HASH_FN'].split()); LN=set(os.environ['HASH_LN'].split())
d=json.load(open(sys.argv[1])); rows=d.get('result') or []
C=json.load(open(sys.argv[2])); ids={c['id'] for c in C}; ems={(c['email'] or '').lower() for c in C}
h=lambda w: hashlib.md5(w.encode()).hexdigest()
def namehit(s):
    for em in re.findall(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+',s or ''):
        lp=re.sub(r'[^a-z]','',em.split('@')[0].lower()); S={lp[i:j] for i in range(len(lp)) for j in range(i+4,min(len(lp),i+14)+1)}
        if {h(x) for x in S}&LN: return True
    return False
grp=collections.Counter(); last={}; mine=[]; mail=collections.Counter()
for r in rows:
    raw=r.get('event_message') or ''
    try: m=json.loads(raw)
    except Exception: m={'msg':raw}
    lvl=str(m.get('level','')); st=str(m.get('status','')); path=str(m.get('path','')); msg=str(m.get('msg') or '')[:120]; err=str(m.get('error') or '')[:160]
    act=str(m.get('action') or (m.get('auth_event') or {}).get('action') or '')
    ts=str(m.get('time') or r.get('timestamp') or '')[:19]
    low=(msg+' '+err+' '+act).lower()
    if any(k in low for k in ('mail','smtp','confirm')) or path in ('/signup','/resend','/otp','/verify'): mail['|'.join([path,act,st,lvl,msg[:60]])]+=1
    if lvl in ('error','warning','fatal') or st[:1] in ('4','5'):
        k='|'.join([lvl,st,path,err,msg]); grp[k]+=1; last.setdefault(k,ts)
    if any(i in raw for i in ids) or any(e and e in raw.lower() for e in ems) or namehit(raw):
        mine.append({'t':ts,'lvl':lvl,'st':st,'path':path,'action':act,'msg':msg,'err':err})
print(json.dumps({'rows':len(rows),'errors':[{'n':n,'last':last[k],'what':k} for k,n in grp.most_common(20)],
 'mail_related':[{'n':n,'what':k} for k,n in mail.most_common(15)],'customer_events':mine[:40]},ensure_ascii=False))
PY
)
  ann notice "s2-3-logs-customer" "3. יומן Auth (72 שעות, HTTP $C) — אירועים של הלקוחה: $(echo "$LO" | jq -c '.customer_events' | scrub | cut -c1-2600)"
  ann notice "s2-3-logs-errors" "3. יומן Auth — שגיאות/אזהרות (מקובץ, $(echo "$LO" | jq -r .rows) שורות): $(echo "$LO" | jq -c '.errors' | scrub | cut -c1-2600)"
  ann notice "s2-3-logs-mail" "3. יומן Auth — אירועי הרשמה/מייל: $(echo "$LO" | jq -c '.mail_related' | scrub | cut -c1-2000)"
else
  ann warning "s2-3-logs" "3. יומני Auth לא נקראו: HTTP $C $(jq -r '.message // .error // empty' "$W/lg.json" 2>/dev/null | scrub | cut -c1-200)"
fi

# ---------- Auth config (GET only) ----------
AC=$(curl -sS -m 30 -o "$W/ac.json" -w '%{http_code}' -H "Authorization: Bearer $TOK" "$A/config/auth" || echo 000)
ann notice "s2-cfg" "הגדרות Auth (קריאה): HTTP $AC $( [ "$AC" = 200 ] && jq -c '{confirm_email_on:(.mailer_autoconfirm==false), smtp_host, smtp_port, sender:(.smtp_admin_email//""), sender_name:.smtp_sender_name, smtp_pass_set:((.smtp_pass//"")!=""), rate_limit_email_sent, mailer_otp_exp, site_url, google_login:.external_google_enabled}' "$W/ac.json" | scrub )"

# ---------- 4. Resend (GET only: list sent emails + status) ----------
RK=$(printf '%s' "${GH_RESEND_KEY:-}" | tr -d '[:space:]"'"'"); [ -n "$RK" ] && echo "::add-mask::$RK"
if [ -n "$RK" ]; then
  RC=$(curl -sS -m 40 -o "$W/rs.json" -w '%{http_code}' -H "Authorization: Bearer $RK" "https://api.resend.com/emails?limit=100" || echo 000)
  if [ "$RC" = 200 ]; then
    for p in 2 3 4 5; do
      AFT=$(jq -r 'if .has_more then (.data|last|.id) else empty end' "$W/rs.json" 2>/dev/null | tail -1); [ -n "$AFT" ] || break
      curl -sS -m 40 -o "$W/rs$p.json" -H "Authorization: Bearer $RK" "https://api.resend.com/emails?limit=100&after=$AFT"
      jq -s '{data:(.[0].data+.[1].data), has_more:.[1].has_more}' "$W/rs.json" "$W/rs$p.json" > "$W/m.json" && mv "$W/m.json" "$W/rs.json"
    done
    RO2=$(python3 -I - "$W/rs.json" "$W/cand.json" <<'PY'
import json,sys,os,re,hashlib,collections
from datetime import datetime,timezone,timedelta
LN=set(os.environ['HASH_LN'].split()); h=lambda w: hashlib.md5(w.encode()).hexdigest()
d=json.load(open(sys.argv[1])).get('data') or []; C=json.load(open(sys.argv[2])); ems={(c['email'] or '').lower() for c in C}
IL=timezone(timedelta(hours=2))
def t(x):
    try: return datetime.fromisoformat(str(x).replace(' ','T').replace('Z','+00:00')[:32]).astimezone(IL).strftime('%d.%m %H:%M')
    except Exception: return str(x)[:16]
def hit(em):
    em=em.lower()
    if em in ems: return True
    lp=re.sub(r'[^a-z]','',em.split('@')[0]); return bool({h(lp[i:j]) for i in range(len(lp)) for j in range(i+4,min(len(lp),i+14)+1)}&LN)
mine=[]; byev=collections.Counter(); prob=[]; dom=collections.defaultdict(collections.Counter)
for e in d:
    to=[x for x in (e.get('to') or [])]; ev=e.get('last_event') or '?'
    for x in to: dom[x.split('@')[-1].lower()][ev]+=1
    byev[ev]+=1
    if any(hit(x) for x in to): mine.append({'at':t(e.get('created_at')),'status':ev,'subject':(e.get('subject') or '')[:40],'to_domain':to[0].split('@')[-1] if to else '','id4':(e.get('id') or '')[:8]})
    if ev not in ('delivered','opened','clicked','sent'): prob.append({'at':t(e.get('created_at')),'status':ev,'to_domain':to[0].split('@')[-1] if to else '','subject':(e.get('subject') or '')[:30]})
print(json.dumps({'emails_listed':len(d),'oldest':t(d[-1]['created_at']) if d else None,'by_status':dict(byev),'customer':mine,
 'problems':prob[:15],'by_domain':{k:dict(v) for k,v in sorted(dom.items(),key=lambda kv:-sum(kv[1].values()))[:8]}},ensure_ascii=False))
PY
)
    ann notice "s2-4-resend-customer" "4. Resend — מיילים ללקוחה: $(echo "$RO2" | jq -c '{customer, emails_listed, oldest}' | scrub | cut -c1-1500)"
    ann notice "s2-4-resend-general" "4/5. Resend — מצב כללי: $(echo "$RO2" | jq -c '{by_status, by_domain, problems}' | scrub | cut -c1-2500)"
  else
    ann warning "s2-4-resend" "4. Resend: רשימת המיילים לא נקראה — HTTP $RC $(jq -c '{name,message}' "$W/rs.json" 2>/dev/null | scrub | cut -c1-250)"
  fi
  # Resend domain status (GET only)
  DC=$(curl -sS -m 30 -o "$W/rd.json" -w '%{http_code}' -H "Authorization: Bearer $RK" "https://api.resend.com/domains" || echo 000)
  ann notice "s2-4-resend-domain" "Resend דומיינים: HTTP $DC $( [ "$DC" = 200 ] && jq -c '[.data[]? | {name,status,region}]' "$W/rd.json")"
else
  ann warning "s2-4-resend" "4. מפתח Resend של Production לא זמין לתהליך"
fi
ann notice "prod-result" "signupdiagtwo — קריאה בלבד. לא שונתה הגדרה, לא נשלח מייל, לא נגעו בשום משתמש."
