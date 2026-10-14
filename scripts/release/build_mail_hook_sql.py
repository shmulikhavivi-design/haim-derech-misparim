#!/usr/bin/env python3
# =====================================================================
# בונה את קובצי ההתקנה של משלוח המיילים (Send Email Hook → Apps Script → Gmail)
# מאותו גוף משותף (supabase/mail_hook/core.sql), כך ש-Staging ו-Production מריצים בדיוק אותו קוד.
#   python3 scripts/release/build_mail_hook_sql.py
#   → supabase/staging_secure/12_staging_mail_hook.sql
#   → supabase/production/12_production_mail_hook.sql   (לא להריץ בלי אישור)
# =====================================================================
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = (ROOT / 'supabase' / 'mail_hook' / 'core.sql').read_text(encoding='utf-8')
STAGING_REF = 'ousepgdvzammgkxkweze'
PRODUCTION_REF = 'qtspzigjlbtckqfyaubp'


def base_fn(ref):
    return f"""create function public.hdm_mail_auth_base()
returns text language sql immutable set search_path = '' as $$ select 'https://{ref}.supabase.co/auth/v1'::text $$;
"""


STAGING = f"""-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: משלוח מיילים דרך Gmail בלי SMTP (Send Email Hook)
-- נוצר אוטומטית מ-scripts/release/build_mail_hook_sql.py. "הכול או כלום". לא מוחק ולא משנה נתונים קיימים.
-- אחרי ההתקנה המיילים עדיין לא עוברים דרך ה-Hook: מפעילים אותו ב-Authentication ← Hooks (ראו docs/email-gmail-relay.md).
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_staging_marker where version = 'staging_mail_hook_v1') then
    raise exception 'עצירה: משלוח המיילים כבר הותקן. שום דבר לא שונה.';
  end if;
end $$;

{base_fn(STAGING_REF)}
{CORE}
insert into public.hdm_staging_marker (version, note) values ('staging_mail_hook_v1', 'Send Email Hook → Apps Script → Gmail (12)');

commit;

select '✅ 12_staging_mail_hook הותקן' as "סטטוס",
       (select count(*) from vault.decrypted_secrets where name like 'hdm_mail_relay_%') as "סודות ממסר ב-Vault (צריך 2 אחרי ההגדרה)";
"""

PRODUCTION = f"""-- =====================================================================
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

{base_fn(PRODUCTION_REF)}
{CORE}
insert into public.hdm_release_marker (version, note) values ('production_mail_hook_v1', 'Send Email Hook → Apps Script → Gmail (12)');

commit;

select '✅ 12_production_mail_hook הותקן' as "סטטוס";
"""

(ROOT / 'supabase' / 'staging_secure' / '12_staging_mail_hook.sql').write_text(STAGING, encoding='utf-8')
(ROOT / 'supabase' / 'production' / '12_production_mail_hook.sql').write_text(PRODUCTION, encoding='utf-8')
assert STAGING_REF not in PRODUCTION and PRODUCTION_REF not in STAGING
print('ok')
