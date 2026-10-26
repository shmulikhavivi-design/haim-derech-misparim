#!/usr/bin/env bash
# paydiagthree (26.10) — קריאה בלבד. מצב הלקוח שניסה להצטרף היום: כרטיס שמור במסד, מזהה לקוח Morning מול הטוקן, הגדרות הפונקציות SQL. מוצפן.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"; PID='reg_mvmxfyilz2yu20'
OUTD="${RUNNER_TEMP:-/tmp}/hdm-export"; rm -rf "$OUTD"; mkdir -p "$OUTD/out" "$OUTD/w"; W="$OUTD/w"
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
q "select (select count(*) from public.hdm_billing_tokens where profile_id='$PID') tokens, (select row_to_json(s) from (select plan,status,source,auto_renew,current_period_end from public.hdm_subscriptions where profile_id='$PID') s) sub, (select count(*) from public.hdm_accounts where profile_id='$PID') accounts" > "$W/state.json"
q "select coalesce(json_agg(json_build_object('name',p.proname,'args',pg_get_function_identity_arguments(p.oid),'def',pg_get_functiondef(p.oid))),'[]') j from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('hdm_billing_save_token','hdm_billing_claim_checkout','hdm_billing_checkout_lookup','hdm_billing_start_checkout','hdm_billing_apply_grow_event')" > "$W/fns.json"
q "select column_name, data_type, is_nullable from information_schema.columns where table_schema='public' and table_name in ('hdm_billing_tokens','hdm_billing_customers') order by table_name, ordinal_position" > "$W/cols.json"
q "select conname, pg_get_constraintdef(oid) d, conrelid::regclass::text t from pg_constraint where conrelid in ('public.hdm_billing_tokens'::regclass,'public.hdm_billing_customers'::regclass,'public.hdm_checkouts'::regclass)" > "$W/cons.json"
CID=$(q "select morning_client_id from public.hdm_billing_customers where profile_id='$PID'" | jq -r '.[0].morning_client_id // empty'); echo "::add-mask::${CID:-x}"
command -v deno >/dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null 2>&1; export PATH="$HOME/.deno/bin:$PATH"; }
echo "::add-mask::${MORNING_CLIENT_SECRET:-x}"
CID="$CID" deno run --allow-net=api.morning.co,api.greeninvoice.co.il --allow-env --allow-read --allow-write="$W" "$ROOT/scripts/production/pay_diag3.ts" "$W/morning.json" || echo fail > "$W/morning_fail.txt"
ann notice "paydiag3-sizes" "$(cd "$W" && wc -c * | tr '\n' ' ')"
tar -C "$OUTD" -czf "$OUTD/r.json" w; rm -rf "$OUTD/w"
openssl rand -out "$OUTD/k.bin" 32
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$OUTD/r.json" -out "$OUTD/out/backup.tgz.enc" -pass file:"$OUTD/k.bin"
openssl pkeyutl -encrypt -pubin -inkey "$HERE/session_2610_public.pem" -pkeyopt rsa_padding_mode:oaep -in "$OUTD/k.bin" -out "$OUTD/out/key.enc"
shred -u "$OUTD/k.bin" "$OUTD/r.json"
ann notice "prod-result" "✅ paydiagthree: נאסף ומוצפן (קריאה בלבד)"
