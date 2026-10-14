-- קריאה בלבד: פונקציות SECURITY DEFINER בסכמה public שמשתמש מחובר יכול להפעיל דרך /rpc
select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as fn,
       case when pg_get_functiondef(p.oid) ~ 'pg_trigger_depth\(\) *(=|>) *0' then 'trigger-only'
            when pg_get_functiondef(p.oid) ~ 'hdm_me\(\)|auth\.uid\(\)' then 'uses-caller'
            else 'NO-GUARD' end as guard,
       exists (select 1 from pg_policies pol where pol.schemaname='public'
               and (coalesce(pol.qual,'') || coalesce(pol.with_check,'')) ~ ('\m' || p.proname || '\(')) as in_policy,
       exists (select 1 from pg_proc q join pg_namespace qn on qn.oid=q.pronamespace
               where qn.nspname='public' and q.oid<>p.oid and pg_get_functiondef(q.oid) ~ ('\m' || p.proname || '\(')) as used_by_other_fn
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prosecdef and p.prokind = 'f'
  and has_function_privilege('authenticated', p.oid, 'EXECUTE')
order by guard, fn;
