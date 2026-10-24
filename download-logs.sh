#!/usr/bin/env bash
# Download the daily request-log exports from S3 to this Mac, then remove them from S3.
#   ./download-logs.sh            -> logs/YYYY-MM-DD.jsonl.gz (git-ignored)
# The server exports each finished day at 00:30 UTC and keeps only the last 3 days in its database.
# Each line is one request as JSON: time, key, model, prompt (proxy_server_request), response, tokens, cost.
# Read one:   gzip -dc logs/2026-10-24.jsonl.gz | jq -r '[.startTime, .metadata.user_api_key_alias, .model, .spend] | @tsv'
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./login.sh >/dev/null || { echo "AWS sign-in/account check failed — run: source ./login.sh"; exit 1; }

BUCKET=$(terraform -chdir=terraform output -raw bundle_bucket)
umask 077                       # downloaded files contain prompts: readable only by you
mkdir -p logs
before=$(find logs -name '*.jsonl.gz' | wc -l | tr -d ' ')
# mv = copy each file, then delete it from S3 only after that file was copied successfully.
aws s3 mv "s3://$BUCKET/logs/" logs/ --recursive --exclude "*" --include "*.jsonl.gz" --only-show-errors
after=$(find logs -name '*.jsonl.gz' | wc -l | tr -d ' ')
echo "Downloaded $((after - before)) new day file(s) to $(pwd)/logs (removed from S3)."
for f in $(find logs -name '*.jsonl.gz' -newer logs/.last-download 2>/dev/null || find logs -name '*.jsonl.gz'); do
  printf '  %s  %s requests\n' "$(basename "$f")" "$(gzip -dc "$f" | grep -c . || true)"
done | sort
touch logs/.last-download
