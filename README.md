# LiteLLM Gateway on AWS

One OpenAI-compatible HTTPS endpoint for many AI models, running on a small EC2 server in Mumbai.
Each person gets their own key; usage is tracked per person.

| | |
|---|---|
| **URL** | `https://3-111-59-142.sslip.io` (admin UI: `/ui`) |
| **Models** | `lite`, `base`, `complex` (free tiers of Gemini, Groq, OpenRouter, Z.AI GLM, Cohere) |
| **Server** | EC2 `t4g.small` in `ap-south-1`, account **985040258825** (Console Dot Dream) |
| **Cost** | about $18–20/month for AWS; the models are free |

Full details (architecture, AWS console map, every command, troubleshooting): **[docs/reference.md](docs/reference.md)**

---

## Everyday use

Start every terminal session with:

```bash
cd ~/aws-deployments/liteLLM
source ./login.sh
```

It signs you in (the browser opens only if your session has expired), checks you're in the right
account, and sets `$ID` and `$URL`. If it says **WRONG ACCOUNT**, sign out of the AWS console in your
browser, then run it again and pick **Console Dot Dream**.

| I want to… | Run |
|---|---|
| Start the server | `aws ec2 start-instances --instance-ids $ID` (ready in 1–2 min) |
| Stop the server (save money) | `aws ec2 stop-instances --instance-ids $ID` |
| Check it's up | `curl -s $URL/health/liveliness` (prints `"I'm alive!"`) |
| Add or change a provider key | `./set-secret.sh GEMINI_API_KEY`, then `./reload.sh --no-apply` |
| Give someone a key | `./new-key.sh priya@example.com students 5` (email, team, USD budget) |
| Change models | Edit `app/config.yaml`, then `./reload.sh` |
| Restart LiteLLM | `./reload.sh --no-apply` |
| See logs | `aws logs tail /litellm/litellm --follow` |
| Open a shell on the server | `aws ssm start-session --target $ID` |

**Admin UI:** open `https://3-111-59-142.sslip.io/ui` and log in with username `admin`. The
password is the master key. Copy it to your clipboard without displaying it:

```bash
aws secretsmanager get-secret-value --secret-id litellm/LITELLM_MASTER_KEY --query SecretString --output text | tr -d '\n' | pbcopy
```

Never share the master key, or paste any key into chat or git.

---

## Using the gateway

Give each user their key and this base URL. Any OpenAI-compatible client works:

```python
from openai import OpenAI
client = OpenAI(base_url="https://3-111-59-142.sslip.io", api_key="sk-...")
r = client.chat.completions.create(model="base", messages=[{"role": "user", "content": "Hello"}])
print(r.choices[0].message.content)
```

| Model | Use for |
|---|---|
| `lite` | quick, simple tasks |
| `base` | general chat and writing (default) |
| `complex` | reasoning, coding, long documents |

Each name spreads requests across several free models and falls back automatically when one is busy.
Free tiers are shared by everyone and may use prompts for training, so don't send confidential data.

---

## First-time setup

This takes about 30 minutes from an empty Mac.

**1. Install the tools**

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform awscli jq gh
brew install --cask session-manager-plugin
```

**2. Get the code and sign in**

```bash
gh repo clone maheshtalada/liteLLM-aws ~/aws-deployments/liteLLM
cd ~/aws-deployments/liteLLM
source ./login.sh
```

On a new AWS account (Builder ID / "Projects"), Mumbai is blocked at first. See
[Region blocked](docs/reference.md#step-3--sign-in-to-aws) for the one-time fix.

**3. Configure**

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`, at minimum:
- `litellm_tag`: an exact LiteLLM version, such as `v1.106.1`
- `allowed_cidrs`: your IP, from `curl -s https://checkip.amazonaws.com`, plus `/32`
- `public_https = true`
- `budget_alert_email`: your email

All the settings are explained in [docs/reference.md](docs/reference.md#step-4--configure).

**4. Deploy**

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply        # review the plan, type yes
```

First boot takes about 6 minutes. Wait until `curl -s $(terraform -chdir=terraform output -raw gateway_url)/health/liveliness` prints `"I'm alive!"`.

**5. Add model keys**

Get free keys and store each one. You type the key at a hidden prompt.

| Provider | Get a key |
|---|---|
| Gemini (enough to start) | https://aistudio.google.com/apikey |
| Groq | https://console.groq.com/keys |
| OpenRouter | https://openrouter.ai/settings/keys |
| Z.AI (GLM) | https://z.ai |
| Cohere | https://dashboard.cohere.com/api-keys |

```bash
./set-secret.sh GEMINI_API_KEY          # repeat for each provider you use
./reload.sh --no-apply
```

**6. Give people keys:** `./new-key.sh <email> <team> [budget]`. The key is shown once; send it privately.

---

## If something goes wrong

| Problem | Fix |
|---|---|
| `Your session has expired` | `source ./login.sh` |
| `WRONG ACCOUNT` or `InvalidInstanceID.NotFound` | Sign out of the AWS console, `source ./login.sh`, pick Console Dot Dream |
| Site doesn't load | The server may be stopped: `aws ec2 start-instances --instance-ids $ID`, wait 2 min |
| `401` from the API | Missing or wrong key in `Authorization: Bearer <key>` |
| `429` / rate limit | A free tier is used up. Wait, or add another provider key. |

More fixes are in [docs/reference.md](docs/reference.md#troubleshooting).

---

## Remove everything

```bash
source ./login.sh
terraform -chdir=terraform destroy
```

---

## Repo layout

| Path | What |
|---|---|
| `app/config.yaml` | Which models are in `lite` / `base` / `complex` |
| `terraform/` | AWS infrastructure; settings in `terraform.tfvars` (not in git) |
| `host/` | Scripts that run on the server at boot |
| `login.sh` · `set-secret.sh` · `reload.sh` · `new-key.sh` | Sign in · store a key · restart · create a user key |
| `docs/reference.md` | Full reference |
