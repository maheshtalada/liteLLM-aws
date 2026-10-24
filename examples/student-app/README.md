# Course assistant: example student app

A tiny Python LLM application that uses the class gateway with a **student key**. It shows the two
building blocks most LLM apps need:

| Command | What it does | Gateway models |
|---|---|---|
| `python app.py chat "<question>"` | Asks a model a question | `base` |
| `python app.py rag "<question>"` | Finds the most relevant course notes by meaning (embeddings + cosine similarity), then answers only from them | `embed` + `base` |

## Run it

```bash
cd examples/student-app
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export OPENAI_BASE_URL="https://3-111-59-142.sslip.io"
export OPENAI_API_KEY="sk-...your student key..."      # from your instructor; never put it in code

python app.py chat "Explain what an API is in two sentences."
python app.py rag  "What should I do if I get a 429 error?"
```

Example output from `rag` (tested on 2026-10-24 with a student key, about 2 s, $0):

```
[retrieved notes]
- If you see a 429 error you hit your rate limit of 10 requests per minute; wait a minute and retry.
- Each student gets a personal API key from the instructor. Keys must never be shared or committed to git.

If you see a 429 error, it means you have hit the rate limit of 10 requests per minute. You should wait a minute and then retry.
```

## Ideas to extend it

- Load `NOTES` from your own `.txt` / `.md` files, split into paragraphs.
- Compute the note embeddings once and save them (JSON, SQLite, or a vector DB such as Chroma).
- Stream answers: `client.chat.completions.create(..., stream=True)`.
- Ask for JSON output to extract structured data (e.g. `response_format={"type": "json_object"}`).

Always embed your notes and your questions with the **same** model name (`embed`). Vectors from
different embedding models can't be compared.
