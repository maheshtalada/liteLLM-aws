# LiteLLM gateway — full reference

Detailed reference for the gateway. For the short version, see the [README](../README.md).
Links inside this file point to sections of this file.

## Architecture

```
Users / apps (OpenAI SDK, curl, agents) — each with their own LiteLLM key
     │  HTTPS 443 → https://<ip-with-dashes>.sslip.io     (port 80 only redirects + renews the cert)
     ▼
┌───────────────── EC2 t4g.small (ARM, Amazon Linux 2023, Mumbai) ─────────────────┐
│ docker compose                                                                   │
│  ├─ caddy     :443  Let's Encrypt certificate, reverse proxy ─┐                  │
│  ├─ litellm   :4000 ◄──────────────────────────────────────────┘                  │
│  │     lite / base / complex ──► Gemini · Groq · OpenRouter · Z.AI GLM · Cohere │
│  ├─ postgres  users, teams, virtual keys, spend logs  (30 GB EBS, daily snapshots)│
│  └─ redis     router state, rate limits                                          │
└──────────────────────────────────────────────────────────────────────────────────┘
 Secrets Manager  litellm/LITELLM_MASTER_KEY, LITELLM_SALT_KEY, POSTGRES_PASSWORD, <PROVIDER>_API_KEY
 S3 (versioned)   app/config.yaml, docker-compose.yml, Caddyfile, bootstrap.env, bin/litellm-up
 CloudWatch Logs  /litellm/litellm (streams: litellm, caddy)
 Access           SSM Session Manager only. No SSH port, no key pair. Port 4000 open only to allowed_cidrs.
 Budget           AWS Budget "litellm-monthly" emails at 80% actual / 100% forecast of $25
```

How config reaches the host: `terraform apply` uploads `app/*` and the launcher to S3. On every
boot and every `./reload.sh`, the host runs `/usr/local/bin/litellm-up`, which:

1. syncs the files from S3,
2. writes `/opt/litellm/.env` from Secrets Manager (readable by root only),
3. runs `docker compose up`.

---

## Setup from scratch

These steps take you from an empty Mac to a working gateway, in about 30 minutes. Run every command
from the repo root.

### Step 1 — Install the tools (macOS)

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform awscli jq shellcheck gh
brew install --cask session-manager-plugin            # asks for your Mac password

terraform version                # ≥ 1.5
aws --version                    # aws-cli/2.x
session-manager-plugin --version
```

Docker is **not** needed on your Mac. It runs only on the EC2 instance.

### Step 2 — Get the code

```bash
gh repo clone maheshtalada/liteLLM-aws ~/aws-deployments/liteLLM     # private repo
cd ~/aws-deployments/liteLLM
chmod +x *.sh
```

### Step 3 — Sign in to AWS

**Shortcut (after the first deploy):** `source ./login.sh` does all of this in one command. It reuses
your session if it's still valid, opens the browser only when it has expired, refuses the wrong account,
and exports `AWS_REGION`, the Terraform credentials, `ID` and `URL`. It must be **sourced**, not run as
`./login.sh`, so the exports stay in your shell. No credentials are stored. The first time:

```bash
aws login --region ap-south-1          # opens the browser: choose the PROJECT account (see below)
aws configure set region ap-south-1
aws sts get-caller-identity --query '[Account,Arn]' --output text
```

**Pick the right account.** After advanced features are activated (below), the browser offers
several accounts. The gateway lives **only** in the project account:

| Account | ID | Use for |
|---|---|---|
| **Console Dot Dream** (project account) | **`985040258825`** | ✅ Everything in this README: Terraform, scripts, start/stop |
| Mahesh-Talada-Team Management Account | `275607988383` | Region policy (SCP), billing, budgets (console only) |
| Identity Delegated Admin | `899562467062` | IAM Identity Center admin; ❌ not for this repo |

If the check shows the wrong account, sign out of the AWS console in your browser (or use a private
window) and run `aws login` again. The CLI reuses whichever console session the browser has.

**One-line check.** Run it before any command that changes something:

```bash
[ "$(aws sts get-caller-identity --query Account --output text)" = 985040258825 ] && echo "OK: project account" || echo "WRONG ACCOUNT: run aws login again and pick Console Dot Dream"
```

Other accounts don't have the instance, so commands fail with errors like `InvalidInstanceID.NotFound`
or `ResourceNotFoundException`. Worse, Terraform would try to create a second copy of everything there.

**Accounts from AWS's new sign-up experience (Builder ID / "Projects" in AWS Settings):** AWS
assigns India-based projects to **Sydney** and blocks every other Region with a policy it manages.
If `aws ec2 describe-vpcs --region ap-south-1` returns `UnauthorizedOperation ... explicit deny in a
service control policy`, do this once:

1. In **AWS Settings → Projects → Actions**, choose **Explore advanced features** and activate them.
   - Activation is **irreversible** and removes the account's spend limit.
   - The management account email must be new to AWS. A Gmail alias like `you+aws-mgmt@gmail.com` works.
2. In **AWS Settings → management account → Manage Region policy**, edit
   `AdvancedModeRegionRestrictionSecurityControlPolicy`. Add `"ap-south-1"` to **every**
   `aws:RequestedRegion` list in it, and keep `unspecified`, `us-east-1` and `us-west-2`.
3. Save, wait a minute, then run `aws ec2 describe-vpcs --region ap-south-1` again. It should print VPCs.

### Step 4 — Configure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
curl -s https://checkip.amazonaws.com            # your public IP, for allowed_cidrs
```

