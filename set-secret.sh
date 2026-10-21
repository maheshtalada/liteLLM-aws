#!/usr/bin/env bash
# Store a provider API key in Secrets Manager without it touching shell history or Terraform state.
# Usage: ./set-secret.sh OPENAI_API_KEY
set -euo pipefail

KEY="${1:?usage: ./set-secret.sh <SECRET_NAME>  e.g. OPENAI_API_KEY}"
NAME="${NAME:-litellm}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

read -r -s -p "Value for ${NAME}/${KEY}: " VALUE
echo

aws secretsmanager put-secret-value \
  --region "$AWS_REGION" \
  --secret-id "${NAME}/${KEY}" \
  --secret-string "$VALUE" >/dev/null

echo "Saved ${NAME}/${KEY}. Run ./reload.sh to apply it."
