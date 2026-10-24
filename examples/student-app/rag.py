"""RAG (retrieval-augmented generation) over your own files.

  build_index("sample_notes")  -> reads .txt/.md/.pdf, splits into chunks, embeds them, saves .index/index.json
  answer("question")           -> finds the most relevant chunks and answers from them, citing sources [1], [2]
"""
import json
import math
from pathlib import Path

from common import EMBED_MODEL, chat, embed_call

INDEX_FILE = Path(".index/index.json")
CHUNK_CHARS = 800      # about 200 tokens per chunk
OVERLAP_CHARS = 150    # keep some context across chunk boundaries
BATCH = 64             # texts per embeddings request (one request counts once against the rate limit)


def load_documents(folder: str) -> list:
    """Return [(source_name, text)] for every .txt, .md and .pdf file under folder."""
    docs = []
    for path in sorted(Path(folder).rglob("*")):
        if path.suffix.lower() in (".txt", ".md"):
            docs.append((path.name, path.read_text(encoding="utf-8", errors="ignore")))
        elif path.suffix.lower() == ".pdf":
            from pypdf import PdfReader  # only needed for PDFs
            pages = [p.extract_text() or "" for p in PdfReader(str(path)).pages]
            docs.append((path.name, "\n\n".join(pages)))
    return docs


def split_into_chunks(text: str) -> list:
    """Split on paragraphs, packing them into chunks of about CHUNK_CHARS with a small overlap."""
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    chunks, current = [], ""
    for para in paragraphs:
        if current and len(current) + len(para) > CHUNK_CHARS:
            chunks.append(current)
            current = current[-OVERLAP_CHARS:] + "\n\n" + para
        else:
            current = (current + "\n\n" + para) if current else para
    if current:
        chunks.append(current)
    return chunks


def embed(texts: list, kind: str = "embed") -> list:
    vectors = []
    for i in range(0, len(texts), BATCH):
        vectors.extend(embed_call(texts[i:i + BATCH], kind=kind))
    return vectors


def build_index(folder: str) -> int:
    chunks = [(name, c) for name, text in load_documents(folder) for c in split_into_chunks(text)]
    if not chunks:
        raise SystemExit(f"No .txt/.md/.pdf content found in {folder}")
    vectors = embed([c for _, c in chunks], kind="index")
    INDEX_FILE.parent.mkdir(exist_ok=True)
    INDEX_FILE.write_text(json.dumps({
        "embed_model": EMBED_MODEL,
        "chunks": [{"source": s, "text": t, "vector": v} for (s, t), v in zip(chunks, vectors)],
    }))
    return len(chunks)


def cosine(a: list, b: list) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    return dot / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)))


def search(question: str, k: int = 4) -> list:
    """Return the k most relevant chunks as [{source, text, score}]."""
    if not INDEX_FILE.exists():
        raise SystemExit("No index yet - run:  python app.py index sample_notes")
    index = json.loads(INDEX_FILE.read_text())
    if index["embed_model"] != EMBED_MODEL:
        raise SystemExit(f"Index was built with '{index['embed_model']}', not '{EMBED_MODEL}'. Re-run index.")
    q = embed([question], kind="search")[0]
    scored = [dict(source=c["source"], text=c["text"], score=cosine(q, c["vector"])) for c in index["chunks"]]
    return sorted(scored, key=lambda c: c["score"], reverse=True)[:k]


def answer(question: str, k: int = 4) -> tuple:
    """Answer from the notes. Returns (answer_text, sources)."""
    hits = search(question, k)
    context = "\n\n".join(f"[{i}] ({h['source']}) {h['text']}" for i, h in enumerate(hits, 1))
    messages = [
        {"role": "system", "content": (
            "Answer using ONLY the numbered context below. Cite sources like [1] or [2]. "
            "If the answer isn't in the context, say you don't know.\n\nContext:\n" + context)},
        {"role": "user", "content": question},
    ]
    return chat(messages, kind="rag"), hits
