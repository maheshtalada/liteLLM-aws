# Course assistant: example student app (with usage measurement)

A small Python LLM application that uses the class gateway with a **student key**. It covers the
building blocks most LLM apps need, and **measures every call** (requests, tokens, seconds, actual
cost, and what it would cost on paid models).

| Command | What it shows | Gateway models |
|---|---|---|
| `python app.py chat "<question>"` | Basic chat | `base` |
| `python app.py index sample_notes` | Load `.txt` / `.md` / `.pdf`, split into chunks, embed once, save `.index/index.json` | `embed` |
| `python app.py ask "<question>"` | **RAG**: find the most relevant chunks by meaning and answer with cited sources | `embed` + `base` |
| `python app.py agent "<task>"` | **Tool calling**: the model calls `calculator`, `search_notes`, `current_time` | `base` |
| `python app.py extract "<text>"` | **Structured output**: text → validated JSON (Pydantic) with a retry | `base` |
| `python app.py usage` | This key's spend, budget, reset date, limits and expiry, from the gateway | — |
| `python app.py benchmark [sessions/day] [students]` | Runs a typical student session and projects usage per day, month and class | all |

Files: `common.py` (client + usage tracking), `rag.py`, `agent.py`, `extract.py`, `app.py` (CLI), and
`sample_notes/` (three notes to try it on).

## Run it

```bash
cd examples/student-app
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export OPENAI_BASE_URL="https://3-111-59-142.sslip.io"
export OPENAI_API_KEY="sk-...your student key..."      # from your instructor; never put it in code

python app.py index sample_notes
python app.py ask "What should I do if I get a 429 error?"
python app.py agent "What is 17.5% of 2340, and what day is it today?"
python app.py extract "Demo day is on 12 Nov 2026 at 3pm in Room 204 with Priya and Arjun; bring laptops."
python app.py benchmark 3 10
```

Every command ends with a usage table like this one (from `ask`):

```
 # call      model     in tok out tok  secs     cost $  if paid $
 1 search    embed         12       0   0.4   0.000000   0.000000
 2 rag       base         566     140   0.8   0.000000   0.000730
   2 requests · 718 tokens · actual cost $0.000000 · if served by paid models $0.000730
```

## Measured usage: one typical student session (2026-10-24)

5 chats, 2 quick classifications, indexing 3 notes, 3 RAG questions, 1 tool-calling task and 1 extraction:

| | Requests | Tokens | Actual cost | If served by paid models |
|---|---|---|---|---|
| One session | 17 | 6,527 | $0 | $0.0087 |
| Per student per day (3 sessions) | 51 | ~19,600 | $0 | $0.026 |
| Per student per month | 1,530 | ~587,000 | $0 | **$0.78** |
| Class of 10 per month | 15,300 | ~5.9 M | $0 | **$7.81** |

- Free models cost $0. Even if every request had gone to paid fallback, a student would cost about
  $0.78/month, so a $1 budget is enough.
- **Output tokens drive cost**: three chats hit the 800-token answer cap. Lower `max_tokens` is the
  biggest saving.
- The 10 requests/minute student limit added two waits (31 s and 61 s) during the scripted run. The SDK
  retries automatically.

"If paid" uses the paid-fallback list prices in `common.py` (Nova Lite for `lite`, DeepSeek V3.2 for
`base`/`complex`, Titan for `embed`).

## Anthropic SDK instead of OpenAI

The gateway also speaks the Anthropic Messages API (`/v1/messages`) with the same key and model names:

```python
from anthropic import Anthropic
client = Anthropic(base_url="https://3-111-59-142.sslip.io", api_key="sk-...")
print(client.messages.create(model="base", max_tokens=200,
      messages=[{"role": "user", "content": "Hello"}]).content[0].text)
```

## Where else to see usage

- **Gateway admin UI** (instructor): `/ui` → **Logs** shows every request with the real model that served
  it, tokens, cost and latency; **Usage** shows totals per student and team.
- **Traces** of each step (retrieved chunks, prompts, tool calls): add Langfuse or LangSmith. The gateway
  can send all requests to Langfuse with one setting.

## Notes

- Always embed notes and questions with the **same** model name (`embed`); vectors from different
  embedding models can't be compared. The index records which model built it and refuses a mismatch.
- `.index/` (your vectors) and `.venv/` are git-ignored.
