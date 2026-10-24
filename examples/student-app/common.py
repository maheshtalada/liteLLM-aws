"""Shared client, model names and USAGE TRACKING for the example app.

Every call goes through chat_call() / embed_call(), which record requests, tokens, latency and cost so
you can see exactly how much a simple LLM app uses. The gateway speaks the OpenAI API, so the official
`openai` package works unchanged. It reads OPENAI_BASE_URL and OPENAI_API_KEY from the environment;
never put a key in code.
"""
import os
import sys
import time

from openai import OpenAI

CHAT_MODEL = os.environ.get("CHAT_MODEL", "base")    # gateway tier: lite / base (complex if your key allows)
EMBED_MODEL = os.environ.get("EMBED_MODEL", "embed")  # must stay the same for indexing and searching

# "If it were paid": list prices (USD per 1M tokens) of the paid fallback each tier uses when free quota
# runs out (Bedrock, Mumbai, 2026-10-24). Used only to estimate; the real cost comes from the gateway.
PAID_PRICE_PER_M = {
    "lite":  (0.071, 0.284),   # lite-paid  -> Amazon Nova Lite
    "base":  (0.74, 2.22),     # base-paid  -> DeepSeek V3.2 (Nova Pro is similar)
    "complex": (0.74, 2.22),   # complex-paid -> DeepSeek V3.2 / Nova Pro
    "embed": (0.02, 0.0),      # embed-bedrock -> Titan Text Embeddings v2
}

_client = None


def get_client() -> OpenAI:
    global _client
    if _client is None:
        missing = [v for v in ("OPENAI_BASE_URL", "OPENAI_API_KEY") if not os.environ.get(v)]
        if missing:
            sys.exit(f"Set {' and '.join(missing)} first (see README.md).")
        # max_retries: the SDK waits and retries on 429 (rate limit) and temporary errors.
        _client = OpenAI(max_retries=5)
    return _client


class Usage:
    """Collects one row per API call."""

    def __init__(self):
        self.calls = []

    def add(self, kind, model, served_by, prompt_tokens, completion_tokens, seconds, cost):
        p_in, p_out = PAID_PRICE_PER_M.get(model, PAID_PRICE_PER_M["base"])
        if_paid = (prompt_tokens * p_in + completion_tokens * p_out) / 1e6
        self.calls.append(dict(kind=kind, model=model, served_by=served_by, prompt=prompt_tokens,
                               completion=completion_tokens, seconds=seconds, cost=cost, if_paid=if_paid))

    def totals(self) -> dict:
        t = dict(requests=len(self.calls), prompt=0, completion=0, seconds=0.0, cost=0.0, if_paid=0.0)
        for c in self.calls:
            for k in ("prompt", "completion", "seconds", "cost", "if_paid"):
                t[k] += c[k]
        return t

    def report(self, title="Usage") -> str:
        lines = [f"\n── {title} " + "─" * 60,
                 f"{'#':>2} {'call':<10}{'model':<9}{'in tok':>7}{'out tok':>8}"
                 f"{'secs':>6}{'cost $':>11}{'if paid $':>11}"]
        for i, c in enumerate(self.calls, 1):
            lines.append(f"{i:>2} {c['kind']:<10}{c['model']:<9}{c['prompt']:>7}"
                         f"{c['completion']:>8}{c['seconds']:>6.1f}{c['cost']:>11.6f}{c['if_paid']:>11.6f}")
        t = self.totals()
        lines.append(f"   {'TOTAL':<19}{t['prompt']:>7}{t['completion']:>8}{t['seconds']:>6.1f}"
                     f"{t['cost']:>11.6f}{t['if_paid']:>11.6f}")
        lines.append(f"   {t['requests']} requests · {t['prompt'] + t['completion']} tokens · "
                     f"actual cost ${t['cost']:.6f} · if served by paid models ${t['if_paid']:.6f}")
        return "\n".join(lines)


usage = Usage()


def _cost(raw) -> float:
    try:
        return float(raw.headers.get("x-litellm-response-cost") or 0)
    except ValueError:
        return 0.0


def chat_call(messages: list, model: str = None, kind: str = "chat", **kwargs):
    """Chat completion that records usage. Returns the full message (content, tool_calls)."""
    model = model or CHAT_MODEL
    kwargs.setdefault("max_tokens", 800)
    start = time.time()
    raw = get_client().chat.completions.with_raw_response.create(model=model, messages=messages, **kwargs)
    resp = raw.parse()
    u = resp.usage
    usage.add(kind, model, resp.model or model, u.prompt_tokens if u else 0, u.completion_tokens if u else 0,
              time.time() - start, _cost(raw))
    return resp.choices[0].message


def chat(messages: list, **kwargs) -> str:
    return chat_call(messages, **kwargs).content or ""


def embed_call(texts: list, kind: str = "embed") -> list:
    start = time.time()
    raw = get_client().embeddings.with_raw_response.create(model=EMBED_MODEL, input=texts)
    resp = raw.parse()
    tokens = resp.usage.prompt_tokens if resp.usage else 0
    usage.add(kind, EMBED_MODEL, resp.model or EMBED_MODEL, tokens, 0, time.time() - start, _cost(raw))
    return [d.embedding for d in resp.data]
