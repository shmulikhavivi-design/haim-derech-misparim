# Read-only shape check of the stored SMTP username (value is never printed).
import json, re, sys
c = json.load(sys.stdin)
u = c.get("smtp_user") or ""; a = c.get("smtp_admin_email") or ""; t = u.strip()
loc = t.split("@")[0] if "@" in t else t
print(" ".join([
    f"brevo_login_shape={bool(re.fullmatch(r'[0-9a-f]{6,12}@smtp-brevo[.]com', t))}",
    f"matches_given_login={t == 'be5ab9001@smtp-brevo.com'}",
    f"user_len={len(u)}", f"lead_or_trail_space={u != t}", f"local_len={len(loc)}",
    f"local_hex={bool(re.fullmatch(r'[0-9a-f]+', loc))}", f"has_upper={t != t.lower()}",
    f"sender_is_app_box={a.strip().lower() == 'life.through.numbers333@gmail.com'}",
]))
