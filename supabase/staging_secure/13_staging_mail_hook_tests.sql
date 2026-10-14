-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: בדיקות למשלוח המיילים בלי SMTP (12)
-- הכול רץ בתוך טרנזקציה ומתבטל בסוף — לא נשמר כלום ולא נשלח אף מייל
-- (בקשות ה-HTTP של pg_net נכנסות לתור רק אחרי commit, ופה תמיד rollback).
-- =====================================================================
do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא הורץ.';
  end if;
  if not exists (select 1 from public.hdm_staging_marker where version = 'staging_mail_hook_v1') then
    raise exception 'עצירה: צריך להתקין קודם את 12_staging_mail_hook.sql. שום דבר לא הורץ.';
  end if;
end $$;

begin;

create temp table t_res (n serial, area text, name text, expected text, got text, ok boolean) on commit drop;

create function pg_temp.chk(p_area text, p_name text, p_exp text, p_got text, p_ok boolean) returns void
language sql as $$ insert into t_res (area, name, expected, got, ok) values (p_area, p_name, p_exp, left(coalesce(p_got, 'NULL'), 300), coalesce(p_ok, false)) $$;

create function pg_temp.ev(act text, email text, th text, redir text, extra jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object(
    'user', jsonb_build_object('id', gen_random_uuid(), 'email', email) || coalesce(extra->'user', '{}'::jsonb),
    'email_data', jsonb_build_object('token', '123456', 'token_hash', th, 'redirect_to', redir,
       'email_action_type', act, 'site_url', 'https://shmulikhavivi-design.github.io/haim-derech-misparim/',
       'token_new', '', 'token_hash_new', '') || coalesce(extra->'email_data', '{}'::jsonb))
$$;

do $$
declare
  base text := public.hdm_mail_auth_base() || '/verify';
  site text := 'https://shmulikhavivi-design.github.io/haim-derech-misparim/';
  m jsonb; r jsonb; q bigint; q2 bigint; b jsonb; k text; nlog bigint; e text;
begin
  -- ---------- בניית המיילים (בלי משלוח) ----------
  m := public.hdm_mail_render(pg_temp.ev('signup', 'a@example.invalid', 'pkce_abc123', site));
  perform pg_temp.chk('הרשמה', 'מייל אחד לכתובת הנרשמת', '1 → a@example.invalid', jsonb_array_length(m) || ' → ' || (m->0->>'to'),
    jsonb_array_length(m) = 1 and m->0->>'to' = 'a@example.invalid');
  perform pg_temp.chk('הרשמה', 'נושא בעברית', 'אישור הרשמה — חיים דרך מספרים', m->0->>'subject', m->0->>'subject' = 'אישור הרשמה — חיים דרך מספרים');
  perform pg_temp.chk('הרשמה', 'קישור אימות של Supabase עם האסימון והסוג', base || '?token=pkce_abc123&type=signup&redirect_to=...',
    m->0->>'text', strpos(m->0->>'text', base || '?token=pkce_abc123&type=signup&redirect_to=https%3A%2F%2Fshmulikhavivi-design.github.io%2Fhaim-derech-misparim%2F') > 0);
  perform pg_temp.chk('הרשמה', 'המייל מימין לשמאל ועם כתובת הקשר', 'dir="rtl" + life.through.numbers333',
    left(m->0->>'html', 80), m->0->>'html' like '<div dir="rtl"%' and m->0->>'html' like '%life.through.numbers333@gmail.com%');

  m := public.hdm_mail_render(pg_temp.ev('recovery', 'b@example.invalid', 'h_rec', site || '?hdm_reset=1'));
  perform pg_temp.chk('שכחתי סיסמה', 'קישור איפוס שומר על ?hdm_reset=1 (מקודד)', '...type=recovery&redirect_to=...%3Fhdm_reset%3D1',
    m->0->>'text', strpos(m->0->>'text', '?token=h_rec&type=recovery&redirect_to=') > 0 and (m->0->>'text') like '%haim-derech-misparim%2F%3Fhdm_reset%3D1%');
  perform pg_temp.chk('שכחתי סיסמה', 'נושא', 'איפוס סיסמה — חיים דרך מספרים', m->0->>'subject', m->0->>'subject' = 'איפוס סיסמה — חיים דרך מספרים');
  perform pg_temp.chk('שכחתי סיסמה', 'ב-HTML ה-& בקישור מקודד (&amp;)', '&amp;type=recovery', null, (m->0->>'html') like '%&amp;type=recovery&amp;redirect_to=%');

  m := public.hdm_mail_render(pg_temp.ev('magiclink', 'c@example.invalid', 'h_ml', ''));
  perform pg_temp.chk('קישור כניסה', 'בלי redirect_to: נלקחת כתובת האתר', 'redirect_to=site_url', m->0->>'text',
    (m->0->>'text') like '%type=magiclink&redirect_to=https%3A%2F%2Fshmulikhavivi-design%');

  m := public.hdm_mail_render(pg_temp.ev('email_change', 'old@example.invalid', 'h_for_new', site,
         '{"user":{"new_email":"new@example.invalid"},"email_data":{"token_hash_new":"h_for_old"}}'));
  perform pg_temp.chk('שינוי מייל', 'שינוי מאובטח: שני מיילים', '2', jsonb_array_length(m)::text, jsonb_array_length(m) = 2);
  perform pg_temp.chk('שינוי מייל', 'token_hash → לכתובת החדשה, token_hash_new → לכתובת הנוכחית', 'new:h_for_new, old:h_for_old',
    (m->0->>'to') || ':' || (m->1->>'to'),
    m->0->>'to' = 'new@example.invalid' and (m->0->>'text') like '%token=h_for_new&type=email_change%'
    and m->1->>'to' = 'old@example.invalid' and (m->1->>'text') like '%token=h_for_old&type=email_change%');
  m := public.hdm_mail_render(pg_temp.ev('email_change', 'old@example.invalid', 'h_only', site, '{"user":{"new_email":"new@example.invalid"}}'));
  perform pg_temp.chk('שינוי מייל', 'שינוי רגיל: מייל אחד לכתובת החדשה', '1 → new', jsonb_array_length(m) || ' → ' || (m->0->>'to'),
    jsonb_array_length(m) = 1 and m->0->>'to' = 'new@example.invalid');

  m := public.hdm_mail_render(pg_temp.ev('reauthentication', 'd@example.invalid', '', ''));
  perform pg_temp.chk('קוד אימות', 'קוד בן 6 ספרות, בלי קישור', '123456, בלי /verify', m->0->>'text',
    (m->0->>'html') like '%123456%' and strpos(m->0->>'html', '/verify') = 0);

  m := public.hdm_mail_render(pg_temp.ev('recovery', 'e@example.invalid', 'h"><script>x</script>', 'https://x.invalid/"><img src=x onerror=alert(1)>'));
  perform pg_temp.chk('אבטחה', 'אין הזרקת HTML מהקישור', 'בלי <script> ובלי <img', null,
    strpos(m->0->>'html', '<script') = 0 and strpos(m->0->>'html', '<img') = 0);
  m := public.hdm_mail_render(pg_temp.ev('recovery', 'not-an-email', 'h', site));
  perform pg_temp.chk('אבטחה', 'כתובת לא תקינה — לא נבנה מייל', '0', jsonb_array_length(m)::text, jsonb_array_length(m) = 0);

  -- ---------- ה-Hook ----------
  -- בלי ממסר מוגדר: שגיאה ברורה (המשתמש רואה "לא נשלח"), ונרשם ביומן
  delete from vault.secrets where name in ('hdm_mail_relay_url', 'hdm_mail_relay_key');
  r := public.hdm_send_email_hook(pg_temp.ev('recovery', 'f@example.invalid', 'h1', site));
  perform pg_temp.chk('Hook', 'ממסר לא מוגדר → שגיאה 500 ל-Auth', 'error.http_code=500', r::text, (r->'error'->>'http_code')::int = 500);
  perform pg_temp.chk('Hook', 'ממסר לא מוגדר → נרשם ביומן', 'relay_not_configured',
    (select status from public.hdm_mail_log order by id desc limit 1), (select status from public.hdm_mail_log order by id desc limit 1) = 'relay_not_configured');

  -- הגדרה: כתובת שאינה Apps Script נדחית
  begin perform public.hdm_mail_setup('https://evil.example/exec'); e := 'accepted';
  exception when others then e := 'rejected'; end;
  perform pg_temp.chk('הגדרה', 'כתובת שאינה Apps Script נדחית', 'rejected', e, e = 'rejected');
  k := public.hdm_mail_setup('  https://script.google.com/macros/s/AKfyTEST_only-123/exec ');
  perform pg_temp.chk('הגדרה', 'מחזירה מפתח אקראי (48 תווי hex) ושומרת שני סודות ב-Vault', '48 hex + 2 secrets',
    length(k) || ' / ' || (select count(*) from vault.decrypted_secrets where name like 'hdm_mail_relay_%'),
    k ~ '^[0-9a-f]{48}$' and (select count(*) from vault.decrypted_secrets where name like 'hdm_mail_relay_%') = 2);
  perform public.hdm_mail_setup('https://script.google.com/macros/s/AKfyTEST_only-123/exec');
  perform pg_temp.chk('הגדרה', 'הרצה חוזרת מחליפה את המפתח (לא מכפילה סודות)', '2',
    (select count(*) from vault.decrypted_secrets where name like 'hdm_mail_relay_%')::text,
    (select count(*) from vault.decrypted_secrets where name like 'hdm_mail_relay_%') = 2
    and (select decrypted_secret from vault.decrypted_secrets where name = 'hdm_mail_relay_key') <> k);
  k := (select decrypted_secret from vault.decrypted_secrets where name = 'hdm_mail_relay_key');

  -- עם ממסר: מחזיר {} ושם בקשת HTTP אחת בתור (בטרנזקציה הזו בלבד — מתבטלת בסוף)
  select coalesce(max(id), 0) into q from net.http_request_queue;
  nlog := (select count(*) from public.hdm_mail_log);
  r := public.hdm_send_email_hook(pg_temp.ev('recovery', 'g@example.invalid', 'h2', site || '?hdm_reset=1'));
  perform pg_temp.chk('Hook', 'עם ממסר → הצלחה ({})', '{}', r::text, r = '{}'::jsonb);
  select count(*), max(id) into nlog, q2 from net.http_request_queue where id > q;
  perform pg_temp.chk('Hook', 'בקשת HTTP אחת לכתובת הממסר', '1 → script.google.com',
    nlog || ' → ' || coalesce((select url from net.http_request_queue where id = q2), '-'),
    nlog = 1 and (select url from net.http_request_queue where id = q2) = 'https://script.google.com/macros/s/AKfyTEST_only-123/exec');
  select convert_from(hq.body, 'UTF8')::jsonb into b from net.http_request_queue hq where hq.id = q2;
  perform pg_temp.chk('Hook', 'גוף הבקשה: נמען, נושא, HTML ומפתח הממסר', 'to/subject/html/text/key',
    (select string_agg(x, ',' order by x) from jsonb_object_keys(b) x),
    b->>'to' = 'g@example.invalid' and b->>'key' = k and b ? 'html' and b ? 'text' and b->>'subject' like 'איפוס סיסמה%');
  perform pg_temp.chk('Hook', 'היומן לא שומר כתובות, אסימונים או תוכן', 'רק action/messages/status',
    (select row_to_json(l)::text from public.hdm_mail_log l order by id desc limit 1),
    (select row_to_json(l)::text from public.hdm_mail_log l order by id desc limit 1) not like '%example.invalid%'
    and (select row_to_json(l)::text from public.hdm_mail_log l order by id desc limit 1) not like '%h2%'
    and (select status from public.hdm_mail_log order by id desc limit 1) = 'queued');
  select count(*) into nlog from net.http_request_queue where id > q2;
  r := public.hdm_send_email_hook(pg_temp.ev('email_change', 'old@example.invalid', 'hx', site,
         '{"user":{"new_email":"new@example.invalid"},"email_data":{"token_hash_new":"hy"}}'));
  perform pg_temp.chk('Hook', 'שינוי מייל מאובטח → שתי בקשות', '2',
    (select count(*) from net.http_request_queue where id > q2)::text, (select count(*) from net.http_request_queue where id > q2) = 2);

  -- ---------- הרשאות ----------
  perform pg_temp.chk('הרשאות', 'Auth (supabase_auth_admin) יכול להפעיל את ה-Hook', 'true',
    has_function_privilege('supabase_auth_admin', 'public.hdm_send_email_hook(jsonb)', 'execute')::text,
    has_function_privilege('supabase_auth_admin', 'public.hdm_send_email_hook(jsonb)', 'execute'));
  perform pg_temp.chk('הרשאות', 'אורח / משתמש מחובר לא יכולים להפעיל שום פונקציית מייל', 'false ×10',
    (select string_agg(has_function_privilege(r.rol, f.sig, 'execute')::text, ',')
       from unnest(array['anon','authenticated']) r(rol),
            unnest(array['public.hdm_send_email_hook(jsonb)','public.hdm_mail_render(jsonb)','public.hdm_mail_setup(text)',
                         'public.hdm_mail_status(integer)','public.hdm_mail_auth_base()']) f(sig)),
    not exists (select 1 from unnest(array['anon','authenticated']) r(rol),
            unnest(array['public.hdm_send_email_hook(jsonb)','public.hdm_mail_render(jsonb)','public.hdm_mail_setup(text)',
                         'public.hdm_mail_status(integer)','public.hdm_mail_auth_base()']) f(sig)
            where has_function_privilege(r.rol, f.sig, 'execute')));
  perform pg_temp.chk('הרשאות', 'אורח / משתמש מחובר לא קוראים את יומן המיילים', 'false',
    (has_table_privilege('anon', 'public.hdm_mail_log', 'select') or has_table_privilege('authenticated', 'public.hdm_mail_log', 'select'))::text,
    not (has_table_privilege('anon', 'public.hdm_mail_log', 'select') or has_table_privilege('authenticated', 'public.hdm_mail_log', 'select')));
  perform pg_temp.chk('הרשאות', 'יומן המיילים: RLS פעיל', 'true',
    (select relrowsecurity::text from pg_class where oid = 'public.hdm_mail_log'::regclass),
    (select relrowsecurity from pg_class where oid = 'public.hdm_mail_log'::regclass));
end $$;

select n as "#", area as "תחום", name as "בדיקה", expected as "צפוי", case when ok then '' else got end as "התקבל (אם נכשל)",
       case when ok then '✅' else '❌' end as "עבר"
from t_res order by n;

select format('סיכום: עברו %s מתוך %s %s', count(*) filter (where ok), count(*),
              case when bool_and(ok) then '✅' else '❌' end) as "סיכום"
from t_res;

rollback;
