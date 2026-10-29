#!/usr/bin/env bash
# =====================================================================
# בדיקה מקומית בלבד של 24_production_oren_free_plus.sql (Plus בחינם לאורן גורגני).
# מסד זמני שמדמה את Production (01 + 07 + 08), נתונים מומצאים, לא מתחבר ל-Supabase. נמחק בסוף.
# =====================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"; PORT="${PGPORT_LOCAL:-54393}"
RUNAS=(); [ "$(id -u)" = 0 ] && { chown -R postgres "$WORK"; RUNAS=(su postgres -c); }
run(){ if [ ${#RUNAS[@]} -gt 0 ]; then "${RUNAS[@]}" "$*"; else bash -c "$*"; fi; }
run "$PGBIN/initdb -D $WORK/data -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null"
run "$PGBIN/pg_ctl -D $WORK/data -o '-p $PORT -k $WORK -c listen_addresses=' -l $WORK/pg.log -w start >/dev/null"
trap 'run "$PGBIN/pg_ctl -D $WORK/data -m immediate stop >/dev/null" || true; rm -rf "$WORK"' EXIT
P=(psql -h "$WORK" -p "$PORT" -U postgres -X -v ON_ERROR_STOP=1 -q -P pager=off)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "✅ $1"; }
bad(){ FAIL=$((FAIL+1)); echo "❌ $1 — $2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "צפוי [$2], התקבל [$3]"; fi; }
q(){ "${P[@]}" -d "$1" -At -c "$2" 2>&1; }
F24="$ROOT/supabase/production/24_production_oren_free_plus.sql"
OREN_UID='85a99441-132f-497c-b9a3-d7ebf3343cda'

mkdb(){ # $1 = שם המסד
  "${P[@]}" -c "create database $1"
  "${P[@]}" -d "$1" -f "$HERE/local_supabase_mock.sql" >/dev/null 2>&1
  "${P[@]}" -d "$1" >/dev/null <<'SQL'
create table public.docs (collection text not null, id text not null, data jsonb not null default '{}'::jsonb, primary key (collection,id));
alter table public.docs enable row level security;
insert into public.docs values
 ('profiles','p_b2ae1de0a3df4e7e8a8f','{"currentName":"אורן גורגני","gender":"גבר"}'),
 ('profiles','payer1','{"currentName":"Payer Test"}'),
 ('profiles','gift1','{"currentName":"Gift Test"}'),
 ('profiles','free1','{"currentName":"Free Test"}');
SQL
  "${P[@]}" -d "$1" -f "$ROOT/supabase/age_gate.sql" >/dev/null 2>&1 || true
  for f in 01_production_migration 07_production_plus_no_extended 08_production_billing; do
    "${P[@]}" -d "$1" -f "$ROOT/supabase/production/$f.sql" >"$WORK/$1-$f.out" 2>&1 || { echo "בסיס $f נכשל:"; tail -5 "$WORK/$1-$f.out"; exit 1; }
  done
  "${P[@]}" -d "$1" >/dev/null <<SQL
insert into auth.users (id, email, email_confirmed_at, created_at) values
 ('$OREN_UID', 'oren13111976@gmail.com', now(), now()),
 ('00000000-0000-0000-0000-000000000001', 'payer@example.invalid', now(), now()),
 ('00000000-0000-0000-0000-000000000002', 'gift@example.invalid', now(), now()),
 ('00000000-0000-0000-0000-000000000003', 'free@example.invalid', now(), now());
insert into public.hdm_accounts (auth_user_id, profile_id) values
 ('$OREN_UID','p_b2ae1de0a3df4e7e8a8f'),
 ('00000000-0000-0000-0000-000000000001','payer1'),
 ('00000000-0000-0000-0000-000000000002','gift1'),
 ('00000000-0000-0000-0000-000000000003','free1');
-- לקוח משלם (Basic, מתחדש) + מתנה קיימת (Plus ידני)
insert into public.hdm_subscriptions (profile_id, plan, status, period_anchor, current_period_end, source, auto_renew, grow_direct_debit_id, last_payment_at)
 values ('payer1','basic','active', now() - interval '3 days', now() + interval '27 days', 'payment', true, 'dd-1', now() - interval '3 days'),
        ('gift1','plus','active', now(), null, 'manual', false, null, null);
insert into public.hdm_consents (user_id, profile_id, version, source)
 select '$OREN_UID', 'p_b2ae1de0a3df4e7e8a8f', public.hdm_required_terms_version(), 'signup';
SQL
}
snap(){ q "$1" "select md5(coalesce(string_agg(to_jsonb(s)::text, ',' order by profile_id), '')) from public.hdm_subscriptions s where profile_id <> 'p_b2ae1de0a3df4e7e8a8f'"; }
billing(){ q "$1" "select (select count(*) from public.hdm_payments)||'|'||(select count(*) from public.hdm_checkouts)||'|'||(select count(*) from public.hdm_billing_tokens)||'|'||(select count(*) from public.hdm_renewal_charges)||'|'||(select count(*) from public.hdm_grow_outbox)"; }
plans(){ q "$1" "select md5(string_agg(to_jsonb(p)::text, ',' order by plan)) from public.hdm_plans p"; }

# ---------- 1. הרצה רגילה ----------
mkdb t1
OTHERS=$(snap t1); BILL=$(billing t1); PLANS=$(plans t1)
check "לפני: אורן בחינם" "free" "$(q t1 "select public.hdm_plan_of('p_b2ae1de0a3df4e7e8a8f')")"
OUT=$("${P[@]}" -d t1 -At -F'|' -f "$F24" 2>&1) && ok "24 רץ בהצלחה" || bad "24 רץ" "$OUT"
check "אחרי: אורן ב-Plus" "plus" "$(q t1 "select public.hdm_plan_of('p_b2ae1de0a3df4e7e8a8f')")"
check "המנוי: active / manual / בלי תפוגה / בלי חידוש / בלי הוראת קבע" "active|manual|t|f|t" \
  "$(q t1 "select status||'|'||source||'|'||(current_period_end is null)::text::char||'|'||auto_renew::text::char||'|'||(grow_direct_debit_id is null)::text::char from public.hdm_subscriptions where profile_id='p_b2ae1de0a3df4e7e8a8f'")"
check "שורת האימות בסוף הקובץ" "plus|t|t|0" "$(echo "$OUT" | tail -1)"
check "אירוע אחד ביומן (start free→plus)" "1|start|free|plus" "$(q t1 "select count(*)||'|'||max(action)||'|'||max(from_plan)||'|'||max(to_plan) from public.hdm_subscription_events where profile_id='p_b2ae1de0a3df4e7e8a8f'")"
check "משתמשים אחרים ללא שינוי" "$OTHERS" "$(snap t1)"
check "תשלומים/ניסיונות/כרטיסים/חידושים/Grow ללא שינוי" "$BILL" "$(billing t1)"
check "טבלת המסלולים ללא שינוי" "$PLANS" "$(plans t1)"
check "אורן לא נכלל ברשימת החידושים בתשלום" "0" "$(q t1 "select count(*) from public.hdm_subscriptions s where s.profile_id='p_b2ae1de0a3df4e7e8a8f' and s.source = 'payment' and s.auto_renew and s.status in ('active','past_due')")"
ENT=$(q t1 "select public.hdm_my_entitlements()->>'plan'||'|'||(public.hdm_my_entitlements()->>'canTarget')||'|'||(public.hdm_my_entitlements()->>'canChat')||'|'||(public.hdm_my_entitlements()->>'ratingDetails')||'|'||(public.hdm_my_entitlements()->>'seeWhoTargeted')||'|'||coalesce(public.hdm_my_entitlements()->>'monthlyNewChats','∞')||'|'||coalesce(public.hdm_my_entitlements()->>'periodEnd','null') from (select set_config('request.jwt.claims', json_build_object('sub','$OREN_UID','role','authenticated')::text, false)) x")
check "הרשאות השרת לאורן = Plus מלא, ללא תפוגה" "plus|true|true|true|true|∞|null" "$ENT"
BS=$(q t1 "select (public.hdm_billing_status()->>'plan')||'|'||(public.hdm_billing_status()->>'autoRenew')||'|'||coalesce(public.hdm_billing_status()->>'nextChargeAt','null')||'|'||(public.hdm_billing_status()->>'canCancel') from (select set_config('request.jwt.claims', json_build_object('sub','$OREN_UID','role','authenticated')::text, false)) x")
check "מסך המנוי: Plus, בלי חידוש, בלי חיוב הבא, אין מה לבטל" "plus|false|null|false" "$BS"

# ---------- 2. הרצה חוזרת ----------
OUT=$("${P[@]}" -d t1 -f "$F24" 2>&1) || true
check "הרצה חוזרת: 'כבר קיים'" "1" "$(echo "$OUT" | grep -c 'כבר קיים')"
check "הרצה חוזרת: עדיין אירוע אחד" "1" "$(q t1 "select count(*) from public.hdm_subscription_events where profile_id='p_b2ae1de0a3df4e7e8a8f'")"

# ---------- 3. עצירות ----------
mkdb t2
q t2 "insert into public.hdm_subscriptions (profile_id, plan, status, current_period_end, source, auto_renew, grow_direct_debit_id) values ('p_b2ae1de0a3df4e7e8a8f','basic','active', now()+interval '20 days','payment', true, 'dd-9')" >/dev/null
B=$(q t2 "select md5(to_jsonb(s)::text) from public.hdm_subscriptions s where profile_id='p_b2ae1de0a3df4e7e8a8f'")
OUT=$("${P[@]}" -d t2 -f "$F24" 2>&1) || true
check "יש מנוי בתשלום → נעצר" "1" "$(echo "$OUT" | grep -c 'מנוי בתשלום')"
check "יש מנוי בתשלום → המנוי שלו לא השתנה" "$B" "$(q t2 "select md5(to_jsonb(s)::text) from public.hdm_subscriptions s where profile_id='p_b2ae1de0a3df4e7e8a8f'")"

mkdb t3
q t3 "set session_replication_role = replica; update public.docs set data = data || '{\"currentName\":\"מישהו אחר\"}'::jsonb where collection='profiles' and id='p_b2ae1de0a3df4e7e8a8f'" 
OUT=$("${P[@]}" -d t3 -f "$F24" 2>&1) || true
check "שם הפרופיל לא תואם → נעצר בלי מנוי" "1|0" "$(echo "$OUT" | grep -c 'השם השתנה')|$(q t3 "select count(*) from public.hdm_subscriptions where profile_id='p_b2ae1de0a3df4e7e8a8f'")"

mkdb t4
q t4 "update public.hdm_accounts set profile_id='free1x' where auth_user_id='$OREN_UID'" >/dev/null 2>&1 || q t4 "delete from public.hdm_accounts where auth_user_id='$OREN_UID'" >/dev/null
OUT=$("${P[@]}" -d t4 -f "$F24" 2>&1) || true
check "החשבון לא מקושר לפרופיל → נעצר" "1|0" "$(echo "$OUT" | grep -c 'לא מקושר')|$(q t4 "select count(*) from public.hdm_subscriptions where profile_id='p_b2ae1de0a3df4e7e8a8f'")"

echo; echo "עברו $PASS מתוך $((PASS+FAIL))"
[ "$FAIL" = 0 ]
