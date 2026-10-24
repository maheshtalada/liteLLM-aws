"""Structured output: turn free text into validated JSON.

Real apps rarely want prose back - they want fields they can store or act on. We ask for JSON,
validate it with Pydantic, and retry once with the error if the model gets it wrong.
"""
import json
from typing import List, Optional

from pydantic import BaseModel, Field, ValidationError

from common import chat


class Event(BaseModel):
    title: str
    date: Optional[str] = Field(None, description="ISO date YYYY-MM-DD, e.g. 2026-11-12")
    time: Optional[str] = Field(None, description="24-hour time HH:MM, e.g. 15:00")
    location: Optional[str] = None
    attendees: List[str] = []
    action_items: List[str] = []


def extract_event(text: str) -> Event:
    schema = json.dumps(Event.model_json_schema())
    messages = [
        {"role": "system", "content": "Extract the event from the user's text. Reply with ONLY a JSON object "
                                      f"matching this JSON schema (no markdown, no prose):\n{schema}"},
        {"role": "user", "content": text},
    ]
    for attempt in range(2):
        raw = chat(messages, kind="extract", response_format={"type": "json_object"}, temperature=0)
        raw = raw.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
        try:
            return Event.model_validate_json(raw)
        except ValidationError as e:
            # Show the model its mistake and ask again once.
            messages += [{"role": "assistant", "content": raw},
                         {"role": "user", "content": f"That JSON was invalid: {e}. Reply with corrected JSON only."}]
    raise ValueError("The model did not return valid JSON after a retry.")
