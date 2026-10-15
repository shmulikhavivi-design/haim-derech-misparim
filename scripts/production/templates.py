# Builds the Supabase Auth PATCH body for the Hebrew email templates from docs/email-templates.md.
# Output: JSON object with mailer_subjects_* and mailer_templates_*_content fields.
import json, re, sys

doc = open(sys.argv[1], encoding="utf-8").read()
sections = {"Reset Password": "recovery", "Confirm signup": "confirmation", "Change Email Address": "email_change"}
out = {}
for title, key in sections.items():
    m = re.search(r"^## " + re.escape(title) + r".*?$(.*?)(?=^## |\Z)", doc, re.S | re.M)
    if not m:
        sys.exit(f"missing section: {title}")
    body = m.group(1)
    subj = re.search(r"\*\*Subject:\*\*\s*`([^`]+)`", body)
    html = re.search(r"```html\n(.*?)```", body, re.S)
    if not subj or not html or "{{ .ConfirmationURL }}" not in html.group(1):
        sys.exit(f"bad section: {title}")
    out[f"mailer_subjects_{key}"] = subj.group(1)
    out[f"mailer_templates_{key}_content"] = html.group(1).strip()
print(json.dumps(out, ensure_ascii=False))
