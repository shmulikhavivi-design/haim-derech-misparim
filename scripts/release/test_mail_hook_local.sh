#!/usr/bin/env bash
# בדיקה מקומית בלבד (בלי סודות, בלי רשת): מתקין את 12_staging_mail_hook.sql על מסד Postgres זמני
# עם הדמיה של Supabase (auth, vault, pg_net) ומריץ את 13_staging_mail_hook_tests.sql.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"; PORT=$((20000 + RANDOM % 20000))
"$PGBIN/initdb" -D "$WORK/data" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null
"$PGBIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=" -l "$WORK/pg.log" -w start >/dev/null
trap '"$PGBIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
P=(psql -h "$WORK" -p "$PORT" -U postgres -d postgres -X -v ON_ERROR_STOP=1 --quiet)

"${P[@]}" -f "$ROOT/scripts/release/local_supabase_mock.sql" >/dev/null
"${P[@]}" >/dev/null <<'SQL'
-- הדמיה של Vault ו-pg_net (מקומי בלבד)
create schema vault;
create table vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, description text, secret text);
create view vault.decrypted_secrets as select id, name, description, secret as decrypted_secret from vault.secrets;
create function vault.create_secret(s text, n text, d text default '') returns uuid language sql as
  $$ insert into vault.secrets (name, description, secret) values (n, d, s) returning id $$;
create function vault.update_secret(i uuid, s text) returns void language sql as $$ update vault.secrets set secret = s where id = i $$;
create schema net;
create table net.http_request_queue (id bigserial primary key, method text, url text, headers jsonb, body bytea, timeout_milliseconds int);
create table net._http_response (id bigint, status_code int, error_msg text);
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000)
returns bigint language sql as $$ insert into net.http_request_queue (method, url, headers, body, timeout_milliseconds)
  values ('POST', url, headers, convert_to(body::text, 'UTF8'), timeout_milliseconds) returning id $$;
create table public.hdm_staging_marker (installed_at timestamptz not null default now(), version text not null default 'staging_secure_v1', note text not null default '');
insert into public.hdm_staging_marker default values;
SQL
sed 's/^create extension if not exists pg_net;$/-- (local: pg_net mocked)/' "$ROOT/supabase/staging_secure/12_staging_mail_hook.sql" | "${P[@]}"
{ "${P[@]}" -f "$ROOT/supabase/staging_secure/12_staging_mail_hook.sql" 2>&1 || true; } | grep -q 'כבר הותקן' && echo "✅ הרצה חוזרת נעצרת"
OUT=$("${P[@]}" -f "$ROOT/supabase/staging_secure/13_staging_mail_hook_tests.sql" 2>&1) || true
echo "$OUT"
echo "$OUT" | grep -q 'סיכום.*✅' || { echo "❌ נכשל"; exit 1; }
LEFT=$("${P[@]}" -At -c "select (select count(*) from net.http_request_queue) + (select count(*) from vault.secrets) + (select count(*) from public.hdm_mail_log)")
[ "$LEFT" = 0 ] && echo "✅ לא נשאר כלום אחרי הבדיקות (תור HTTP, Vault, יומן)" || { echo "❌ נשארו נתונים: $LEFT"; exit 1; }
