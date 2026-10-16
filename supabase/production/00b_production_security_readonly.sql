-- Read-only: security & subscriptions state of Production (counts and names only, no personal data)
select json_build_object(
  'tables', (select json_agg(json_build_object('t', c.relname, 'rls', c.relrowsecurity,
              'policies', (select count(*) from pg_policies p where p.schemaname='public' and p.tablename=c.relname),
              'anon', (select string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants g where g.table_schema='public' and g.table_name=c.relname and g.grantee='anon'),
              'authenticated', (select string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants g where g.table_schema='public' and g.table_name=c.relname and g.grantee='authenticated')) order by c.relname)
            from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='r'),
  'docs_policies', (select json_agg(json_build_object('name', policyname, 'cmd', cmd, 'roles', roles::text, 'open', coalesce(qual,'') in ('true','') ) order by policyname) from pg_policies where schemaname='public' and tablename='docs'),
  'docs_by_collection', (select json_object_agg(collection, n) from (select collection, count(*) n from public.docs group by collection) x),
  'functions_anon_exec', (select count(*) from pg_proc p where p.pronamespace='public'::regnamespace and has_function_privilege('anon', p.oid, 'EXECUTE') and p.prokind='f'),
  'pr9_subscriptions_installed', to_regclass('public.hdm_subscriptions') is not null,
  'release_marker', to_regclass('public.hdm_release_marker') is not null,
  'backup_schema', to_regnamespace('hdm_backup') is not null,
  'auth_users', (select count(*) from auth.users),
  'auth_confirmed', (select count(*) from auth.users where email_confirmed_at is not null),
  'auth_last_signin_7d', (select count(*) from auth.users where last_sign_in_at > now() - interval '7 days'),
  'pg_net_installed', exists (select 1 from pg_extension where extname='pg_net')
) as report;
