"""Tool calling: the model decides to call Python functions, we run them, and it uses the results.

This loop is the core of every "LLM agent". Tools here:
  calculator(expression)  - exact arithmetic (models are bad at maths)
  search_notes(query)     - looks things up in your indexed notes (see rag.py)
  current_time()          - today's date and time
"""
import ast
import datetime
import json
import operator

from common import chat_call

TOOLS = [
    {"type": "function", "function": {
        "name": "calculator",
        "description": "Evaluate an arithmetic expression exactly, e.g. '12.5 * 4 + 3'.",
        "parameters": {"type": "object", "properties": {"expression": {"type": "string"}},
                       "required": ["expression"]}}},
    {"type": "function", "function": {
        "name": "search_notes",
        "description": "Search the course notes and return the most relevant passages.",
        "parameters": {"type": "object", "properties": {"query": {"type": "string"}},
                       "required": ["query"]}}},
    {"type": "function", "function": {
        "name": "current_time",
        "description": "Get the current date and time.",
        "parameters": {"type": "object", "properties": {}}}},
]

_OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv,
        ast.Pow: operator.pow, ast.Mod: operator.mod, ast.USub: operator.neg, ast.UAdd: operator.pos}


def calculator(expression: str) -> str:
    """Safe arithmetic: only numbers and + - * / ** % (no eval of arbitrary code)."""
    def ev(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.BinOp) and type(node.op) in _OPS:
            return _OPS[type(node.op)](ev(node.left), ev(node.right))
        if isinstance(node, ast.UnaryOp) and type(node.op) in _OPS:
            return _OPS[type(node.op)](ev(node.operand))
        raise ValueError("only numbers and + - * / ** % are allowed")
    try:
        return str(ev(ast.parse(expression, mode="eval").body))
    except Exception as e:  # report errors back to the model instead of crashing
        return f"error: {e}"


def search_notes(query: str) -> str:
    from rag import search
    try:
        return "\n\n".join(f"({h['source']}) {h['text']}" for h in search(query, k=3))
    except SystemExit as e:
        return f"error: {e}"


def current_time() -> str:
    return datetime.datetime.now().strftime("%A %d %B %Y, %H:%M")


FUNCTIONS = {"calculator": calculator, "search_notes": search_notes, "current_time": current_time}


def run(question: str, max_steps: int = 5, verbose: bool = True) -> str:
    messages = [
        {"role": "system", "content": "You are a helpful assistant. Use the tools when they help; "
                                      "always use calculator for arithmetic."},
        {"role": "user", "content": question},
    ]
    for _ in range(max_steps):
        msg = chat_call(messages, kind="agent", tools=TOOLS)
        if not msg.tool_calls:
            return msg.content or ""
        messages.append(msg.model_dump(exclude_none=True))
        for call in msg.tool_calls:
            args = json.loads(call.function.arguments or "{}")
            result = FUNCTIONS[call.function.name](**args) if call.function.name in FUNCTIONS else "unknown tool"
            if verbose:
                print(f"  [tool] {call.function.name}({args}) -> {result[:120]}")
            messages.append({"role": "tool", "tool_call_id": call.id, "content": result})
    return "Stopped after too many tool steps."
