# LiteLLM Gateway on a single EC2 instance

One OpenAI/Anthropic-compatible endpoint for **Amazon Bedrock** (Claude, Nova, Llama…) and
**external providers** (Anthropic, OpenAI, Azure OpenAI, Gemini, Groq, Cohere) — the AWS
multi-provider gateway architecture, minus ECS/EKS.

## Architecture

```
Clients (apps, agents, Claude Code)
     │  HTTPS 443 (allowed_cidrs)          ← optional ALB + ACM when acm_certificate_arn is set
     ▼                                        (otherwise direct HTTP :4000 for testing)
┌──────────────────── EC2 (Amazon Linux 2023, t3.large) ────────────────────┐
│  docker compose                                                           │
│   ├─ litellm   :4000  ──► Bedrock (instance role, IMDSv2) ──► Claude/Nova/Llama
│   │                   ──► Anthropic / OpenAI / Azure / Gemini / Groq / Cohere
│   ├─ postgres  (virtual keys, teams, budgets, spend)  → EBS, daily snapshots
│   └─ redis     (rate limits, router state)                                │
└───────────────────────────────────────────────────────────────────────────┘
  Secrets Manager: litellm/LITELLM_MASTER_KEY, LITELLM_SALT_KEY, POSTGRES_PASSWORD, <PROVIDER>_API_KEY
  S3 (versioned):  config.yaml, docker-compose.yml, launcher      CloudWatch Logs: /litellm/litellm
  Access: SSM Session Manager (no SSH port, no key pair)
```

## Prerequisites

- Terraform ≥ 1.5, AWS CLI v2, [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- **Bedrock model access** in your region: open the Bedrock console → Model catalog and make sure the
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
cp terraform/terraform.tfvars.example terraform/terraform.tfvars    # set litellm_tag, allowed_cidrs, azure_api_base
# Edit app/config.yaml: fill <placeholders>, delete providers you don't use

terraform -chdir=terraform init
terraform -chdir=terraform apply                            # ~5 min; first boot takes another ~3–5 min

# Provider keys (prompted, not echoed). Bedrock needs none.
chmod +x *.sh
./set-secret.sh OPENAI_API_KEY
./set-secret.sh ANTHROPIC_API_KEY                # …one per provider you kept
./reload.sh --no-apply                           # host re-reads secrets and restarts LiteLLM
```

Find Bedrock IDs callable from your region:

```bash
aws bedrock list-inference-profiles --region ap-south-1 --query 'inferenceProfileSummaries[].inferenceProfileId'
aws bedrock list-foundation-models  --region ap-south-1 --by-inference-type ON_DEMAND --query 'modelSummaries[].modelId'
```

## Verify

```bash
URL=$(terraform -chdir=terraform output -raw gateway_url)
MASTER=$(aws secretsmanager get-secret-value --secret-id litellm/LITELLM_MASTER_KEY --query SecretString --output text)

curl -s $URL/health/liveliness
curl -s $URL/v1/models -H "Authorization: Bearer $MASTER"

# Bedrock through the gateway
curl -s $URL/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"model":"nova-lite","messages":[{"role":"user","content":"ping"}]}'

# External provider through the same endpoint
curl -s $URL/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"ping"}]}'
```

Admin UI: `$URL/ui` → log in with the master key → create teams and **virtual keys** with budgets,
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
`$MASTER`. To revoke a key: UI → Virtual Keys → delete, or `POST $URL/key/delete`.

## Day-2 operations

| Task | How |
|---|---|
| Add/change models | Edit `app/config.yaml` → `./reload.sh` |
| Add a new provider | Add its key name to `provider_secret_names` → `./reload.sh` → `./set-secret.sh <KEY>` → `./reload.sh --no-apply` |
| Rotate a provider key | `./set-secret.sh <KEY>` → `./reload.sh --no-apply` |
| Upgrade LiteLLM | Change `litellm_tag` → `./reload.sh` |
| Shell on the host | `$(terraform -chdir=terraform output -raw ssm_shell)` then `sudo docker compose --project-directory /opt/litellm logs -f litellm` |
| Logs | CloudWatch log group `/litellm/litellm` |
| Roll back config | S3 bucket is versioned — restore the previous `app/config.yaml` version, then `./reload.sh --no-apply` |
| Restore DB | Daily EBS snapshots (7 kept) of the root volume, tag `Backup=litellm` |

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

## Rough monthly cost (ap-south-1)

t3.large on-demand + 40 GB gp3 + snapshots + Elastic IP ≈ USD 70–90; the optional ALB adds ≈ USD 20–25.
Model usage (Bedrock or external) is billed separately.

## Tear down

`terraform -chdir=terraform destroy` (secrets go into a 7-day recovery window; snapshots made by DLM are kept until you delete them).
