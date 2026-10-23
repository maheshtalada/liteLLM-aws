#!/usr/bin/env bash
# Create per-user LiteLLM virtual keys so usage/spend is tracked per person (and per team).
# For each person: creates the team and user if missing, adds the user to the team, issues a key.
#
# One person (key printed once on screen):
#   ./new-key.sh [options] <email> <team> [max_budget_usd]
#   ./new-key.sh priya@example.com platform 50
#
# Many people (keys written to a private file under keys/, never printed):
#   ./new-key.sh --team students --emails "a@x.edu, b@x.edu, c@x.edu" [options]
#   ./new-key.sh --team students --file students.csv  [options]    # CSV / TXT
#   ./new-key.sh --team students --file students.xlsx [options]    # Excel (first sheet)
#   ./new-key.sh --team students --sheet "<Google Sheets URL>" [options]
#     The sheet must be shared as "Anyone with the link: Viewer" (reads that tab as CSV).
#     For a private sheet: File → Download → .xlsx or .csv, then use --file.
#   File format: email in column A, optional per-person budget (USD) in column B; header rows are skipped.
#
# Options (applied to every key):
#   --budget USD            max spend per key (a usage cap on free models; real dollars on Bedrock)
#   --budget-duration DUR   reset the budget every DUR, e.g. 1d, 7d, 30d (default: never)
#   --rpm N                 requests per minute per key
#   --tpm N                 tokens per minute per key
#   --models a,b            model names the key may use, e.g. lite,base (default: all)
#   --expires DUR           key expires after DUR, e.g. 30d, 90d (default: never)
#   --dry-run               show what would be created; no API calls
#
# The master key is never printed. Run it yourself — it outputs live keys.
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

TEAM="" BUDGET="" BUDGET_DURATION="" RPM="" TPM="" MODELS="" EXPIRES="" EMAILS="" FILE="" SHEET="" DRY_RUN=0
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --team)            TEAM="$2"; shift 2 ;;
    --emails)          EMAILS="$2"; shift 2 ;;
    --file)            FILE="$2"; shift 2 ;;
    --sheet)           SHEET="$2"; shift 2 ;;
    --budget)          BUDGET="$2"; shift 2 ;;
    --budget-duration) BUDGET_DURATION="$2"; shift 2 ;;
    --rpm)             RPM="$2"; shift 2 ;;
    --tpm)             TPM="$2"; shift 2 ;;
    --models)          MODELS="$2"; shift 2 ;;
    --expires)         EXPIRES="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage 0 ;;
    --*)               echo "unknown option: $1"; usage ;;
    *)                 POSITIONAL+=("$1"); shift ;;
  esac
done

# Single-person form: <email> <team> [budget]
BATCH=1
if [ -z "$EMAILS" ] && [ -z "$FILE" ] && [ -z "$SHEET" ]; then
  [ "${#POSITIONAL[@]}" -ge 2 ] || usage
  BATCH=0
  EMAILS="${POSITIONAL[0]}"; TEAM="${POSITIONAL[1]}"; BUDGET="${POSITIONAL[2]:-$BUDGET}"
fi
[ -n "$TEAM" ] || { echo "--team is required"; usage; }

# ---------- Collect "email,budget" rows ----------
rows_from_file() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    *.xlsx)
      # Read the first worksheet's columns A and B with the Python standard library (no extra installs).
      python3 - "$1" <<'PY'
import sys, zipfile, re, xml.etree.ElementTree as ET
ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
z = zipfile.ZipFile(sys.argv[1])
shared = []
if "xl/sharedStrings.xml" in z.namelist():
    for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", ns):
        shared.append("".join(t.text or "" for t in si.iter("{%s}t" % ns["m"])))
