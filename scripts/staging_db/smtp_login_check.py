#!/usr/bin/env python3
# בדיקת התחברות ל-Gmail SMTP בלבד (בלי שליחת מייל). קורא HDM_U / HDM_P מהסביבה; לא מדפיס את הסיסמה.
import os, smtplib, ssl
u, p = os.environ.get("HDM_U", ""), os.environ.get("HDM_P", "")
c = p.replace(" ", "")
shape = f"len={len(p)} nospace_len={len(c)} spaces={p.count(' ')} masked={bool(p) and set(p) <= set('*•')} letters_only={c.isalpha()} lower={c.islower()}"
out = []
for label, pw in (("as-is", p), ("no-spaces", c)):
    try:
        s = smtplib.SMTP_SSL("smtp.gmail.com", 465, context=ssl.create_default_context(), timeout=20)
        s.login(u, pw); s.quit(); out.append(label + ": 235 login OK")
    except smtplib.SMTPAuthenticationError as e:
        out.append(f"{label}: {e.smtp_code} " + e.smtp_error.decode(errors="ignore").split("\n")[0][:90])
    except Exception as e:
        out.append(f"{label}: {type(e).__name__}")
    if pw == c:
        break
print("צורת הסיסמה השמורה: " + shape + " ;; התחברות ל-Gmail: " + " | ".join(out))
