# LiteLLM Gateway on a single EC2 instance

One OpenAI-compatible endpoint in front of many model providers, on one small EC2 instance in
**Mumbai (`ap-south-1`)**. It currently serves **free-tier models only** (Gemini, Groq, OpenRouter,
Z.AI GLM, Cohere), grouped into three model names — `lite`, `base`, `complex`. Bedrock and paid
providers (Anthropic, OpenAI, Azure) can be added back in `app/config.yaml`.

## Architecture

```
Clients (apps, agents, Claude Code)
     │  HTTPS 443 (allowed_cidrs)          ← optional ALB + ACM when acm_certificate_arn is set
     ▼                                        (otherwise direct HTTP :4000 for testing)
┌──────────────────── EC2 (Amazon Linux 2023, t4g.small ARM) ───────────────┐
│  docker compose                                                           │
│   ├─ litellm   :4000  ──► lite / base / complex  ──► Gemini / Groq / OpenRouter / GLM / Cohere
│   │                   ──► (optional) Bedrock via instance role, IMDSv2
│   ├─ postgres  (virtual keys, teams, budgets, spend)  → EBS, daily snapshots
│   └─ redis     (rate limits, router state)                                │
└───────────────────────────────────────────────────────────────────────────┘
  Secrets Manager: litellm/LITELLM_MASTER_KEY, LITELLM_SALT_KEY, POSTGRES_PASSWORD, <PROVIDER>_API_KEY
  S3 (versioned):  config.yaml, docker-compose.yml, launcher      CloudWatch Logs: /litellm/litellm
  Access: SSM Session Manager (no SSH port, no key pair)
```

## Prerequisites