sheets = sorted(n for n in z.namelist() if re.match(r"xl/worksheets/sheet\d+\.xml$", n))
sheet = ET.fromstring(z.read(sheets[0]))
for row in sheet.iter("{%s}row" % ns["m"]):
    cols = {}
    for c in row.findall("m:c", ns):
        col = re.sub(r"\d", "", c.get("r", ""))
        t, v = c.get("t"), c.find("m:v", ns)
        if t == "s" and v is not None:      val = shared[int(v.text)]
        elif t == "inlineStr":              val = "".join(x.text or "" for x in c.iter("{%s}t" % ns["m"]))
        else:                               val = v.text if v is not None else ""
        cols[col] = (val or "").strip()
    print("%s,%s" % (cols.get("A", ""), cols.get("B", "")))
PY
      ;;
    *.xls) echo "Old .xls isn't supported — in Excel use File → Save As → CSV (or .xlsx)." >&2; return 1 ;;
    *)     tr -d '\r' < "$1" | tr ';\t' ',,' ;;
  esac
}

# Google Sheets: turn a normal sheet URL into its CSV export URL (keeps the tab given by #gid=).
rows_from_sheet() {
  local id gid csv
  id=$(echo "$1" | sed -nE 's#.*/spreadsheets/d/([A-Za-z0-9_-]+).*#\1#p')
  [ -n "$id" ] || { echo "Not a Google Sheets URL: $1" >&2; return 1; }
  gid=$(echo "$1" | sed -nE 's#.*[#&?]gid=([0-9]+).*#\1#p')
  csv=$(curl -sSL --fail "https://docs.google.com/spreadsheets/d/$id/export?format=csv${gid:+&gid=$gid}" 2>/dev/null) \
    && ! echo "$csv" | grep -qi '<html' \
    || { echo "Couldn't read the sheet. Share it as 'Anyone with the link: Viewer', or download it (.xlsx/.csv) and use --file." >&2; return 1; }
  echo "$csv" | tr -d '\r'
}

ROWS=$(
  if [ -n "$SHEET" ]; then
    rows_from_sheet "$SHEET"
  elif [ -n "$FILE" ]; then
    [ -f "$FILE" ] || { echo "file not found: $FILE" >&2; exit 1; }
    rows_from_file "$FILE"
  else
    echo "$EMAILS" | tr ',; \t' '\n\n\n\n'
  fi | while IFS=, read -r email budget _rest; do
    email=$(echo "$email" | tr -d ' "' | tr '[:upper:]' '[:lower:]')
    budget=$(echo "${budget:-}" | tr -d ' "$')
    echo "$email" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' || continue   # skips headers/blank lines
    echo "$budget" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || budget=""
    echo "$email,$budget"
  done | awk -F, '!seen[$1]++'
)
COUNT=$(printf '%s\n' "$ROWS" | grep -c . || true)
[ "$COUNT" -gt 0 ] || { echo "No valid email addresses found."; exit 1; }

echo "Team: $TEAM · people: $COUNT · models: ${MODELS:-all} · budget: ${BUDGET:-none}${BUDGET_DURATION:+ per $BUDGET_DURATION}" \
     "· rpm: ${RPM:-none} · tpm: ${TPM:-none} · expires: ${EXPIRES:-never}"
if [ "$DRY_RUN" = 1 ]; then
  printf '%s\n' "$ROWS" | while IFS=, read -r email budget; do
    echo "  would create: $email  (budget: ${budget:-${BUDGET:-none}})"
  done
  exit 0
fi

# ---------- Connect to the gateway ----------
# Terraform can't read `aws login` sessions directly — hand it the CLI's temporary credentials.
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || eval "$(aws configure export-credentials --format env)"
TF="terraform -chdir=terraform"
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

# Team may already exist — that's fine, carry on.
api /team/new "$(jq -n --arg t "$TEAM" '{team_id:$t, team_alias:$t}')" >/dev/null 2>&1 \
  && echo "Created team $TEAM" || echo "Team $TEAM exists — continuing"

