-- =====================================================================
-- חיים דרך מספרים — Production: משלוח מיילים דרך Gmail בלי SMTP (Send Email Hook)
-- נוצר אוטומטית מ-scripts/release/build_mail_hook_sql.py — אותו קוד שנבדק ב-Staging (12_staging_mail_hook.sql).
-- ⚠️ להרצה רק בפרויקט הפעיל, רק אחרי אישור, ורק אחרי 01_production_migration.sql. "הכול או כלום".
-- לא נוגע בנתונים קיימים: מוסיף טבלת יומן ופונקציות בלבד. ההפעלה עצמה — ב-Authentication ← Hooks.
-- ביטול: ב-Authentication ← Hooks מכבים את Send Email (חוזרים ל-SMTP / לשירות המובנה). אפשר להשאיר את הפונקציות.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is not null then
    raise exception 'עצירה: זה פרויקט הניסוי (Staging). הקובץ הזה מיועד ל-Production בלבד. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_release_marker') is null then
    raise exception 'עצירה: צריך להריץ קודם את 01_production_migration.sql. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_release_marker where version = 'production_mail_hook_v1') then
    raise exception 'עצירה: משלוח המיילים כבר הותקן. שום דבר לא שונה.';
  end if;
end $$;

create function public.hdm_mail_auth_base()
returns text language sql immutable set search_path = '' as $$ select 'https://qtspzigjlbtckqfyaubp.supabase.co/auth/v1'::text $$;

-- ---------------------------------------------------------------------
-- מיילים בלי SMTP ובלי סיסמת אפליקציה: Supabase "Send Email Hook" → ממסר Google Apps Script → Gmail
-- (גוף משותף ל-Staging ול-Production. נבנה לקבצים 12_* על ידי scripts/release/build_mail_hook_sql.py)
--
-- איך זה עובד:
--   1. Supabase Auth צריך לשלוח מייל (אישור הרשמה / שכחתי סיסמה / קישור כניסה / שינוי מייל).
--   2. במקום SMTP, Auth קורא לפונקציה public.hdm_send_email_hook(event).
--   3. הפונקציה בונה את המייל בעברית ואת הקישור, ושולחת בקשת HTTP (pg_net, ברקע) לממסר.
--   4. הממסר הוא סקריפט קטן בחשבון Google של האפליקציה (Apps Script), ששולח דרך MailApp —
--      המייל יוצא מ-life.through.numbers333@gmail.com עצמו, עם החתימה של Google. בלי סיסמת אפליקציה ובלי דומיין.
-- סודות: כתובת הממסר ומפתח הממסר נשמרים רק ב-Vault של Supabase. לא בקוד ולא ב-GitHub.
-- ---------------------------------------------------------------------

create extension if not exists pg_net;

-- יומן משלוח: סוג הפעולה ומזהה הבקשה בלבד. בלי כתובות, בלי אסימונים, בלי תוכן.
create table public.hdm_mail_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  action text not null,
  messages int not null,
  request_ids bigint[] not null default '{}',
  status text not null
);
alter table public.hdm_mail_log enable row level security;
revoke all on table public.hdm_mail_log from public, anon, authenticated;

