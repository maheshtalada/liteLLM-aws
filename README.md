# LiteLLM Gateway on AWS

One OpenAI-compatible HTTPS endpoint for many AI models, running on a small EC2 server in Mumbai.
Each person gets their own key; usage is tracked per person.

| | |
|---|---|
| **URL** | `https://3-111-59-142.sslip.io` (admin UI: `/ui`) |
| **Models** | Free: `lite`, `base`, `complex` · Paid (Amazon Bedrock): `bedrock-lite`, `bedrock-base`, `bedrock-complex`, `claude-haiku-4-5`, `claude-sonnet-4-6`, `claude-opus-4-5` |
| **Server** | EC2 `t4g.small` in `ap-south-1`, account **985040258825** (Console Dot Dream) |
| **Cost** | about $18–20/month for the server; free models cost $0, Bedrock models are billed per token |

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
| Give a whole class keys | `./new-key.sh --team students --file students.xlsx --models lite,base --budget 2` (see [below](#keys-for-a-class-or-team)) |
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

| Free model | Paid model (Bedrock) | Use for |
|---|---|---|
| `lite` | `bedrock-lite` (Nova Lite, Claude Haiku 4.5) | quick, simple tasks |
| `base` | `bedrock-base` (Claude Sonnet 4.6, Nova Pro, DeepSeek V3.2) | general chat and writing (default) |
| `complex` | `bedrock-complex` (Claude Opus 4.5, Qwen3 Coder 480B, Kimi K3) | reasoning, coding, long documents |
| | `claude-haiku-4-5`, `claude-sonnet-4-6`, `claude-opus-4-5` | that exact Claude model |

Each name spreads requests across several models and falls back automatically when one is busy.

- **Free models:** shared by everyone and may use prompts for training, so don't send confidential data.
- **Bedrock models:** cost money per token, but your data stays within AWS. They are used **only** when a
  client asks for them; free models never fall back to Bedrock. Leave them off student keys, or give
  those keys a dollar budget.

---

## Keys for a class or team

Create everyone's keys in one command, from a list, a CSV or Excel file, or a Google Sheet:

```bash
./new-key.sh --team students --emails "priya@college.edu, arjun@college.edu" --models lite,base --budget 2 --budget-duration 1d --rpm 10 --expires 90d
./new-key.sh --team students --file students.csv  --models lite,base --budget 2 --budget-duration 1d --rpm 10 --expires 90d
./new-key.sh --team students --file students.xlsx --models lite,base --budget 2 --budget-duration 1d --rpm 10 --expires 90d
./new-key.sh --team students --sheet "https://docs.google.com/spreadsheets/d/<id>/edit#gid=0" --models lite,base --budget 2
./new-key.sh --team students --file students.csv --dry-run      # preview only; creates nothing
```

**File format (CSV or Excel):** email in column A, and optionally a per-student budget in column B
that overrides `--budget`. Header rows, blank lines, invalid entries and duplicates are skipped. For an
old `.xls` file, save it as `.xlsx` or CSV first.

**Google Sheets:** `--sheet` reads the tab in the link, but only if the sheet is shared as **"Anyone
with the link: Viewer"**. That means anyone who gets the link can see the emails. To keep the sheet
private, use **File → Download → Microsoft Excel (.xlsx)** and pass that file to `--file`.

| Option | Meaning | Suggested for students |
|---|---|---|
| `--models` | Models the key may use | `lite,base` (keeps paid Bedrock and the scarce `complex` models off) |
| `--budget` | Spend cap per key, in USD | `2` (a usage cap on free models; real dollars on Bedrock) |
| `--budget-duration` | Budget resets every… | `1d` |
| `--rpm` / `--tpm` | Requests / tokens per minute | `10` / `20000` (shares the free quotas fairly) |
| `--expires` | Key stops working after… | `90d` (end of course) |

Keys are **not shown on screen**. They are written to two private files (readable only by you,
git-ignored):

- `keys/<team>-<time>.csv`: email, key and limits for each student
- `keys/<team>-<time>-messages.txt`: a ready-to-send message per student (key, base URL, setup)

Send each student only their own message, by direct message or email, never in a group chat. Then
delete the files. Students never see the provider keys; those stay on the server.

To manage keys later, use UI → **Virtual Keys** (edit limits, delete a key) and **Usage** (spend per student).
To replace a lost key, delete the old one and run `./new-key.sh` again for that student.

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

**Bedrock (paid models):** no key needed. For Claude, submit the one-time Anthropic use-case form:
in the Bedrock console (Mumbai), go to **Model catalog**, open any Claude model and **submit use case
details**. It takes effect in about 15 minutes.

**6. Give people keys:** `./new-key.sh <email> <team> [budget]` for one person (the key is shown once),
or `--file students.xlsx` for a whole class (see [Keys for a class or team](#keys-for-a-class-or-team)).

---

## If something goes wrong

| Problem | Fix |
|---|---|
| `Your session has expired` | `source ./login.sh` |
| `WRONG ACCOUNT` or `InvalidInstanceID.NotFound` | Sign out of the AWS console, `source ./login.sh`, pick Console Dot Dream |
| Site doesn't load | The server may be stopped: `aws ec2 start-instances --instance-ids $ID`, wait 2 min |
| `401` from the API | Missing or wrong key in `Authorization: Bearer <key>` |
| `429` / rate limit | A free tier is used up. Wait, or add another provider key. |
| `Model use case details have not been submitted` | Submit the Anthropic form in the Bedrock console (see step 5), then wait 15 min |

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
