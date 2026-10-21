-- =====================================================================
-- חיים דרך מספרים — גרסת תנאים חדשה עם פתיחת המנויים בתשלום (2026-10-21). להרצה רק ביום ההפעלה, באישור מפורש,
-- אחרי 08 ואחרי אישור משפטי של הנוסח. "שינוי מהותי": כל המשתמשים יתבקשו לאשר את התנאים המעודכנים בכניסה הבאה
-- (מסך האישור הקיים). לא משנה ולא מוחק משתמשים, פרופילים, שיחות, מנויים או אישורים קודמים. הרצה חוזרת נעצרת.
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_release_marker') is null or to_regclass('public.hdm_staging_marker') is not null then
    raise exception 'עצירה: זה לא מסד ה-Production. שום דבר לא שונה.';
  end if;
  if not exists (select 1 from public.hdm_release_marker where version = 'production_billing_v1') then
    raise exception 'עצירה: קודם 08 (מנויים בתשלום). שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_terms_versions where version = '2026-10-21') then
    raise exception 'עצירה: גרסת התנאים 2026-10-21 כבר קיימת. שום דבר לא שונה.';
  end if;
end $$;
create temp table hdm_pre on commit drop as
  select (select count(*) from public.hdm_consents) c, (select count(*) from public.docs) d, (select count(*) from auth.users) u;
insert into public.hdm_terms_versions (version, requires_reconsent, note)
values ('2026-10-21', true, 'פתיחת המנויים בתשלום: סעיף מנויים, חיובים, שדרוגים, חידושים וביטולים; מדיניות ביטול מנוי');
do $$ begin
  if public.hdm_required_terms_version() <> '2026-10-21' then raise exception 'עצירה: הגרסה הנדרשת לא עודכנה.'; end if;
  if (select c from hdm_pre) <> (select count(*) from public.hdm_consents) or (select d from hdm_pre) <> (select count(*) from public.docs)
     or (select u from hdm_pre) <> (select count(*) from auth.users) then raise exception 'עצירה: מספר הרשומות השתנה.'; end if;
end $$;
insert into public.hdm_release_marker (version, note) values ('production_terms_2026_10_21', 'תנאים מעודכנים עם פתיחת המנויים בתשלום — כולם מאשרים מחדש');
commit;