# Batch output: private files (git-ignored keys/ directory, readable only by you).
if [ "$BATCH" = 1 ]; then
  umask 077
  mkdir -p keys
  STAMP=$(date +%Y%m%d-%H%M%S)
  OUT_CSV="keys/$TEAM-$STAMP.csv"
  OUT_TXT="keys/$TEAM-$STAMP-messages.txt"
  echo "email,key_alias,key,models,budget_usd,budget_reset,rpm,expires" > "$OUT_CSV"
  : > "$OUT_TXT"
fi

OK=0 FAILED=0
while IFS=, read -r email budget; do
  budget="${budget:-$BUDGET}"
  alias="$TEAM-${email%@*}-$(date +%s)"

  api /user/new "$(jq -n --arg u "$email" '{user_id:$u, user_email:$u, auto_create_key:false}')" >/dev/null 2>&1 || true
  api /team/member_add "$(jq -n --arg t "$TEAM" --arg u "$email" \
    '{team_id:$t, member:{role:"user", user_id:$u}}')" >/dev/null 2>&1 || true

  req=$(jq -n --arg u "$email" --arg t "$TEAM" --arg a "$alias" --arg b "$budget" --arg bd "$BUDGET_DURATION" \
              --arg rpm "$RPM" --arg tpm "$TPM" --arg m "$MODELS" --arg exp "$EXPIRES" '
    {user_id:$u, team_id:$t, key_alias:$a, metadata:{created_by:"new-key.sh"}}
    + (if $b   == "" then {} else {max_budget:($b|tonumber)} end)
    + (if $bd  == "" then {} else {budget_duration:$bd} end)
    + (if $rpm == "" then {} else {rpm_limit:($rpm|tonumber)} end)
    + (if $tpm == "" then {} else {tpm_limit:($tpm|tonumber)} end)
    + (if $m   == "" then {} else {models:($m|split(",")|map(gsub("^ +| +$";"")))} end)
    + (if $exp == "" then {} else {duration:$exp} end)')

  if ! resp=$(api /key/generate "$req" 2>&1) || ! key=$(echo "$resp" | jq -er '.key' 2>/dev/null); then
    echo "  FAILED  $email: $(echo "$resp" | jq -r '.error.message // .detail // .' 2>/dev/null | head -c 200)"
    FAILED=$((FAILED + 1)); continue
  fi
  OK=$((OK + 1))

  if [ "$BATCH" = 0 ]; then
    echo
    echo "Key for $email (team $TEAM${budget:+, budget \$$budget}) — shown once, send it privately:"
    echo "  $key"
    echo "Base URL: $URL"
  else
    echo "  created $email"
    printf '%s,%s,%s,"%s",%s,%s,%s,%s\n' "$email" "$alias" "$key" "${MODELS:-all}" "${budget:-}" \
      "${BUDGET_DURATION:-}" "${RPM:-}" "${EXPIRES:-never}" >> "$OUT_CSV"
    cat >> "$OUT_TXT" <<MSG
==================== To: $email ====================
Hi! Here is your personal key for the course AI gateway. Please don't share it.

  Base URL : $URL
  API key  : $key
  Models   : ${MODELS:-all models on the gateway}${budget:+
  Budget   : \$$budget${BUDGET_DURATION:+ (resets every $BUDGET_DURATION)}}${EXPIRES:+
  Expires  : in $EXPIRES}

Setup (macOS/Linux terminal, or add to ~/.zshrc):
  export OPENAI_BASE_URL="$URL"
  export OPENAI_API_KEY="$key"

Python:
  from openai import OpenAI
  client = OpenAI()
  r = client.chat.completions.create(model="base", messages=[{"role": "user", "content": "Hello"}])
  print(r.choices[0].message.content)

Never commit this key to git or paste it into shared documents.

MSG
  fi
done <<< "$ROWS"
unset MASTER

echo
echo "Done: $OK created, $FAILED failed."
if [ "$BATCH" = 1 ] && [ "$OK" -gt 0 ]; then
  echo "Keys:     $OUT_CSV"
  echo "Messages: $OUT_TXT   (one ready-to-send message per person)"
  echo "Both files are private (chmod 600) and git-ignored. Delete them once the keys are sent."
fi
