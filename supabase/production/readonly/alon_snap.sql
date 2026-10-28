-- קריאה בלבד: צילום מצב לפני/אחרי Plus לאלון — גיבובים וספירות של כל המנויים והתשלומים, ומנוי אלון. לא משנה כלום.
select json_build_object(
 'at', now(),
 'others_subs_md5', (select md5(coalesce(string_agg(to_jsonb(s)::text, ',' order by profile_id), '')) from public.hdm_subscriptions s where profile_id <> 'reg_mvsgolyrptxuqg'),
 'others_subs_count', (select count(*) from public.hdm_subscriptions where profile_id <> 'reg_mvsgolyrptxuqg'),
 'others_events_count', (select count(*) from public.hdm_subscription_events where profile_id <> 'reg_mvsgolyrptxuqg'),
 'payments', (select count(*) from public.hdm_payments), 'payments_md5', (select md5(coalesce(string_agg(to_jsonb(y)::text, ',' order by to_jsonb(y)::text), '')) from public.hdm_payments y),
 'checkouts', (select count(*) from public.hdm_checkouts), 'checkouts_md5', (select md5(coalesce(string_agg(to_jsonb(k)::text, ',' order by k.id), '')) from public.hdm_checkouts k),
 'card_tokens', (select count(*) from public.hdm_billing_tokens),
 'renewal_charges', (select count(*) from public.hdm_renewal_charges),
 'grow_outbox', (select count(*) from public.hdm_grow_outbox),
 'plans_md5', (select md5(string_agg(to_jsonb(p)::text, ',' order by plan)) from public.hdm_plans p),
 'alon_sub', (select to_jsonb(s) from public.hdm_subscriptions s where profile_id = 'reg_mvsgolyrptxuqg'),
 'alon_events', (select json_agg(to_jsonb(e) - 'profile_id' order by e.id) from public.hdm_subscription_events e where e.profile_id = 'reg_mvsgolyrptxuqg'),
 'alon_billing', (select json_build_object('checkouts',(select count(*) from public.hdm_checkouts where profile_id='reg_mvsgolyrptxuqg'),'payments',(select count(*) from public.hdm_payments where profile_id='reg_mvsgolyrptxuqg'),'tokens',(select count(*) from public.hdm_billing_tokens where profile_id='reg_mvsgolyrptxuqg'),'renewals',(select count(*) from public.hdm_renewal_charges where profile_id='reg_mvsgolyrptxuqg'),'outbox',(select count(*) from public.hdm_grow_outbox where profile_id='reg_mvsgolyrptxuqg'))),
 'alon_in_renewal_list', (select count(*) from public.hdm_subscriptions s where s.profile_id='reg_mvsgolyrptxuqg' and s.source='payment' and s.auto_renew and s.status in ('active','past_due'))
) as j
