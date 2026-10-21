#!/usr/bin/env bash
# Presence check only: prints which named secrets are non-empty, never their values.
# For Supabase-token-like secrets, also lists which known projects they can see (labels only).
set -u
SCOPE="$1"; PROD='qtspzigjlbtckqfyaubp'; STG='ousepgdvzammgkxkweze'; OUT=""
for n in $NAMES; do
  v="${!n:-}"
  [ -n "$v" ] || continue
  echo "::add-mask::$v"
  kind="set"
  case "$v" in sbp_*) kind="supabase-token";; postgres*://*) kind="db-url";; xsmtpsib-*) kind="brevo-smtp-key";; xkeysib-*) kind="brevo-api-key";; sb_secret_*|eyJ*) kind="supabase-api-key";; esac
  case "$v" in *"$PROD"*) kind="$kind(production)";; *"$STG"*) kind="$kind(staging)";; esac
  if [ "${kind%%(*}" = supabase-token ]; then
    P=$(curl -sS -m 20 -H "Authorization: Bearer $v" https://api.supabase.com/v1/projects | jq -r --arg p "$PROD" --arg s "$STG" '[.[].id] | map(if .==$p then "production" elif .==$s then "staging" else "other" end) | join("+")' 2>/dev/null || echo '?')
    kind="$kind sees:[${P:-none}]"
  fi
  OUT="$OUT $n=$kind;"
done
echo "::notice title=secrets-$SCOPE::${OUT:- (none of the checked names exist)}"
