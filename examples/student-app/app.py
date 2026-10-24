"""Course assistant: an example LLM application on the class gateway, with usage measurement.

Setup (your key comes from the instructor; never put it in code or git):
    export OPENAI_BASE_URL="https://3-111-59-142.sslip.io"
    export OPENAI_API_KEY="sk-...your key..."
    pip install -r requirements.txt

Commands (each prints a usage table: requests, tokens, seconds, cost):
    python app.py chat      "Explain what an API is in two sentences."
    python app.py index     sample_notes            # embed your .txt/.md/.pdf files once
    python app.py ask       "How do I avoid 429 errors?"   # RAG with cited sources
    python app.py agent     "What is 17.5% of 2340, and what day is it today?"
    python app.py extract   "Demo day is on 12 Nov 2026 at 3pm in Room 204 with Priya and Arjun; bring laptops."
    python app.py usage                             # this key's total spend and budget, from the gateway
    python app.py benchmark [sessions_per_day] [students]   # simulate a typical session and project usage
"""
import json
import os
import sys
import time
import urllib.request

import agent
import extract
import rag
from common import CHAT_MODEL, chat, usage


def key_info() -> dict:
    """Ask the gateway about the current key (works with a student key; shows only its own data)."""
    req = urllib.request.Request(os.environ["OPENAI_BASE_URL"].rstrip("/") + "/key/info",
                                 headers={"Authorization": "Bearer " + os.environ["OPENAI_API_KEY"]})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r).get("info", {})


def benchmark(sessions_per_day: int = 3, students: int = 10):
    """One typical student session: chats, a quick task, indexing notes, RAG questions, an agent task, extraction."""
    t0 = time.time()
    print("Running one simulated student session (rate limit retries may add waiting time)...")
    for q in ["What is an API?", "Explain embeddings to a beginner in 3 sentences.",
              "Give me 3 ideas for a small LLM app.", "What is the difference between RAG and fine-tuning?",
              "Summarise what a vector database does in one sentence."]:
        chat([{"role": "user", "content": q}], kind="chat")
    for text in ["I loved the workshop!", "The Wi-Fi kept dropping, very frustrating."]:
        chat([{"role": "user", "content": f"Sentiment (positive/negative/neutral), one word: {text}"}],
             model="lite", kind="classify", max_tokens=10)
    rag.build_index("sample_notes")
    for q in ["How do students get a key?", "What should I do about a 429 error?", "Which model tier is for reasoning?"]:
        rag.answer(q)
    agent.run("What is 17.5% of 2340?", verbose=False)
    extract.extract_event("Demo day on 12 Nov 2026 at 15:00 in Room 204 with Priya and Arjun. Bring laptops.")

    print(usage.report("One simulated student session"))
    t = usage.totals()
    tokens = t["prompt"] + t["completion"]
    per_month = sessions_per_day * 30
    print(f"\nSession wall time: {time.time() - t0:.0f}s (includes waiting on the 10 requests/min limit)")
    print(f"\nProjection ({sessions_per_day} sessions/day per student, {students} students, 30 days):")
    rows = [("per session", 1), ("per student per day", sessions_per_day),
            ("per student per month", per_month), (f"class of {students} per month", per_month * students)]
    print(f"  {'':<26}{'requests':>10}{'tokens':>12}{'actual $':>11}{'if paid $':>11}")
    for label, n in rows:
        print(f"  {label:<26}{t['requests'] * n:>10}{tokens * n:>12}{t['cost'] * n:>11.4f}{t['if_paid'] * n:>11.4f}")
    print("\n'actual $' is what the gateway charged (free models = $0). 'if paid $' is the same usage at the\n"
          "paid-fallback list prices, i.e. the worst case once free quotas run out.")


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(1)
    cmd, arg = sys.argv[1], " ".join(sys.argv[2:])
    if cmd == "chat":
        print(chat([{"role": "user", "content": arg}]))
    elif cmd == "index":
        print(f"Indexed {rag.build_index(arg or 'sample_notes')} chunks into {rag.INDEX_FILE}")
    elif cmd in ("ask", "rag"):
        text, hits = rag.answer(arg)
        print(text, "\n\nSources:", ", ".join(f"[{i}] {h['source']} ({h['score']:.2f})" for i, h in enumerate(hits, 1)))
    elif cmd == "agent":
        print(agent.run(arg))
    elif cmd == "extract":
        print(extract.extract_event(arg).model_dump_json(indent=2))
    elif cmd == "usage":
        i = key_info()
        print(json.dumps({k: i.get(k) for k in ("key_alias", "models", "spend", "max_budget", "budget_duration",
                                                 "budget_reset_at", "rpm_limit", "expires")}, indent=2))
        return
    elif cmd == "benchmark":
        a = sys.argv[2:]
        benchmark(int(a[0]) if a else 3, int(a[1]) if len(a) > 1 else 10)
        return
    else:
        print(__doc__)
        sys.exit(1)
    print(usage.report(f"Usage for this run (model tier '{CHAT_MODEL}')"))


if __name__ == "__main__":
    main()
