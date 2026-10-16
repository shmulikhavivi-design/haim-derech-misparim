-- Read-only: what is inside the existing hdm_backup schema (names, row counts, owner) — no content
select json_build_object(
  'objects', (select json_agg(json_build_object('name', c.relname, 'kind', c.relkind,
                 'rows', case when c.relkind in ('r','p') then (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from hdm_backup.%I', c.relname), false, true, '')))[1]::text::bigint end,
                 'owner', pg_get_userbyid(c.relowner)) order by c.relname)
              from pg_class c where c.relnamespace = 'hdm_backup'::regnamespace and c.relkind in ('r','p','v','m')),
  'functions', (select count(*) from pg_proc where pronamespace = 'hdm_backup'::regnamespace),
  'schema_owner', (select pg_get_userbyid(nspowner) from pg_namespace where nspname = 'hdm_backup'),
  'docs_now', (select count(*) from public.docs),
  'counts_table', case when to_regclass('hdm_backup.counts_before_migration') is not null
                   then query_to_xml('select * from hdm_backup.counts_before_migration', false, true, '')::text end
) as backup;
