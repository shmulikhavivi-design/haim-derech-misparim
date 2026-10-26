#!/usr/bin/env bash
# agediag (26.10) — READ ONLY (database/query/read-only). אבחון סינון גילאים. מזהים מוסווים, בלי שמות/מיילים. אין כתיבה.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
q(){ curl -sS -m 120 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
BUF=/tmp/ad.txt; : > $BUF; w(){ printf '%s\n' "$*" >> $BUF; }
BASE="with pr as (select d.id, d.data, nullif(regexp_replace(coalesce(d.data->>'age',''),'\D','','g'),'')::int pub_age, date_part('year', age(pp.birthdate))::int real_age,
       exists(select 1 from public.hdm_hidden_profiles h where h.profile_id=d.id) hidden, (d.data->>'deleted') del,
       coalesce((select s.plan from public.hdm_subscriptions s where s.profile_id=d.id and s.status in ('active','canceled') and (s.current_period_end is null or s.current_period_end>now())),'free') plan
     from public.docs d left join public.hdm_profile_private pp on pp.profile_id=d.id where d.collection='profiles' and coalesce(d.data->>'lifePathNumber','')<>''),
   g as (select id, data, pub_age, real_age, hidden, del, plan,
       case when data->>'gender' like 'גבר%' then 'm' when data->>'gender' like 'אישה%' then 'f' else '?' end gc,
       case when data->>'lookingFor' like 'גבר%' then 'm' when data->>'lookingFor' like 'נש%' then 'f' else 'any' end sc,
       data->>'ageMin' amin_raw, data->>'ageMax' amax_raw,
       nullif(regexp_replace(coalesce(data->>'ageMin',''),'\D','','g'),'')::int amin, nullif(regexp_replace(coalesce(data->>'ageMax',''),'\D','','g'),'')::int amax from pr)"
w "== raw values: gender / lookingFor / ageMin / ageMax types (distinct)"
q "select data->>'gender' g, data->>'lookingFor' lf, jsonb_typeof(data->'ageMin') tmin, jsonb_typeof(data->'ageMax') tmax, jsonb_typeof(data->'age') tage, count(*) n from public.docs where collection='profiles' group by 1,2,3,4,5 order by n desc" | jq -c '.[]?' >> $BUF
w "== profiles: id | plan | gender>seeks | range(raw) | pub_age | real_age(birthdate) | hidden | deleted"
q "$BASE select substr(md5(id),1,6) id, plan, gc||'>'||sc gs, coalesce(amin_raw,'∅')||'-'||coalesce(amax_raw,'∅') rng, pub_age, real_age, hidden, del from g order by gc, id" | jq -r '.[]? | [.id,.plan,.gs,.rng,.pub_age,.real_age,.hidden,.del]|map(tostring)|join(" | ")' >> $BUF
w "== per viewer: id | plan | range | STRICT (client rule: unknown age passes) | GENDER-ONLY | out-of-range shown if relaxed"
q "$BASE select substr(md5(v.id),1,6) v, v.plan, coalesce(v.amin::text,'')||'-'||coalesce(v.amax::text,'') rng,
   (select string_agg(substr(md5(c.id),1,6)||'('||coalesce(c.pub_age::text,'?')||')', ' ') from g c where c.id<>v.id and not c.hidden and c.del is distinct from 'true'
      and (v.sc='any' or v.sc=c.gc) and (c.sc='any' or c.sc=v.gc)
      and (c.pub_age is null or ((v.amin is null or c.pub_age>=v.amin) and (v.amax is null or c.pub_age<=v.amax)))
      and (v.pub_age is null or ((c.amin is null or v.pub_age>=c.amin) and (c.amax is null or v.pub_age<=c.amax)))) strict,
   (select string_agg(substr(md5(c.id),1,6)||'('||coalesce(c.pub_age::text,'?')||')', ' ') from g c where c.id<>v.id and not c.hidden and c.del is distinct from 'true'
      and (v.sc='any' or v.sc=c.gc) and (c.sc='any' or c.sc=v.gc)) gender_only
   from g v where v.del is distinct from 'true' order by v.gc, v.id" | jq -r '.[]? | [.v,.plan,.rng,("STRICT: "+(.strict//"NONE")),("GENDER-ONLY: "+(.gender_only//"NONE"))]|join(" | ")' >> $BUF
w "== women seeking men with range 30-43"
q "$BASE select substr(md5(id),1,6) id, plan, amin_raw, amax_raw, pub_age, real_age from g where gc='f' and amin=30 and amax=43" | jq -c '.[]?' >> $BUF
w "== men aged 22 (public or real)"
q "$BASE select substr(md5(id),1,6) id, plan, sc, amin_raw, amax_raw, pub_age, real_age, hidden from g where gc='m' and (pub_age=22 or real_age=22)" | jq -c '.[]?' >> $BUF
w "== public age vs birthdate mismatch count: $(q "$BASE select count(*) filter (where pub_age is distinct from real_age and real_age is not null) mism, count(*) filter (where pub_age is null) no_pub, count(*) total from g" | jq -c '.[0]')"
w "== server-side age filtering in functions? (functions mentioning ageMin)"
q "select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and pg_get_functiondef(p.oid) ilike '%ageMin%'" | jq -c '[.[]?.proname]' >> $BUF
w "== RLS/policies on docs (profiles readable how)"
q "select polname, polcmd, pg_get_expr(polqual, polrelid) q from pg_policy where polrelid='public.docs'::regclass" | jq -c '.[]? | {polname,polcmd,q:(.q|.[0:200])}' >> $BUF
python3 -I - "$BUF" <<'PY'
import sys
t=open(sys.argv[1],encoding='utf-8').read(); n=3300; parts=[t[i:i+n] for i in range(0,len(t),n)] or ['']
for i,c in enumerate(parts[:15],1):
    c=c.replace('%','%25').replace('\r','%0D').replace('\n','%0A'); print(f'::notice title=ad-{i}-of-{len(parts)}::{c}')
PY
ann notice "prod-result" "✅ agediag: קריאה בלבד"
