#!/usr/bin/env bash
# incident3 — מה קורה אחרי הכניסה, בעסקה שמבוטלת תמיד: לכל חשבון מאושר (בלי לזהות אותו) מריצים כמו האפליקציה —
# hdm_claim_profile, hdm_terms_status, hdm_accept_terms, שמירת פרופיל (רק למשתמש הבדיקה), hdm_my_entitlements, hdm_my_private, hdm_my_targets.
# בסוף rollback: שום דבר לא נשמר. מדפיס רק "חשבון 1/2/3" ותוצאה, בלי שמות או אימיילים.
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"
Q=$(cat <<'SQL'
begin;
create temp table t_out (k int, who text, step text, res text);
create or replace function pg_temp.as_user(p_uid uuid, p_sql text) returns text language plpgsql as $f$
declare r text; begin begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true); perform set_config('role', 'authenticated', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || left(coalesce(r, ''), 160);
exception when others then execute 'reset role'; return 'ERR:' || sqlstate || ' ' || left(sqlerrm, 200); end; end $f$;
do $d$
declare u record; i int := 0; who text; pid text; st jsonb; ver text;
begin
  for u in select id, email like 'life.through.numbers333+incb%' as test from auth.users where email_confirmed_at is not null order by created_at loop
    i := i + 1; who := case when u.test then 'משתמש בדיקה' else 'חשבון ' || i end;
    pid := pg_temp.as_user(u.id, 'select public.hdm_claim_profile()');
    insert into t_out values (i, who, 'claim_profile', pid);
    insert into t_out values (i, who, 'terms_status', pg_temp.as_user(u.id, 'select public.hdm_terms_status()::text'));
    begin st := substr(pg_temp.as_user(u.id, 'select public.hdm_terms_status()::text'), 4)::jsonb; ver := st->>'required'; exception when others then ver := null; end;
    insert into t_out values (i, who, 'accept_terms', pg_temp.as_user(u.id, format('select public.hdm_accept_terms(%L, ''gate'')::text', ver)));
    if u.test and pid like 'ok:%' then
      insert into t_out values (i, who, 'save_profile', pg_temp.as_user(u.id, format($s$insert into public.docs (collection, id, data, updated_at) values ('profiles', %L, '{"currentName":"בדיקה","gender":"אישה","lookingFor":"גברים","birthdate":"1990-01-01","age":"36","location":"תל אביב"}'::jsonb, now()) on conflict (collection, id) do update set data = excluded.data returning id$s$, substr(pid, 4))));
    end if;
    insert into t_out values (i, who, 'read_own_profile', pg_temp.as_user(u.id, format('select count(*)::text from public.docs where collection = ''profiles'' and id = %L', substr(pid, 4))));
    insert into t_out values (i, who, 'entitlements', pg_temp.as_user(u.id, 'select public.hdm_my_entitlements()::text'));
    insert into t_out values (i, who, 'my_private', pg_temp.as_user(u.id, 'select left(public.hdm_my_private()::text, 20)'));
    insert into t_out values (i, who, 'my_targets', pg_temp.as_user(u.id, 'select left(public.hdm_my_targets()::text, 20)'));
    insert into t_out values (i, who, 'profiles_visible', pg_temp.as_user(u.id, 'select count(*)::text from public.docs where collection = ''profiles'''));
  end loop;
  raise exception 'HDM_OUT %', (select json_agg(json_build_object('who', t.who, 'step', t.step, 'res', regexp_replace(t.res, '[A-Za-z0-9._%%+-]+@[A-Za-z0-9.-]+', '<email>', 'g')) order by t.k, t.step) from t_out t);
end $d$;
rollback;
SQL
)
C=$(curl -sS -m 120 -o /tmp/i3.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
M=$(jq -r '.message // tostring' /tmp/i3.json | grep -o 'HDM_OUT .*' | sed 's/^HDM_OUT //' | head -1 || true)
if [ -n "$M" ]; then
  ERRS=$(echo "$M" | jq -c '[.[] | select(.res | startswith("ERR"))]' 2>/dev/null)
  ann notice "i3-errors" "שגיאות: ${ERRS:-?}"
  ann notice "i3-all" "$(echo "$M" | jq -r '[.[] | "\(.who)/\(.step)=\(.res|.[0:60])"] | join(" | ")' 2>/dev/null | sed -E 's/"pid"[^,]*//g' | cut -c1-3500)"
else ann error "i3" "HTTP $C $(jq -r '.message // tostring' /tmp/i3.json | cut -c1-800)"; fi
ann notice "prod-result" "incident3 הסתיים — הכול בוטל (rollback), שום דבר לא נשמר"
