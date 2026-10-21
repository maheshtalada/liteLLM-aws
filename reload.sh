#!/usr/bin/env bash
# Push config/compose changes and restart LiteLLM on the host — no SSH needed.
#   1. terraform apply  (uploads changed app/ files and bootstrap.env to S3)
#   2. SSM Run Command  (host re-syncs from S3, re-reads secrets, recreates the container)
# Usage: ./reload.sh            # apply + restart
#        ./reload.sh --no-apply # only restart (e.g. after ./set-secret.sh)
set -euo pipefail
# Terraform can't read `aws login` sessions directly — hand it the CLI's temporary credentials.
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || eval "$(aws configure export-credentials --format env)"
TF="terraform -chdir=$(dirname "$0")/terraform"

if [ "${1:-}" != "--no-apply" ]; then
  $TF apply
fi

INSTANCE_ID=$($TF output -raw instance_id)
REGION=$($TF output -raw ssm_shell | sed -E 's/.*--region ([^ ]+).*/\1/')

CMD_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "litellm reload" \
  --parameters 'commands=["bash /usr/local/bin/litellm-up"]' \
  --query 'Command.CommandId' --output text)

echo "Reloading LiteLLM on $INSTANCE_ID (command $CMD_ID)..."
aws ssm wait command-executed --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" || true

aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Errors:StandardErrorContent}' --output yaml
