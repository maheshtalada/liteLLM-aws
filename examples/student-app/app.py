"""Course assistant: a tiny LLM application that uses the class gateway.

It shows the two building blocks most LLM apps need:
  1. chat        - ask a model a question               (model "base")
  2. RAG         - find the relevant notes with embeddings, then answer from them
                   (embeddings: model "embed", answer: model "base")

Setup (your key comes from the instructor; never put it in code or git):
    export OPENAI_BASE_URL="https://3-111-59-142.sslip.io"
    export OPENAI_API_KEY="sk-...your key..."
    pip install -r requirements.txt

Run:
    python app.py chat "Explain what an API is in two sentences."
    python app.py rag  "How do students get access to the gateway?"
"""
import math
import sys

from openai import OpenAI

client = OpenAI()  # reads OPENAI_BASE_URL and OPENAI_API_KEY from the environment

# A few "course notes" for the RAG demo. In a real app these would come from files or a database.
NOTES = [
    "Each student gets a personal API key from the instructor. Keys must never be shared or committed to git.",
    "The gateway offers three model tiers: lite for quick tasks, base for general chat, complex for reasoning.",
    "Free models may use prompts for training, so do not send confidential or personal data.",
    "If you see a 429 error you hit your rate limit of 10 requests per minute; wait a minute and retry.",
    "Embeddings turn text into vectors so you can search notes by meaning instead of exact words.",
]


def chat(question: str, context: str = "") -> str:
    system = "You are a concise teaching assistant."
    if context:
        system += " Answer using only this context; say if it isn't covered.\n\nContext:\n" + context
    resp = client.chat.completions.create(
        model="base",
        messages=[{"role": "system", "content": system}, {"role": "user", "content": question}],
        max_tokens=400,
    )
    return resp.choices[0].message.content


def embed(texts: list) -> list:
    resp = client.embeddings.create(model="embed", input=texts)
    return [d.embedding for d in resp.data]


def cosine(a: list, b: list) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    return dot / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)))


def rag(question: str, top_k: int = 2) -> str:
    note_vectors = embed(NOTES)          # in a real app: compute once and store in a vector DB
    q_vector = embed([question])[0]
    ranked = sorted(zip(NOTES, note_vectors), key=lambda nv: cosine(q_vector, nv[1]), reverse=True)
    context = "\n".join(f"- {note}" for note, _ in ranked[:top_k])
    print(f"[retrieved notes]\n{context}\n")
    return chat(question, context)


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("chat", "rag"):
        print(__doc__)
        sys.exit(1)
    mode, question = sys.argv[1], " ".join(sys.argv[2:])
    print(chat(question) if mode == "chat" else rag(question))
