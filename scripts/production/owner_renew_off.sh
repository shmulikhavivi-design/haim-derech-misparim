#!/usr/bin/env bash
# ownerrenewoff — ביטול החידוש האוטומטי של הבעלים (אישור 22.10 22:47) דרך פונקציית הביטול של האפליקציה (hdm_billing_cancel, בלי החזר).
# התקופה ששולמה נשארת עד 22.11, אין חיוב, אין מחיקה. קודם חזרה בעסקה שמבוטלת, אחר כך ביצוע, ואז אימות.
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"; RO="$RW/read-only"
q(){ curl -sS -m 120 -o /tmp/or.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$1" -d "$(jq -nc --arg q "$2" '{query:$q}')" || echo 000; }
ST="select json_build_object('plan', s.plan, 'plan_now', public.hdm_plan_of(s.profile_id), 'status', s.status, 'auto_renew', to_jsonb(s)->>'auto_renew', 'period_end', to_char(s.current_period_end at time zone 'Asia/Jerusalem','DD.MM.YYYY HH24:MI'), 'payments', (select count(*) from public.hdm_payments), 'charges', (select count(*) from public.hdm_renewal_charges), 'card_saved', exists (select 1 from public.hdm_billing_tokens t where t.profile_id=s.profile_id), 'cancel_requests', (select count(*) from public.hdm_cancel_requests c where c.profile_id=s.profile_id), 'emails_queued', (select count(*) from public.hdm_email_outbox e where e.profile_id=s.profile_id and e.sent_at is null)) r from public.hdm_subscriptions s join public.hdm_accounts a on a.profile_id=s.profile_id join auth.users u on u.id=a.auth_user_id where md5(lower(u.email))='162e004328485070b0af8b256ad2e798'"
q "$RW" "$ST" >/dev/null; BEFORE=$(jq -c '.[0].r' /tmp/or.json); ann notice "or-1-before" "לפני: $BEFORE"
echo "$BEFORE" | jq -e '.auto_renew == "true"' >/dev/null || stop "החידוש כבר כבוי או שהמנוי לא נמצא — לא שונה כלום."
CORE=$(cat <<'SQL'
do $c$ declare uid uuid := (select id from auth.users where md5(lower(email))='162e004328485070b0af8b256ad2e798'); r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true); perform set_config('role', 'authenticated', true);
  r := public.hdm_billing_cancel(false);
  execute 'reset role';
  perform set_config('hdm.or_result', r::text, true);
end $c$;
SQL
)
SIM="do \$s\$ declare pid text := (select a.profile_id from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where md5(lower(u.email))='162e004328485070b0af8b256ad2e798'); n int; begin
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pid;
  select count(*) into n from jsonb_array_elements(public.hdm_billing_claim_due_renewals(500)) x where x->>'profileId' = pid;
  raise exception 'HDM_OR result=% claimed_after_due=%', current_setting('hdm.or_result', true), n; end \$s\$;"
C=$(q "$RW" "begin; $CORE $SIM rollback;"); M=$(jq -r '.message // tostring' /tmp/or.json | grep -o 'HDM_OR.*' | head -1 | cut -c1-500)
echo "$M" | grep -q '"canceled": true' && echo "$M" | grep -q 'claimed_after_due=0' || stop "החזרה לא עברה — לא שונה כלום: ${M:-HTTP $C $(jq -r '.message // tostring' /tmp/or.json | cut -c1-300)}"
ann notice "or-2-rehearse" "✅ חזרה (בוטלה): $M"
C=$(q "$RW" "begin; $CORE commit;"); case "$C" in 200|201) ;; *) stop "הביצוע נכשל (HTTP $C): $(jq -r '.message // tostring' /tmp/or.json | cut -c1-300)";; esac
q "$RW" "$ST" >/dev/null; AFTER=$(jq -c '.[0].r' /tmp/or.json); ann notice "or-3-after" "אחרי: $AFTER"
python3 - "$BEFORE" "$AFTER" <<'PY' && ann notice "or-4-verify" "✅ החידוש האוטומטי כבוי; המסלול נשאר בסיסי עד 22.11; אין חיוב חדש; הכרטיס והתשלומים לא השתנו" || ann error "or-4-verify" "❗ לבדוק: $BEFORE → $AFTER"
import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2])
ok = b['auto_renew']=='false' and b['plan_now']=='basic' and b['period_end']==a['period_end'] and b['payments']==a['payments'] and b['charges']==a['charges'] and b['card_saved']==a['card_saved']
sys.exit(0 if ok else 1)
PY
ann notice "prod-result" "ownerrenewoff הסתיים"
