-- =====================================================================
-- חיים דרך מספרים — תיקון: קליטת תוצאת חידוש בכרטיס שמור לפי החיוב שהשרת "תפס" (Staging בלבד).
--
-- הבאג (נמצא בבדיקה מקצה לקצה של Grow, 20.10.2026): hdm_billing_apply_grow_event מזהה חידוש לפי מזהה סדרת החיובים
-- של Grow (grow_direct_debit_id). בחידוש הראשון בכרטיס שמור עוד אין מזהה כזה, ולכן:
--   * כרטיס שנדחה בחידוש הראשון נרשם "unknown" במקום "failed" — המנוי לא סומן past_due ולא נוסה שוב;
--   * חידוש ראשון שאושר בלי ש-Grow החזירה מזהה סדרה — נרשם "unknown" ולא האריך את המנוי.
-- התיקון: hdm_billing_apply_card_renewal — מזהה את המנוי לפי החיוב (chargeId) בלבד. עוטף את
-- hdm_billing_apply_morning_renewal (24), שכבר בנויה ונבדקה כך (41 בדיקות). grow-renewals עובר להשתמש בה.
-- Staging: להריץ פעם אחת אחרי 24 ו-26. נעצר אם כבר הותקן. Production: לא רץ.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if to_regprocedure('public.hdm_billing_apply_morning_renewal(jsonb)') is null
     or to_regprocedure('public.hdm_billing_save_grow_card(text, text, text, text, text, text)') is null then
    raise exception 'עצירה: צריך קודם את 24 ו-26. שום דבר לא שונה.';
  end if;
  if to_regprocedure('public.hdm_billing_apply_card_renewal(jsonb)') is not null then
    raise exception 'עצירה: התיקון כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

-- p: { chargeId, transactionId, outcome: approved|failed, amountAgorot, raw? } — בטוח להפעלה חוזרת (עסקה נקלטת פעם אחת)
create function public.hdm_billing_apply_card_renewal(p jsonb)
returns jsonb language sql volatile security definer set search_path = '' as $$
  select public.hdm_billing_apply_morning_renewal(p)
$$;

revoke all on function public.hdm_billing_apply_card_renewal(jsonb) from public, anon, authenticated;
grant execute on function public.hdm_billing_apply_card_renewal(jsonb) to service_role;

insert into public.hdm_staging_marker (version, note)
values ('staging_billing_card_renewal_v1', 'תיקון: חידוש בכרטיס שמור מזוהה לפי החיוב, גם בלי מזהה סדרה של Grow');

commit;

select '✅ תיקון קליטת החידוש בכרטיס שמור הותקן (Staging)' as "סטטוס";
