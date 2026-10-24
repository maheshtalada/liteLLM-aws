#!/usr/bin/env bash
# Create gateway keys for students with the standard student policy — the short version of new-key.sh.
#
#   ./add-students.sh <team> <emails | file.csv | file.xlsx | Google Sheets URL> [extra new-key.sh options]
#
#   ./add-students.sh test-team test.student@example.com
#   ./add-students.sh class-a "priya@college.edu, arjun@college.edu"
#   ./add-students.sh class-a students.xlsx
#   ./add-students.sh class-a students.csv --dry-run          # preview only
#   ./add-students.sh class-a students.csv --budget 2         # override a default for this run
#
# Keys are written to keys/<team>-<time>.csv plus a ready-to-send message per student (never printed).
set -euo pipefail
cd "$(dirname "$0")"

# ---- Student policy (edit here to change it for everyone) ----
MODELS="lite,base"        # tiers students may use (no paid bedrock-*/claude-*, no complex)
BUDGET="1"                # USD of PAID fallback per student (free models count as $0)
BUDGET_RESET="30d"        # budget refills every 30 days
RPM="10"                  # requests per minute per student
EXPIRES="90d"             # key stops working after 90 days

if [ $# -lt 2 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
TEAM="$1"; INPUT="$2"; shift 2

# Sign in if needed and refuse the wrong AWS account (login.sh exports credentials for Terraform).
# shellcheck disable=SC1091
source ./login.sh >/dev/null || { echo "AWS sign-in/account check failed — run: source ./login.sh"; exit 1; }

case "$INPUT" in
  https://docs.google.com/spreadsheets/*) SRC=(--sheet "$INPUT") ;;
  *.csv|*.CSV|*.txt|*.xlsx|*.XLSX|*.xls)  SRC=(--file "$INPUT") ;;
  *@*)                                    SRC=(--emails "$INPUT") ;;
  *) echo "Not an email list, a .csv/.xlsx file or a Google Sheets URL: $INPUT"; exit 1 ;;
esac

# Defaults first; anything passed after the input (e.g. --budget 2) overrides them.
exec ./new-key.sh --team "$TEAM" "${SRC[@]}" \
  --models "$MODELS" --budget "$BUDGET" --budget-duration "$BUDGET_RESET" \
  --rpm "$RPM" --expires "$EXPIRES" "$@"
