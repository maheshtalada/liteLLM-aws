#!/usr/bin/env bash
# Create a per-user LiteLLM virtual key so usage/spend is tracked per person (and per team).
# Creates the team and user if they don't exist, adds the user to the team, then issues a key.
# Usage: ./new-key.sh <user_email> <team> [max_budget_usd]
#   e.g. ./new-key.sh priya@example.com platform 50
# The key is printed once — hand it to the user directly. The master key is never printed.
set -euo pipefail

USER_EMAIL="${1:?usage: ./new-key.sh <user_email> <team> [max_budget_usd]}"
TEAM="${2:?usage: ./new-key.sh <user_email> <team> [max_budget_usd]}"
BUDGET="${3:-}"

TF="terraform -chdir=$(dirname "$0")/terraform"
URL=$($TF output -raw gateway_url)
SECRET_NAME=$($TF output -raw master_key_secret_name)
REGION=$($TF output -raw ssm_shell | sed -E 's/.*--region ([^ ]+).*/\1/')
MASTER=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_NAME" \
  --query SecretString --output text)

# POST JSON to the admin API; the auth header is passed via a file descriptor so it never shows in `ps`.
# Prints the response body; returns non-zero on HTTP errors.
api() {
  curl -sS --fail-with-body -X POST "$URL$1" \
    -H @<(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$MASTER") \
    -d "$2"
}

# Team and user may already exist — that's fine, carry on.
api /team/new "$(jq -n --arg t "$TEAM" '{team_id:$t, team_alias:$t}')" >/dev/null 2>&1 \
  && echo "Created team $TEAM" || echo "Team $TEAM exists (or could not be created) — continuing"
api /user/new "$(jq -n --arg u "$USER_EMAIL" '{user_id:$u, user_email:$u, auto_create_key:false}')" >/dev/null 2>&1 \
  && echo "Created user $USER_EMAIL" || echo "User $USER_EMAIL exists (or could not be created) — continuing"
api /team/member_add "$(jq -n --arg t "$TEAM" --arg u "$USER_EMAIL" \
  '{team_id:$t, member:{role:"user", user_id:$u}}')" >/dev/null 2>&1 || true

KEY_REQ=$(jq -n --arg u "$USER_EMAIL" --arg t "$TEAM" --arg b "$BUDGET" \
  '{user_id:$u, team_id:$t, key_alias:"\($u)-\(now|floor)", metadata:{created_by:"new-key.sh"}}
   + (if $b == "" then {} else {max_budget:($b|tonumber)} end)')

KEY=$(api /key/generate "$KEY_REQ" | jq -r '.key')
unset MASTER

echo
echo "Key for $USER_EMAIL (team $TEAM${BUDGET:+, budget \$$BUDGET}) — shown once, send it privately:"
echo "  $KEY"
echo "Base URL: $URL"
