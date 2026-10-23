# shellcheck shell=bash
# Sign in to the LiteLLM project account and prepare this shell for Terraform and the README commands.
# Usage (must be sourced so the exports stay in your shell):
#   source ./login.sh
# - Reuses a valid `aws login` session; opens the browser only when it has expired.
# - Refuses to continue if you're signed in to any account other than the project account.
# - Exports AWS_REGION and the session credentials (for Terraform), plus URL and ID.
# Works in zsh and bash. Never prints secrets.

LITELLM_ACCOUNT="985040258825"     # Console Dot Dream (project account)
LITELLM_REGION="ap-south-1"

_litellm_login() {
  # Drop credentials exported by an earlier run so we test the real session, not stale env vars.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION AWS_PROFILE

  local account
  account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  if [ -z "$account" ]; then
    echo "AWS session missing or expired — opening the browser. Choose: Console Dot Dream ($LITELLM_ACCOUNT)"
    aws login --region "$LITELLM_REGION" || { echo "aws login failed"; return 1; }
    account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  fi

  if [ "$account" != "$LITELLM_ACCOUNT" ]; then
    echo "WRONG ACCOUNT: signed in to ${account:-nothing}, need $LITELLM_ACCOUNT (Console Dot Dream)."
    echo "Sign out of the AWS console in your browser (or use a private window), then: source ./login.sh"
    return 1
  fi

  aws configure set region "$LITELLM_REGION"
  export AWS_REGION="$LITELLM_REGION"
  eval "$(aws configure export-credentials --format env)" || { echo "could not export credentials"; return 1; }

  local dir
  dir=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  ID=$(terraform -chdir="$dir/terraform" output -raw instance_id 2>/dev/null)
  URL=$(terraform -chdir="$dir/terraform" output -raw gateway_url 2>/dev/null)
  export ID URL

  echo "OK: project account $account, region $AWS_REGION"
  [ -n "$ID" ] && echo "Instance $ID: $(aws ec2 describe-instances --instance-ids "$ID" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)"
  [ -n "$URL" ] && echo "Gateway  $URL"
  echo "Credentials expire at: ${AWS_CREDENTIAL_EXPIRATION:-unknown} — run 'source ./login.sh' again after that."
}

_litellm_login