- Terraform ≥ 1.5, AWS CLI v2, [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  (`brew install awscli`, `brew install --cask session-manager-plugin`)
- Signed in: `aws login --region ap-south-1`, then `aws sts get-caller-identity` to confirm the account.
- **New AWS sign-up experience (Builder ID / AWS Settings "Projects")**: AWS assigns India-based
  projects to Sydney and blocks other Regions with a managed SCP. To use Mumbai you must
  *activate advanced features* (irreversible; removes the spend limit), then in the management account
  add `"ap-south-1"` to **every** `aws:RequestedRegion` list in
  `AdvancedModeRegionRestrictionSecurityControlPolicy` (AWS Settings → Manage Region policy).
- (Only if you add Bedrock models) **Bedrock model access** in your region: open the Bedrock console → Model catalog and make sure the
  models you list in `config.yaml` are usable in your account (Anthropic models may require a one-time
  use-case form). Do this once as an admin.
- (Recommended) remote state backend — uncomment it in `terraform/versions.tf`.

### Terraform setup (macOS)

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform version                                # must be ≥ 1.5
```

Other platforms: https://developer.hashicorp.com/terraform/install

### Validate the Terraform config

All Terraform files live in `terraform/`; run from the repo root with `-chdir`:

```bash
terraform -chdir=terraform init -backend=false   # download providers only, no state backend
terraform -chdir=terraform fmt -check -recursive # formatting (drop -check to auto-fix)
terraform -chdir=terraform validate              # syntax + internal consistency
```

If you signed in with `aws login`, Terraform can't read that session directly. Before `plan`/`apply`/`output`, run
`eval "$(aws configure export-credentials --format env)"` in the same shell (`reload.sh` and `new-key.sh` do this for you).

`validate` needs no AWS credentials or `terraform.tfvars`. Run it after editing any `.tf` file;
use `terraform -chdir=terraform plan` (needs credentials and tfvars) to see real changes.

### Editor setup (VS Code)

| Extension | ID | For |
|---|---|---|
| HashiCorp Terraform | `hashicorp.terraform` | `*.tf` — highlighting, autocomplete, validation, `terraform fmt` |
| YAML | `redhat.vscode-yaml` | `app/config.yaml`, `app/docker-compose.yml` |
| ShellCheck | `timonwong.shellcheck` | `set-secret.sh`, `reload.sh`, `host/litellm-up` (needs `brew install shellcheck`) |

```bash
brew install shellcheck
code --install-extension hashicorp.terraform
code --install-extension redhat.vscode-yaml
code --install-extension timonwong.shellcheck
```

If `code` isn't found, run **Shell Command: Install 'code' command in PATH** from the VS Code command palette.
To format Terraform on save, add to VS Code `settings.json`:

```json
"[terraform]": {
  "editor.defaultFormatter": "hashicorp.terraform",
  "editor.formatOnSave": true
}
```

## Deploy

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars    # region, litellm_tag, allowed_cidrs, budget email
# Edit app/config.yaml if you want different models

eval "$(aws configure export-credentials --format env)"    # only if you signed in with `aws login`
terraform -chdir=terraform init
terraform -chdir=terraform apply                            # ~5 min; first boot takes another ~3–5 min

# Provider keys (prompted, not echoed) — get free keys from each provider's console
chmod +x *.sh
./set-secret.sh GEMINI_API_KEY        # https://aistudio.google.com/apikey
./set-secret.sh GROQ_API_KEY          # https://console.groq.com/keys
./set-secret.sh OPENROUTER_API_KEY    # https://openrouter.ai/settings/keys
./set-secret.sh ZAI_API_KEY           # https://z.ai (API keys)
./set-secret.sh COHERE_API_KEY        # https://dashboard.cohere.com/api-keys (trial)
./reload.sh --no-apply                # host re-reads secrets and restarts LiteLLM
```

Current settings (`terraform/terraform.tfvars`): `ap-south-1`, `t4g.small` (2 vCPU ARM, 2 GiB + 2 GiB swap,
Free Tier eligible), 30 GB disk, `cpu_credits = "standard"` (never billed for extra CPU), LiteLLM `v1.106.1`,
and a $25/month AWS Budget that emails at 80% actual / 100% forecast spend. Terraform picks the ARM or
x86 AMI automatically from `instance_type`.

### Model tiers (`app/config.yaml`)

Clients send `"model": "lite" | "base" | "complex"`. Each name load-balances across every free deployment
in that tier; a rate-limited deployment cools down for 60 s and requests fall back to another tier.

| Tier | Use for | Deployments |
|---|---|---|
| `lite` | classification, extraction, short answers | Gemini 3.5 Flash-Lite, Groq gpt-oss-20b, GLM-4.5-Flash, Nemotron 3.5 Lightning |
| `base` | general chat and writing (default) | Gemini 3.8 Flash, Groq gpt-oss-120b, Qwen 3.8 27B, GLM-4.7-Flash, MiniMax M3.1 Flash, Gemma 4 31B |
| `complex` | reasoning, coding, long documents | Gemini 2.5 Pro, Nemotron 3 Ultra, Inkling, Laguna S 2.1, Cohere Command A |

Free tiers are rate-limited, shared by everyone using the gateway, and may use prompts for training —
don't send confidential data. Free model lists change often; links to check are at the top of `app/config.yaml`.

Optional — if you add Bedrock models later, find the IDs callable from Mumbai:

```bash
aws bedrock list-inference-profiles --region ap-south-1 --query 'inferenceProfileSummaries[].inferenceProfileId'
aws bedrock list-foundation-models  --region ap-south-1 --by-inference-type ON_DEMAND --query 'modelSummaries[].modelId'
```

## Shell setup (once per terminal)

Every command below assumes these variables. `MASTER` is read without being printed — never `echo` it.

```bash
cd ~/aws-deployments/liteLLM
eval "$(aws configure export-credentials --format env)"     # aws login → env vars Terraform can read
export AWS_REGION=ap-south-1
URL=$(terraform -chdir=terraform output -raw gateway_url)
ID=$(terraform -chdir=terraform output -raw instance_id)
MASTER=$(aws secretsmanager get-secret-value --secret-id "$(terraform -chdir=terraform output -raw master_key_secret_name)" \
  --query SecretString --output text)
```

`aws login` sessions expire; if a command says the token expired, run `aws login` again and repeat the block.

## Verify

```bash
curl -sS $URL/health/liveliness                                   # → "I'm alive!"
curl -sS $URL/v1/models -H "Authorization: Bearer $MASTER" | jq -r '.data[].id'   # → base, complex, lite

for tier in lite base complex; do
  echo "== $tier"
  curl -sS $URL/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
    -d "{\"model\":\"$tier\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: ping\"}]}" \
    | jq -r '.model, (.choices[0].message.content // .error.message)'
done
```

The first line printed per tier is the deployment that actually answered (LiteLLM picks one at random).

If the host isn't up yet, check boot progress (first boot takes 3–5 minutes):

```bash
aws ssm send-command --instance-ids $ID --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init status","systemctl is-active litellm","docker ps --format \"{{.Names}} {{.Status}}\""]' \
  --query Command.CommandId --output text      # then:
aws ssm get-command-invocation --instance-id $ID --command-id <id-from-above> --query StandardOutputContent --output text
```

Admin UI: open `$URL/ui` in a browser → log in with the master key → teams, **virtual keys**, budgets,
RPM/TPM limits and per-key model allow-lists. Never hand out the master key.

## Per-user keys (usage tracking)

Give every team member their own virtual key — spend, tokens and requests are then tracked per key,
per user and per team (stored in Postgres, visible in the UI under **Usage** and via `/spend/logs`).

```bash
./new-key.sh priya@example.com platform 50   # user, team, optional USD budget
./new-key.sh arjun@example.com data          # no budget cap
```

The script creates the team and user if missing, adds the user to the team, and prints the new key
**once** — send it to the person privately. Users call the gateway with their own key in place of
`$MASTER`. Check usage and revoke keys (needs the shell setup above):

```bash
curl -sS "$URL/user/info?user_id=priya@example.com" -H "Authorization: Bearer $MASTER" | jq '.user_info.spend'
curl -sS "$URL/team/info?team_id=platform"         -H "Authorization: Bearer $MASTER" | jq '.team_info.spend'
curl -sS -X POST $URL/key/delete -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"key_aliases":["<key alias shown in the UI>"]}'
```

## Day-2 operations

Run the shell setup first. `reload.sh` and `new-key.sh` export the `aws login` credentials themselves.

| Task | Command |
|---|---|
| Add/change models | edit `app/config.yaml` → `./reload.sh` |
| Add a new provider | add its key name to `provider_secret_names` in tfvars → `./reload.sh` → `./set-secret.sh <KEY>` → `./reload.sh --no-apply` |
| Rotate a provider key | `./set-secret.sh <KEY>` → `./reload.sh --no-apply` |
| Upgrade LiteLLM | change `litellm_tag` in tfvars → `./reload.sh` |
| Restart LiteLLM only | `./reload.sh --no-apply` |
| Shell on the host | `aws ssm start-session --target $ID` |
| App logs (live) | `aws logs tail /litellm/litellm --follow` |
| App logs (on host) | `sudo docker compose --project-directory /opt/litellm logs --tail 200 litellm` |
| Boot logs (on host) | `sudo cat /var/log/cloud-init-output.log` |
| Roll back config | `aws s3api list-object-versions --bucket "$(terraform -chdir=terraform output -raw bundle_bucket)" --prefix app/config.yaml` → copy the old version back with `aws s3api copy-object … --copy-source "<bucket>/app/config.yaml?versionId=<id>"` → `./reload.sh --no-apply` |
| List DB snapshots | `aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Backup,Values=litellm --query 'Snapshots[].[SnapshotId,StartTime]' --output table` |
| Change cost alert | edit `monthly_budget_usd` / `budget_alert_email` in tfvars → `terraform -chdir=terraform apply` |
| Bigger instance | `instance_type = "t4g.medium"` in tfvars → `terraform -chdir=terraform apply` (stop/resize/start, a few minutes down; switching ARM ↔ x86 changes the AMI and **replaces** the instance — snapshot first) |
| Your IP changed | update `allowed_cidrs` in tfvars (`curl -s https://checkip.amazonaws.com`) → `terraform -chdir=terraform apply` |
| Stop the server (save cost) | `aws ec2 stop-instances --instance-ids $ID` · start: `aws ec2 start-instances --instance-ids $ID` (disk + IP still billed, ~$7/mo) |

## When to graduate from one instance

This is a single host: a reboot or instance failure means a few minutes of downtime, and Postgres
lives on the instance. Move to the ECS package (RDS + ElastiCache + 2+ tasks) when the gateway
becomes production-critical for clients. `app/config.yaml` carries over unchanged.

## Hardening checklist

- [ ] ACM cert + DNS name → set `acm_certificate_arn` (direct :4000 is plain HTTP — testing only)
- [ ] `allowed_cidrs` limited to office/VPN ranges
- [ ] Remote, encrypted Terraform state
- [ ] Never change `LITELLM_SALT_KEY` once keys/models are stored in the DB
- [ ] Keep client data on Bedrock/paid providers; restrict free-tier models to dev virtual keys
- [ ] Optional: Bedrock Guardrails, AWS WAF on the ALB, private subnet + NAT (`associate_public_ip = false`)

## Rough monthly cost (ap-south-1, compute only)

| Item | USD/month |
|---|---|
| t4g.small (current) | ~8.2 |
| 30 GB gp3 + snapshots | ~3–4 |
| Public IPv4 (Elastic IP) | ~3.65 |
| 8 Secrets Manager secrets | ~3.20 |
| **Total** | **~18–20** |

Bigger options: t4g.medium (4 GiB, ~$16) for ~30 active users; the optional ALB adds ~$20.
Model usage is $0 on free tiers; Bedrock/paid providers are billed separately.

## Tear down

```bash
eval "$(aws configure export-credentials --format env)"
terraform -chdir=terraform destroy
```

Secrets go into a 7-day recovery window. Snapshots made by DLM are kept until you delete them:

```bash
aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Backup,Values=litellm --query 'Snapshots[].SnapshotId' --output text \
  | xargs -n1 aws ec2 delete-snapshot --snapshot-id
```