Edit `terraform/terraform.tfvars`. This file is git-ignored. These are the values in use:

| Variable | Value | Meaning |
|---|---|---|
| `region` | `"ap-south-1"` | Mumbai |
| `litellm_tag` | `"v1.106.1"` | Exact LiteLLM image tag ([releases](https://github.com/BerriAI/litellm/releases)). Never `latest`. |
| `allowed_cidrs` | `["<your-ip>/32"]` | Who can reach plain HTTP `:4000` directly (admin and debugging) |
| `public_https` | `true` | Run Caddy and serve `https://<ip-with-dashes>.sslip.io` on 443 to everyone |
| `public_hostname` | `""` | Optional: your own domain name instead of sslip.io (point an A record at the IP first) |
| `instance_type` | `"t4g.small"` | 2 vCPU ARM with 2 GiB RAM, Free Tier eligible. Use `t4g.medium` for about 30 active users. |
| `root_volume_gb` | `30` | Disk size. The Free Tier covers 30 GB. |
| `provider_secret_names` | `["GEMINI_API_KEY", "GROQ_API_KEY", "OPENROUTER_API_KEY", "ZAI_API_KEY", "COHERE_API_KEY"]` | One secret is created per provider |
| `monthly_budget_usd` / `budget_alert_email` | `25` / your email | Cost alert email |
| `azure_api_base` | `""` | Azure is not used |

Optional: edit `app/config.yaml` to change which models are in each tier.

### Step 5 — Deploy

```bash
eval "$(aws configure export-credentials --format env)"   # Terraform can't read `aws login` sessions directly
terraform -chdir=terraform init
terraform -chdir=terraform plan        # review: about 43 resources, all new
terraform -chdir=terraform apply       # about 2 minutes
terraform -chdir=terraform output      # gateway_url, instance_id, ssm_shell, ...
```

The instance then needs **about 6 minutes on first boot** to install Docker, pull the images and
start LiteLLM. Wait until this prints `"I'm alive!"`:

```bash
curl -s $(terraform -chdir=terraform output -raw gateway_url)/health/liveliness
```

On a **brand-new** instance, the Elastic IP can attach after the first boot has already started.
If HTTPS doesn't come up, run `./reload.sh --no-apply` once. That rebuilds the sslip.io hostname
from the final IP.

### Step 6 — Add provider API keys

Get a free key from each provider, then store it. The script prompts for the key with hidden input.
**Never paste keys into chat, git, or a terminal command line.**

| Provider | Get a key | Free-tier notes |
|---|---|---|
| Google Gemini | https://aistudio.google.com/apikey | Covers all three tiers by itself; daily limits per project |
| Groq | https://console.groq.com/keys | About 1,000 requests a day per model |
| OpenRouter | https://openrouter.ai/settings/keys | `:free` models only; list changes weekly |
| Z.AI (GLM) | https://z.ai → API keys | GLM-4.5/4.7-Flash are free |
| Cohere | https://dashboard.cohere.com/api-keys | Trial key: 1,000 calls a month |

```bash
./set-secret.sh GEMINI_API_KEY
./set-secret.sh GROQ_API_KEY
./set-secret.sh OPENROUTER_API_KEY
./set-secret.sh ZAI_API_KEY
./set-secret.sh COHERE_API_KEY
./reload.sh --no-apply          # the host re-reads the secrets and restarts LiteLLM (about 30 s)
```

You can skip providers. LiteLLM sends each request to the deployments that work, so Gemini alone
is enough to start.

### Step 7 — Verify

Run the [shell setup](#shell-setup-once-per-terminal) first, then:

```bash
curl -sS $URL/health/liveliness                                            # "I'm alive!"
curl -sS $URL/v1/models -H "Authorization: Bearer $MASTER" | jq -r '.data[].id'   # base, complex, lite

for tier in lite base complex; do
  echo "== $tier"
  curl -sS $URL/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
    -d "{\"model\":\"$tier\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: ping\"}]}" \
    | jq -r '.model, (.choices[0].message.content // .error.message)'
done
```

For each tier, the first line printed is the deployment that answered. LiteLLM picks one at random.

**Admin UI:** open `$URL/ui` in a browser and log in with username `admin` and the master key as the
password. To copy the master key to the clipboard without showing it: `printf %s "$MASTER" | pbcopy`.

### Step 8 — Give people access and use it

Create a key per person (see [Per-user keys](#per-user-keys)):

```bash
./new-key.sh priya@example.com platform 10      # email, team, optional USD budget
```

Users then point any OpenAI-compatible client at the gateway:

```python
from openai import OpenAI
client = OpenAI(base_url="https://3-111-59-142.sslip.io", api_key="sk-...their key...")
r = client.chat.completions.create(model="base", messages=[{"role": "user", "content": "Hello"}])
print(r.choices[0].message.content)
```

```bash
curl https://3-111-59-142.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $THEIR_KEY" -H "Content-Type: application/json" \
  -d '{"model":"lite","messages":[{"role":"user","content":"Hello"}],"stream":true}'
```

---

## Shell setup (once per terminal)

Most commands below assume these variables. `MASTER` is read without being printed. Never `echo` it.

```bash
cd ~/aws-deployments/liteLLM
source ./login.sh          # sign in if needed, check account, export AWS_REGION + credentials + ID + URL
MASTER=$(aws secretsmanager get-secret-value --secret-id "$(terraform -chdir=terraform output -raw master_key_secret_name)" \
  --query SecretString --output text)
```

`aws login` sessions expire (`login.sh` prints when). If a command says `Your session has expired`
or `ExpiredToken`, run this block again.

<details><summary>Same thing without login.sh</summary>

```bash
aws login --region ap-south-1                               # pick Console Dot Dream
[ "$(aws sts get-caller-identity --query Account --output text)" = 985040258825 ] && echo "OK: project account" || echo "WRONG ACCOUNT: run aws login again and pick Console Dot Dream"
eval "$(aws configure export-credentials --format env)"     # aws login session → env vars for Terraform
export AWS_REGION=ap-south-1
URL=$(terraform -chdir=terraform output -raw gateway_url)
ID=$(terraform -chdir=terraform output -raw instance_id)
```
</details>

`reload.sh` and `new-key.sh` export the credentials themselves.

---

## Model tiers

Clients send `"model": "lite"`, `"base"` or `"complex"`. Each name load-balances across every free
deployment in that tier. When a deployment fails twice, it cools down for 60 s. Fallbacks:
`lite → base`, `base → lite → complex`, `complex → base`.

**Current (2026-10-23): Gemini only.** Only `GEMINI_API_KEY` is stored, so the free tiers use:
`lite` = gemini-3.5-flash-lite, gemini-3.1-flash-lite; `base` = gemini-3.6-flash, gemini-3.5-flash;
`complex` = gemini-3.6-flash, gemini-3-flash-preview. All are healthy and answered at $0.

Not used: gemini-3.8-flash and 3.7-flash hang for more than 60 s; gemini-2.5-pro and 2.5-flash return "no
longer available to new users"; gemini-pro-latest returns 429 (not on the free tier). The other providers'
entries are commented out in `app/config.yaml`. Uncomment them after `./set-secret.sh <KEY>`, then run
`./reload.sh`. The table below is the full design once all providers have keys.

To list the Gemini models your key can call (this runs on the host, so the key isn't printed):
`aws ssm send-command --instance-ids $ID --document-name AWS-RunShellScript --parameters '{"commands":["set -a; . /opt/litellm/.env; set +a; curl -s -H \"x-goog-api-key: $GEMINI_API_KEY\" https://generativelanguage.googleapis.com/v1beta/models | jq -r .models[].name"]}'`

| Tier | Use for | Deployments (`app/config.yaml`) |
|---|---|---|
| `lite` | classification, extraction, short answers | Gemini 3.5 Flash-Lite, Groq gpt-oss-20b, GLM-4.5-Flash, Nemotron 3.5 Lightning |
| `base` | general chat and writing (the default) | Gemini 3.8 Flash, Groq gpt-oss-120b, Qwen 3.8 27B, GLM-4.7-Flash, MiniMax M3.1 Flash, Gemma 4 31B |
| `complex` | reasoning, coding, long documents | Gemini 2.5 Pro, Nemotron 3 Ultra, Inkling, Laguna S 2.1, Cohere Command A |

### Paid fallback when free quota runs out

Free deployments carry `input_cost_per_token: 0` / `output_cost_per_token: 0`, so they never count
against budgets. Router fallbacks: `lite → base → lite-paid`, `base → lite → complex → base-paid`,
`complex → base → complex-paid`. The paid groups also fall back to each other.

| Group | Deployments |
|---|---|
| `lite-paid` | `bedrock/apac.amazon.nova-lite-v1:0`, `openrouter/qwen/qwen3.7-flash` |
| `base-paid` | `bedrock/apac.amazon.nova-pro-v1:0`, `bedrock/deepseek.v3.2`, `openrouter/deepseek/deepseek-v4.1-flash` |
| `complex-paid` | `bedrock/qwen.qwen3-coder-480b-a35b-v1:0`, `bedrock/in.moonshotai.kimi-k3`, `openrouter/qwen/qwen3.7-plus` |

- A key's `models` list (e.g. `lite,base`) does **not** block these fallbacks, and the paid cost is charged
  to that key's budget.
- **Tested on 2026-10-23** with a key restricted to `lite,base` and a $0.05 budget. Requesting `base`
  (free providers had no keys yet) returned HTTP 200 from `apac.amazon.nova-lite-v1:0` via group
  `lite-paid`, with `x-litellm-attempted-fallbacks: 1`. It used 13 + 2 tokens, cost $0.000001323, and
  `/key/info` showed spend 0.000001323.
- Response headers that help when debugging: `x-litellm-model-group`, `x-litellm-attempted-fallbacks`,
  `x-litellm-response-cost`.

### Response cache

`litellm_settings.cache` in `app/config.yaml` stores responses in the Redis container for 1 hour
(`ttl: 3600`). The cache key is the model name + messages + parameters, so only identical requests hit
it. Redis runs memory-only, capped at 128 MB with `allkeys-lru` eviction (`app/docker-compose.yml`).
Clients bypass it per request with `extra_body={"cache": {"no-cache": True}}`. A cache hit returns an
`x-litellm-cache-key` response header. Tested on 2026-10-23: a repeated request took 0.17 s instead of
1.5 s. To turn it off, set `cache: false`, then run `./reload.sh`.

### Paid models: Amazon Bedrock

These are used only when a client asks for one of these names; the free tiers never fall back to
them. There's no API key: the EC2 instance role calls Bedrock (`bedrock:InvokeModel*` in
`terraform/main.tf`). They're billed per token on your AWS bill, and LiteLLM records the cost per key,
so key budgets are real dollar limits here. Fallbacks: `bedrock-lite ↔ bedrock-base`,
`bedrock-complex → bedrock-base`.

| Name | Deployments | Inference ID (data location) |
|---|---|---|
| `bedrock-lite` | Amazon Nova Lite, Claude Haiku 4.5 | `apac.amazon.nova-lite-v1:0` (APAC), `in.anthropic.claude-haiku-4-5-20251001-v1:0` (India) |
| `bedrock-base` | Claude Sonnet 4.6, Nova Pro, DeepSeek V3.2 | `global.anthropic.claude-sonnet-4-6` (global), `apac.amazon.nova-pro-v1:0`, `deepseek.v3.2` (Mumbai) |
| `bedrock-complex` | Claude Opus 4.5, Qwen3 Coder 480B, Kimi K3 | `global.anthropic.claude-opus-4-5-20251101-v1:0`, `qwen.qwen3-coder-480b-a35b-v1:0` (Mumbai), `in.moonshotai.kimi-k3` (India) |
| `claude-haiku-4-5` / `claude-sonnet-4-6` / `claude-opus-4-5` | that exact Claude model | as above |

Find what your account can call, and test one model (about 5 tokens):

```bash
aws bedrock list-inference-profiles --query 'inferenceProfileSummaries[].inferenceProfileId'
aws bedrock list-foundation-models --by-inference-type ON_DEMAND --query 'modelSummaries[].modelId'
aws bedrock-runtime converse --model-id in.anthropic.claude-haiku-4-5-20251001-v1:0 \
  --messages '[{"role":"user","content":[{"text":"Say OK"}]}]' --inference-config '{"maxTokens":5}'
```

**Claude needs a one-time form:** `Model use case details have not been submitted for this account`
means you must open the Bedrock console (Mumbai), go to **Model catalog**, open any Anthropic Claude
model and submit the use-case details. It takes effect in about 15 minutes. Until then, `bedrock-*`
requests that land on Claude fall back to Nova or DeepSeek, and `claude-*` names fail.

`AccessDeniedException ... is not available for this account` means AWS hasn't enabled that model for
your account yet. As of 2026-10-23 this applies to Claude Sonnet/Opus 5.x, Haiku 5.5, Opus 4.8,
GPT-5.x and GLM-5.3. Request access from the Bedrock console or AWS Support, then add the model to
`app/config.yaml` and run `./reload.sh`.

Free tiers are rate-limited and **shared by every user of the gateway**, and providers may use the
prompts for training. Don't send confidential data. Free model lists change often; the links to
check are at the top of `app/config.yaml`. To add Bedrock or paid providers later, add entries to
`app/config.yaml` and their key names to `provider_secret_names`. See
[Day-2 operations](#day-2-operations).

---

## Per-user keys

Every person gets their own virtual key. Spend, tokens and requests are recorded in Postgres per
key, per user and per team. You can see them in the UI under **Usage**.

```bash
./new-key.sh priya@example.com platform 10   # email, team, optional USD budget for that key
./new-key.sh arjun@example.com data          # no budget cap
```

The script creates the team and the user if they don't exist, adds the user to the team, and prints
the new key **once**. Send it to the person privately.

**Many people at once** (`--emails "a,b,c"`, `--file list.csv`, `--file list.xlsx` or `--sheet <Google Sheets URL>`), with limits applied
to every key:

```bash
./new-key.sh --team students --file students.xlsx \
  --models lite,base --budget 2 --budget-duration 1d --rpm 10 --tpm 20000 --expires 90d
```

| Option | LiteLLM key field | Example |
|---|---|---|
| `--models a,b` | `models` | `lite,base` |
| `--budget USD` | `max_budget` | `2` |
| `--budget-duration` | `budget_duration` | `1d`, `7d`, `30d` |
| `--rpm` / `--tpm` | `rpm_limit` / `tpm_limit` | `10` / `20000` |
| `--expires` | `duration` | `90d` |
| `--dry-run` | — | parse the input and show what would be created |

- **Input file:** column A is the email; column B is an optional per-person budget. Headers, blanks,
  invalid entries and duplicates are skipped. `.xlsx` is read with the Python standard library (first
  sheet), so nothing extra needs installing.
- **Google Sheets:** `--sheet <url>` downloads `…/export?format=csv&gid=<tab>`. It works only for sheets
  shared as "Anyone with the link: Viewer". For a private sheet, download it as .xlsx/.csv and use
  `--file`. Reading private sheets directly would need Google OAuth, which this script doesn't do.
- **Output:** batch mode never prints keys. It writes `keys/<team>-<time>.csv` and
  `keys/<team>-<time>-messages.txt` (chmod 600; `keys/` is git-ignored). Send each person their own
  message, then delete the files.
- **Tested:** on 2026-10-23, a key restricted to `lite,base` listed only those models, and a request for
  `bedrock-lite` was refused with `not available for this API key`.

After the [shell setup](#shell-setup-once-per-terminal):

```bash
curl -sS "$URL/user/info?user_id=priya@example.com" -H "Authorization: Bearer $MASTER" | jq '.user_info.spend'
curl -sS "$URL/team/info?team_id=platform"         -H "Authorization: Bearer $MASTER" | jq '.team_info.spend'
curl -sS -X POST $URL/key/delete -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"key_aliases":["<key alias shown in the UI>"]}'                      # revoke a key
```

Never hand out the master key. It can do everything, including creating and deleting keys.

---

## What's in the AWS console

Sign in through AWS Settings (or `aws login`) and open the **project account, Console Dot Dream
(`985040258825`)**. The management and Identity Delegated Admin accounts don't contain these resources. Set the Region
selector (top-right) to **Asia Pacific (Mumbai)**.

**Everything at once:** **Resource Groups & Tag Editor → Tag Editor**. Choose Region `ap-south-1`
and resource types `All supported resource types`, add tag `Project` = `litellm`, then
**Search resources**. All resources created by this repo carry the tags `Project=litellm` and
`ManagedBy=terraform`.

| Service | Console location | What's there |
|---|---|---|
| **EC2** | EC2 → Instances → `litellm` | The server (t4g.small). Also the Monitoring tab and the Status checks. |
| EC2 · Elastic IP | EC2 → Network & Security → Elastic IPs | `3.111.59.142` |
| EC2 · Security group | EC2 → Security Groups → `litellm-instance` | Inbound rules: 443 and 80 open to everyone; 4000 open to your IP |
| EC2 · EBS volume | EC2 → Elastic Block Store → Volumes (`litellm-root`) and Snapshots | 30 GB disk; daily snapshots tagged `Backup=litellm` |
| **Systems Manager** | Systems Manager → Fleet Manager / Session Manager / Run Command | Browser shell on the server; history of `reload.sh` runs |
| **Secrets Manager** | Secrets Manager → Secrets → `litellm/...` | Master key, salt key, Postgres password, provider keys |
| **S3** | S3 → `litellm-bundle-...` | Config bundle (versioned) |
| **CloudWatch** | CloudWatch → Logs → Log groups → `/litellm/litellm` | Logs from the `litellm` and `caddy` containers |
| **IAM** (global) | IAM → Roles → `litellm-instance`, `litellm-dlm` | Instance permissions (read its secrets and bucket, SSM, logs) |
| **Data Lifecycle Manager** | EC2 → Elastic Block Store → Lifecycle Manager | Daily snapshot policy; 7 are kept |
| **Budgets** (global) | Billing and Cost Management → Budgets → `litellm-monthly` | $25/month alert |
| **Costs** | Billing and Cost Management → Cost Explorer (group by Service) | What you're actually paying for |

The same list from the CLI:

```bash
aws resourcegroupstaggingapi get-resources --region ap-south-1 --tag-filters Key=Project,Values=litellm \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n'
```

---

## Start and stop the server

Stop the instance when nobody is using it (overnight, weekends) to save about 60% of the cost.
Starting and stopping are **AWS CLI** commands, not Terraform. Terraform defines *what exists*
(instance, disk, IP, secrets), while start and stop only switch the existing server on or off.
A stopped instance doesn't confuse Terraform: a later `plan` won't start it or recreate it.

```bash
source ./login.sh                      # signs in if needed, checks the account, sets $ID
```

| Task | Command |
|---|---|
| Check state | `aws ec2 describe-instances --region ap-south-1 --instance-ids $ID --query 'Reservations[0].Instances[0].State.Name' --output text` |
| **Start** | `aws ec2 start-instances --region ap-south-1 --instance-ids $ID` |
| Wait until running | `aws ec2 wait instance-running --region ap-south-1 --instance-ids $ID` |
| **Stop** | `aws ec2 stop-instances --region ap-south-1 --instance-ids $ID` |
| Wait until stopped | `aws ec2 wait instance-stopped --region ap-south-1 --instance-ids $ID` |

After a **start**, LiteLLM and Caddy come up on their own (systemd runs `litellm-up` on boot) in about
1–2 minutes. Check:

```bash
curl -s https://3-111-59-142.sslip.io/health/liveliness      # "I'm alive!"
```

**In the console:** set the Region to Mumbai, then **EC2 → Instances → `litellm` → Instance state →
Start instance / Stop instance**.

**What survives a stop:** the Elastic IP (so the URL and HTTPS certificate stay the same) and the
disk (database, users, keys, config).

**Cost while stopped:** about $0.25/day for the disk and IP, compared with about $0.60/day running.

| What | Tool |
|---|---|
| Start / stop / check the server | AWS CLI (`aws ec2 ...`) or the EC2 console |
| Create, change or delete infrastructure | Terraform (`terraform -chdir=terraform plan / apply / destroy`) |
| Restart LiteLLM after a config or key change | `./reload.sh` / `./reload.sh --no-apply` (needs the server running) |

## Day-2 operations

Run the [shell setup](#shell-setup-once-per-terminal) first.

| Task | Command |
|---|---|
| Add or change models | Edit `app/config.yaml`, then `./reload.sh` (runs `terraform apply` and restarts) |
| Add a new provider | Add its key name to `provider_secret_names`, then `./reload.sh`, then `./set-secret.sh <KEY>`, then `./reload.sh --no-apply` |
| Rotate a provider key | `./set-secret.sh <KEY>`, then `./reload.sh --no-apply` |
| Upgrade LiteLLM | Change `litellm_tag`, then `./reload.sh` |
| Restart LiteLLM only | `./reload.sh --no-apply` |
| Shell on the host | `aws ssm start-session --target $ID` |
| Container status (on host) | `sudo docker ps` |
| App logs (live) | `aws logs tail /litellm/litellm --follow` |
| App logs (on host) | `sudo docker compose --project-directory /opt/litellm logs --tail 200 litellm` |
| Boot logs (on host) | `sudo cat /var/log/cloud-init-output.log` |
| Roll back config | `aws s3api list-object-versions --bucket "$(terraform -chdir=terraform output -raw bundle_bucket)" --prefix app/config.yaml`, then copy the old version back with `aws s3api copy-object --copy-source "<bucket>/app/config.yaml?versionId=<id>" --bucket <bucket> --key app/config.yaml`, then `./reload.sh --no-apply` |
| List DB snapshots | `aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Backup,Values=litellm --query 'Snapshots[].[SnapshotId,StartTime]' --output table` |
| Your IP changed | Update `allowed_cidrs` (find it with `curl -s https://checkip.amazonaws.com`), then `terraform -chdir=terraform apply`. This only affects `:4000`; HTTPS is open to everyone. |
| Use your own domain | Point an A record at the Elastic IP, set `public_hostname = "llm.example.com"`, then `./reload.sh` |
| Turn public HTTPS off | `public_https = false`, then `./reload.sh`. This closes 80/443; access is then `http://<ip>:4000` from `allowed_cidrs` only. |
| Change the cost alert | Edit `monthly_budget_usd` / `budget_alert_email`, then `terraform -chdir=terraform apply` |
| Bigger instance | `instance_type = "t4g.medium"`, then `terraform -chdir=terraform apply`. It stops, resizes and starts (a few minutes of downtime). Switching ARM ↔ x86 changes the AMI and **replaces** the instance, so snapshot first. |
| Start / stop the server | See [Start and stop the server](#start-and-stop-the-server) |

---

## Troubleshooting

| Symptom | Check / fix |
|---|---|
| `curl` hangs or `HTTP 000` after deploy | First boot takes about 6 minutes. Check progress: `aws ssm start-session --target $ID`, then `cloud-init status` and `sudo systemctl status litellm`. |
| HTTPS certificate error / Caddy not running | `sudo docker logs litellm-caddy`. Ports 80 and 443 must be open to the internet, and `PUBLIC_HOSTNAME` in `/opt/litellm/.env` must match the current IP. Run `./reload.sh --no-apply`. |
| `401` from the API | Wrong or missing key: `Authorization: Bearer <key>`. |
| Model returns `RateLimitError` / `429` | A free tier is exhausted. LiteLLM falls back automatically, but if every provider in a tier is out, wait or add a paid provider. |
| `AuthenticationError` for a provider | Its key is missing or wrong. Run `./set-secret.sh <KEY>`, then `./reload.sh --no-apply`. |
| `Your session has expired. Please reauthenticate using 'aws login'` / `ExpiredToken` | Your `aws login` session timed out. Run `source ./login.sh` and retry. |
| `InvalidInstanceID.NotFound` / `ResourceNotFoundException` / Terraform wants to **create** everything again | You're signed in to the **wrong account**. Run the account check from [Step 3](#step-3--sign-in-to-aws); sign out of the console, `aws login` again and pick **Console Dot Dream** (`985040258825`). |
| `Unable to locate credentials` / Terraform `No valid credential sources` | Run `aws login`, then `eval "$(aws configure export-credentials --format env)"`. |
| `UnauthorizedOperation ... service control policy` | The Region isn't allowed. See [Step 3](#step-3--sign-in-to-aws). |
| EC2 `InvalidParameterCombination ... not eligible for Free Tier` | The account is on the Free plan. Use a Free Tier type (t4g.small, t3.small, c7i-flex.large, m7i-flex.large). |
| Server out of memory | `free -m` on the host. The 2 GiB of RAM plus 2 GiB of swap fits light use; move up to `t4g.medium`. |

---

## Cost

Compute only, in `ap-south-1`, running 24/7.

| Item | USD/month |
|---|---|
| t4g.small | ~8.20 |
| 30 GB gp3 disk + daily snapshots | ~3–4 |
| Elastic IP (public IPv4) | ~3.65 |
| 8 Secrets Manager secrets | ~3.20 |
| CloudWatch Logs, S3, data transfer | < 1 |
| **Total** | **~18–20** |

- **Free-tier models:** cost $0.
- **Bigger instance:** t4g.medium (4 GiB, ~$16) for about 30 active users.
- **Load balancer:** the optional ALB adds ~$20; it isn't needed, because Caddy provides HTTPS for free.
- **Spend alert:** the AWS Budget `litellm-monthly` emails you before spend passes $25.

---

## Hardening checklist

- [x] HTTPS with a valid certificate (Caddy + Let's Encrypt). The master key never travels over plain HTTP.
- [x] Per-user keys with optional budgets; no SSH (SSM only); encrypted disk; secrets in Secrets Manager
- [ ] Own domain instead of sslip.io (`public_hostname`)
- [ ] Restrict `public_cidrs` to office/VPN ranges if the gateway doesn't need to be open to the whole internet
- [ ] Remote, encrypted Terraform state (uncomment the backend in `terraform/versions.tf`)
- [ ] MFA on the management account (AWS Settings → Set up MFA)
- [ ] Never change `LITELLM_SALT_KEY` once keys are stored in the DB
- [ ] Keep confidential data on Bedrock or paid providers; free tiers may train on prompts

---

## Tear down

```bash
aws login --region ap-south-1
[ "$(aws sts get-caller-identity --query Account --output text)" = 985040258825 ] && echo "OK: project account" || echo "WRONG ACCOUNT: run aws login again and pick Console Dot Dream"
eval "$(aws configure export-credentials --format env)"
terraform -chdir=terraform destroy
```

Secrets go into a 7-day recovery window. Snapshots made by DLM are kept until you delete them:

```bash
aws ec2 describe-snapshots --region ap-south-1 --owner-ids self --filters Name=tag:Backup,Values=litellm \
  --query 'Snapshots[].SnapshotId' --output text | xargs -n1 aws ec2 delete-snapshot --region ap-south-1 --snapshot-id
```

---

## Developing this repo

### Layout

| Path | What |
|---|---|
| `terraform/*.tf` | VPC lookup, security group, IAM, Secrets Manager, S3 bundle, EC2, Elastic IP, optional ALB, DLM snapshots, budget |
| `app/config.yaml` | LiteLLM model list and router settings |
| `app/docker-compose.yml` | litellm, postgres, redis, caddy (`https` profile) |
| `app/Caddyfile` | HTTPS reverse proxy to `litellm:4000` |
| `host/user-data.sh.tftpl` | First boot: swap, Docker, Compose, systemd unit |
| `host/litellm-up` | Runs on every boot and reload: S3 sync, `.env` from Secrets Manager, compose up |
| `login.sh` | `source ./login.sh`: sign in, check the account, export credentials, `ID`, `URL` |
| `set-secret.sh` / `reload.sh` / `new-key.sh` | Store a provider key / apply and restart / create per-user keys (one, or a whole list from CSV/Excel) |

### Validate changes

```bash
terraform -chdir=terraform init -backend=false   # providers only
terraform -chdir=terraform fmt -check -recursive # drop -check to auto-fix
terraform -chdir=terraform validate              # needs no credentials and no tfvars
shellcheck -S warning *.sh host/litellm-up
```

### Editor setup (VS Code)

| Extension | ID | For |
|---|---|---|
| HashiCorp Terraform | `hashicorp.terraform` | `*.tf`: highlighting, autocomplete, validation, format on save |
| YAML | `redhat.vscode-yaml` | `app/config.yaml`, `app/docker-compose.yml` |
| ShellCheck | `timonwong.shellcheck` | `*.sh`, `host/litellm-up` |

```bash
code --install-extension hashicorp.terraform
code --install-extension redhat.vscode-yaml
code --install-extension timonwong.shellcheck
```

If `code` isn't found, run **Shell Command: Install 'code' command in PATH** from the VS Code
command palette. To format on save, add this to VS Code `settings.json`:

```json
"[terraform]":      { "editor.defaultFormatter": "hashicorp.terraform", "editor.formatOnSave": true },
"[terraform-vars]": { "editor.defaultFormatter": "hashicorp.terraform", "editor.formatOnSave": true }
```
