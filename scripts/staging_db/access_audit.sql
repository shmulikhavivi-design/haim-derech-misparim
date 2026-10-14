-- קריאה בלבד: סימנים לשימוש לא מורשה במסד של Staging
select 'roles (login, not built-in)' as what, string_agg(rolname, ', ') as value from pg_roles
 where rolcanlogin and rolname not in ('postgres','authenticator','supabase_admin','supabase_auth_admin','supabase_storage_admin','supabase_replication_admin','supabase_read_only_user','pgbouncer','supabase_realtime_admin','supabase_functions_admin','supabase_etl_admin','dashboard_user','pgsodium_keymaker','pgsodium_keyholder','supabase_privileged_role')
union all select 'auth.users total', count(*)::text from auth.users
union all select 'auth.users created last 3d (not test domains)', count(*)::text from auth.users where created_at > now() - interval '3 days' and email not like '%@example.invalid' and email not like 'life.through.numbers333+%'
union all select 'public tables (not hdm_/docs)', coalesce(string_agg(tablename, ', '), 'none') from pg_tables where schemaname='public' and tablename !~ '^(hdm_|docs$)'
union all select 'schemas (non-system)', string_agg(nspname, ', ') from pg_namespace where nspname !~ '^(pg_|information_schema|auth|storage|realtime|extensions|graphql|graphql_public|vault|pgsodium|pgsodium_masks|supabase_|net|cron|pgbouncer|_realtime|_analytics|public)'
union all select 'functions in public not hdm_/pg_temp', coalesce(string_agg(proname, ', '), 'none') from pg_proc where pronamespace='public'::regnamespace and proname !~ '^hdm_'
union all select 'event triggers', coalesce(string_agg(evtname, ', '), 'none') from pg_event_trigger where evtname !~ '^(issue_|pgrst_|graphql_|supabase_)'
union all select 'active connections now (app | client)', string_agg(distinct coalesce(application_name,'') || ' | ' || coalesce(host(client_addr),'local'), '; ') from pg_stat_activity where usename = 'postgres';
