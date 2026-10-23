# CLAUDE.md — LiteLLM gateway on EC2

This repo deploys a LiteLLM gateway on one EC2 instance (Amazon Linux 2023, docker compose:
LiteLLM + Postgres + Redis). Bedrock is called through the instance IAM role; external providers
(Anthropic, OpenAI, Azure OpenAI, Gemini, Groq, Cohere) use keys stored in AWS Secrets Manager.
Short guide: README.md. Full runbook (every command, console map, troubleshooting): docs/reference.md.

## Layout

- `terraform/*.tf` — Terraform (run as `terraform -chdir=terraform …`; tfvars live in `terraform/`) (VPC lookup, SG, IAM role, Secrets Manager, S3 bundle, EC2, optional ALB, DLM snapshots)
- `app/config.yaml` — LiteLLM model list (Bedrock + external). Synced to the host via S3.
- `app/docker-compose.yml` — stack that runs on the host in /opt/litellm
- `host/user-data.sh.tftpl` — first-boot install (Docker, Compose, systemd unit)
- `host/litellm-up` — runs on every boot / reload: S3 sync → render .env from Secrets Manager → compose up
- `login.sh` — `source ./login.sh`: aws login if expired, refuse any account but 985040258825, export creds/AWS_REGION/ID/URL.
- `set-secret.sh` — store a provider key (prompted, hidden). `reload.sh` — apply + restart via SSM.
- `new-key.sh` — per-user virtual key (user + team) for usage tracking. The user runs it; it prints the
  new key once, so don't run it yourself and capture the key in chat.

## Deploy workflow (follow in order)

1. **Preflight** — run and report results; stop if any fail:
   - `terraform version` (≥ 1.5), `aws --version` (v2), `session-manager-plugin --version`
   - `aws sts get-caller-identity` — confirm the account/role with the user before continuing
2. **Variables** — if `terraform/terraform.tfvars` doesn't exist, copy `terraform/terraform.tfvars.example` and ask the user for:
   `litellm_tag` (exact release ≥ v1.83.0 — check https://github.com/BerriAI/litellm/releases),
   `allowed_cidrs` (suggest their current public IP from `curl -s https://checkip.amazonaws.com` + `/32`),
   `azure_api_base` (or remove Azure), and which providers to keep in `provider_secret_names`.
3. **Bedrock model IDs** — run
   `aws bedrock list-inference-profiles --region <region> --query 'inferenceProfileSummaries[].inferenceProfileId'`
   and `aws bedrock list-foundation-models --region <region> --by-inference-type ON_DEMAND --query 'modelSummaries[].modelId'`,
   then replace the `<…>` placeholders in `app/config.yaml`. Prefer `apac.*` inference profile IDs in ap-south-1.
   Remove config entries for providers the user isn't using. No `<` placeholders may remain.
4. `terraform -chdir=terraform init` → `terraform -chdir=terraform plan` → show the user a short summary of the plan → **ask before `terraform apply`**.
5. **Provider keys** — tell the user to run `./set-secret.sh <KEY>` themselves in a terminal for each provider
   (it prompts with hidden input). Then run `./reload.sh --no-apply`.
6. **Verify** with the curl commands in docs/reference.md "Step 7 — Verify" (one Bedrock model, one external model).
   If the host isn't ready, wait — first boot takes 3–5 minutes after apply.

## Debugging

- Host shell: `aws ssm start-session --target <instance_id>` (output `ssm_shell`).
- Boot logs: `sudo cat /var/log/cloud-init-output.log`; service: `sudo systemctl status litellm`.
- App logs: `sudo docker compose --project-directory /opt/litellm logs --tail 200 litellm`, or CloudWatch `/litellm/<name>`.
- Bedrock `AccessDeniedException` → model access not enabled in the Bedrock console, or wrong model/profile ID for the region.
- Bedrock credential errors inside the container → check IMDS hop limit is 2 (set in terraform/main.tf).

## Rules

- **Never** print, echo, cat or log secret values (master key, salt key, provider keys, `.env` on the host).
  When verifying, read the master key into a shell variable without echoing it.
- **Never** ask the user to paste API keys into the chat — they use `./set-secret.sh` in their own terminal.
- **Never** change or rotate `LITELLM_SALT_KEY` once the gateway is running.
- Ask before `terraform apply`, `terraform destroy`, or any command that deletes resources.
- Don't use `latest` image tags. Don't open SSH (port 22); use SSM.
- Don't set `allowed_cidrs` to `0.0.0.0/0` without the user explicitly asking.
- Don't commit `terraform.tfvars`, `*.tfstate*`, or `.terraform/`.