create function public.hdm_mail_esc(s text)
returns text language sql immutable set search_path = '' as $$
  select replace(replace(replace(replace(replace(coalesce(s, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')
$$;

create function public.hdm_mail_urlenc(s text)
returns text language plpgsql immutable set search_path = '' as $$
declare b bytea := convert_to(coalesce(s, ''), 'UTF8'); i int; c int; o text := '';
begin
  for i in 0 .. length(b) - 1 loop
    c := get_byte(b, i);
    if (c between 48 and 57) or (c between 65 and 90) or (c between 97 and 122) or c in (45, 46, 95, 126) then
      o := o || chr(c);
    else
      o := o || '%' || upper(lpad(to_hex(c), 2, '0'));
    end if;
  end loop;
  return o;
end $$;

-- בניית המיילים מאירוע ה-Hook. פונקציה טהורה (בלי משלוח) — כך אפשר לבדוק אותה בלי לשלוח כלום.
-- מחזירה מערך: [{to, subject, html, text}]
create function public.hdm_mail_render(event jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  d jsonb := coalesce(event->'email_data', '{}'::jsonb);
  u jsonb := coalesce(event->'user', '{}'::jsonb);
  act text := coalesce(d->>'email_action_type', '');
  redir text := coalesce(nullif(d->>'redirect_to', ''), nullif(d->>'site_url', ''), '');
  base text := public.hdm_mail_auth_base() || '/verify';
  out jsonb := '[]'::jsonb;
  btn constant text := 'background:#6b4fa0;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none';
  foot constant text := '<p>חיים דרך מספרים · life.through.numbers333@gmail.com</p>';
  link text; subj text; intro text; label text; tail text; who text; th text; i int;
  pairs jsonb;
begin
  -- שינוי מייל: token_hash שייך לכתובת החדשה, token_hash_new לכתובת הנוכחית (ההפך מהשמות — כך בתיעוד של Supabase)
  if act = 'email_change' then
    pairs := '[]'::jsonb;
    if coalesce(d->>'token_hash', '') <> '' and coalesce(u->>'new_email', '') <> '' then
      pairs := pairs || jsonb_build_array(jsonb_build_object('to', u->>'new_email', 'th', d->>'token_hash'));
    end if;
    if coalesce(d->>'token_hash_new', '') <> '' and coalesce(u->>'email', '') <> '' then
      pairs := pairs || jsonb_build_array(jsonb_build_object('to', u->>'email', 'th', d->>'token_hash_new'));
    end if;
  else
    pairs := jsonb_build_array(jsonb_build_object('to', coalesce(u->>'email', ''), 'th', coalesce(d->>'token_hash', '')));
  end if;

  for i in 0 .. jsonb_array_length(pairs) - 1 loop
    who := pairs->i->>'to';
    th := pairs->i->>'th';
    continue when who !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$';
    link := base || '?token=' || public.hdm_mail_urlenc(th) || '&type=' || public.hdm_mail_urlenc(act)
            || case when redir <> '' then '&redirect_to=' || public.hdm_mail_urlenc(redir) else '' end;
    tail := 'אם לא ביקשת זאת, אפשר להתעלם מהמייל. החשבון לא ישתנה.';
    case act
      when 'signup' then
        subj := 'אישור הרשמה — חיים דרך מספרים';
        intro := '<p>ברוכים הבאים ל"חיים דרך מספרים"!</p><p>כדי להשלים את ההרשמה, יש לאשר את כתובת המייל:</p>';
        label := 'אישור המייל'; tail := 'אם לא נרשמת, אפשר להתעלם מהמייל.';
      when 'recovery' then
        subj := 'איפוס סיסמה — חיים דרך מספרים';
        intro := '<p>שלום,</p><p>קיבלנו בקשה להגדיר סיסמה לחשבון שלך ב"חיים דרך מספרים".</p>';
        label := 'להגדרת סיסמה';
      when 'magiclink' then
        subj := 'קישור כניסה — חיים דרך מספרים';
        intro := '<p>שלום,</p><p>זה קישור הכניסה שלך ל"חיים דרך מספרים":</p>';
        label := 'כניסה';
      when 'invite' then
        subj := 'הזמנה — חיים דרך מספרים';
        intro := '<p>שלום,</p><p>הוזמנת להצטרף ל"חיים דרך מספרים".</p>';
        label := 'קבלת ההזמנה';
      when 'email_change' then
        subj := 'אישור כתובת מייל חדשה — חיים דרך מספרים';
        intro := '<p>כדי לאשר את שינוי כתובת המייל בחשבון שלך:</p>';
        label := 'אישור הכתובת';
      when 'reauthentication' then
        subj := 'קוד אימות — חיים דרך מספרים';
        out := out || jsonb_build_array(jsonb_build_object(
          'to', who, 'subject', subj,
          'html', '<div dir="rtl" style="font-family:Arial,sans-serif;font-size:16px;line-height:1.6"><p>קוד האימות שלך:</p><p style="font-size:24px;letter-spacing:4px"><b>'
                  || public.hdm_mail_esc(d->>'token') || '</b></p><p>' || tail || '</p>' || foot || '</div>',
          'text', 'קוד האימות שלך: ' || coalesce(d->>'token', '') || E'\n' || tail));
        continue;
      else
        subj := 'הודעה מ"חיים דרך מספרים"';
        intro := '<p>שלום,</p>';
        label := 'המשך';
    end case;
    out := out || jsonb_build_array(jsonb_build_object(
      'to', who, 'subject', subj,
      'html', '<div dir="rtl" style="font-family:Arial,sans-serif;font-size:16px;line-height:1.6">' || intro
              || '<p><a href="' || public.hdm_mail_esc(link) || '" style="' || btn || '">' || label || '</a></p>'
              || '<p>' || tail || '</p>' || foot || '</div>',
      'text', regexp_replace(intro, '<[^>]+>', ' ', 'g') || E'\n' || label || ': ' || link || E'\n\n' || tail));
  end loop;
  return out;
end $$;

-- ה-Hook עצמו. Auth קורא לו בתור supabase_auth_admin.
-- אם הממסר לא מוגדר — מחזיר שגיאה, כדי שהמשתמש יראה "לא נשלח" ולא יחכה למייל שלא יגיע.
create function public.hdm_send_email_hook(event jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  msgs jsonb; relay text; k text; ids bigint[] := '{}'; i int; rid bigint;
  act text := coalesce(event->'email_data'->>'email_action_type', '?');
begin
  select decrypted_secret into relay from vault.decrypted_secrets where name = 'hdm_mail_relay_url' limit 1;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'hdm_mail_relay_key' limit 1;
  if coalesce(relay, '') !~ '^https://script\.google\.com/macros/s/[A-Za-z0-9_-]+/exec$' or length(coalesce(k, '')) < 32 then
    insert into public.hdm_mail_log (action, messages, status) values (act, 0, 'relay_not_configured');
    return jsonb_build_object('error', jsonb_build_object('http_code', 500, 'message', 'Email relay is not configured'));
  end if;
  msgs := public.hdm_mail_render(event);
  for i in 0 .. coalesce(jsonb_array_length(msgs), 0) - 1 loop
    select net.http_post(
      url := relay,
      body := (msgs->i) || jsonb_build_object('key', k),
      headers := '{"Content-Type":"application/json"}'::jsonb,
      timeout_milliseconds := 15000) into rid;
    ids := ids || rid;
  end loop;
  insert into public.hdm_mail_log (action, messages, request_ids, status)
    values (act, coalesce(jsonb_array_length(msgs), 0), ids, case when coalesce(jsonb_array_length(msgs), 0) = 0 then 'nothing_to_send' else 'queued' end);
  return '{}'::jsonb;
end $$;

-- הגדרה חד-פעמית (מנהל, SQL Editor): שומרת ב-Vault את כתובת הממסר ומפתח אקראי חדש,
-- ומחזירה את המפתח פעם אחת — מדביקים אותו בשורה KEY בסקריפט של Google. לא שולחים אותו בצ'אט.
create function public.hdm_mail_setup(p_relay_url text)
returns text language plpgsql security definer set search_path = '' as $$
declare k text := encode(extensions.gen_random_bytes(24), 'hex'); sid uuid;
begin
  p_relay_url := btrim(coalesce(p_relay_url, ''));
  if p_relay_url !~ '^https://script\.google\.com/macros/s/[A-Za-z0-9_-]+/exec$' then
    raise exception 'הכתובת צריכה להיות כתובת ה-Web app של Apps Script, שמתחילה ב-https://script.google.com/macros/s/ ומסתיימת ב-/exec';
  end if;
  select id into sid from vault.secrets where name = 'hdm_mail_relay_url';
  if sid is null then perform vault.create_secret(p_relay_url, 'hdm_mail_relay_url', 'Apps Script mail relay URL');
  else perform vault.update_secret(sid, p_relay_url); end if;
  sid := null;
  select id into sid from vault.secrets where name = 'hdm_mail_relay_key';
  if sid is null then perform vault.create_secret(k, 'hdm_mail_relay_key', 'Apps Script mail relay key');
  else perform vault.update_secret(sid, k); end if;
  return k;
end $$;

-- מצב המשלוחים האחרונים (מנהל, SQL Editor): סטטוס HTTP מהממסר. 302 = הגיע ל-Google והסקריפט רץ.
create function public.hdm_mail_status(p_limit int default 10)
returns table(created_at timestamptz, action text, messages int, status text, relay_http int[], relay_error text)
language sql stable security definer set search_path = '' as $$
  select l.created_at, l.action, l.messages, l.status,
         (select array_agg(r.status_code order by r.id) from net._http_response r where r.id = any(l.request_ids)),
         (select string_agg(r.error_msg, ' | ') from net._http_response r where r.id = any(l.request_ids) and r.error_msg is not null)
  from public.hdm_mail_log l order by l.id desc limit greatest(1, least(p_limit, 100))
$$;

revoke all on function public.hdm_mail_esc(text), public.hdm_mail_urlenc(text), public.hdm_mail_render(jsonb),
  public.hdm_send_email_hook(jsonb), public.hdm_mail_setup(text), public.hdm_mail_status(int), public.hdm_mail_auth_base()
  from public, anon, authenticated;
grant execute on function public.hdm_send_email_hook(jsonb) to supabase_auth_admin;
grant usage on schema public to supabase_auth_admin;

insert into public.hdm_release_marker (version, note) values ('production_mail_hook_v1', 'Send Email Hook → Apps Script → Gmail (12)');

commit;

select '✅ 12_production_mail_hook הותקן' as "סטטוס";
