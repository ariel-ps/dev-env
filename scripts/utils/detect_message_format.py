#!/usr/bin/env python3
"""
Detect the LLM provider format of a message or message list.
Supports: OpenAI, Anthropic/Claude, LangChain, and Gemini formats.

Usage:
    python detect_message_format.py '{"role": "user", "content": "hi"}'
    echo '{"role": "user", "content": "hi"}' | python detect_message_format.py
"""

import json
import sys
from dataclasses import dataclass
from typing import Any

from langchain_core.messages import (
    AIMessage,
    HumanMessage,
    SystemMessage,
    ToolMessage,
    convert_to_messages,
)


@dataclass
class DetectionResult:
    format: str
    confidence: str  # "high" | "medium" | "low"
    reason: str
    lc_messages: list | None = None


def _is_openai_message(obj: dict) -> bool:
    valid_roles = {"user", "assistant", "system", "tool", "function", "developer"}
    if "role" not in obj or obj["role"] not in valid_roles:
        return False
    # OpenAI content is a string, None, or list of content parts with "type"
    content = obj.get("content")
    if content is None or isinstance(content, str):
        return True
    if isinstance(content, list):
        return all(isinstance(p, dict) and "type" in p for p in content)
    return False


def _is_anthropic_message(obj: dict) -> bool:
    valid_roles = {"user", "assistant"}
    if "role" not in obj or obj["role"] not in valid_roles:
        return False
    content = obj.get("content")
    # Anthropic's structured content blocks always have "type"
    if isinstance(content, list):
        anthropic_types = {"text", "image", "tool_use", "tool_result", "document"}
        return all(
            isinstance(p, dict) and p.get("type") in anthropic_types for p in content
        )
    # Plain string is valid for both — not distinctive on its own
    return isinstance(content, str)


def _is_langchain_message(obj: dict) -> bool:
    lc_types = {"human", "ai", "system", "tool", "function", "chat"}
    return obj.get("type") in lc_types and "content" in obj


def _is_gemini_message(obj: dict) -> bool:
    valid_roles = {"user", "model"}
    if "role" not in obj or obj["role"] not in valid_roles:
        return False
    parts = obj.get("parts")
    return isinstance(parts, list)


def _try_convert_lc(data: Any) -> list | None:
    try:
        msgs = convert_to_messages(data if isinstance(data, list) else [data])
        return msgs
    except Exception:
        return None


def detect_single(obj: dict) -> DetectionResult:
    # LangChain is unambiguous — has "type" field with LC type names
    if _is_langchain_message(obj):
        lc = _try_convert_lc(obj)
        return DetectionResult("LangChain", "high", '"type" field matches LangChain message schema', lc)

    # Gemini uses "parts" instead of "content"
    if _is_gemini_message(obj):
        return DetectionResult("Gemini", "high", '"parts" array with "user"/"model" roles matches Gemini format', None)

    anthropic = _is_anthropic_message(obj)
    openai = _is_openai_message(obj)

    if anthropic and isinstance(obj.get("content"), list):
        # Structured content blocks → Anthropic
        lc = _try_convert_lc(obj)
        return DetectionResult("Anthropic", "high", "Structured content blocks with Anthropic types (text/image/tool_use/tool_result)", lc)

    if openai and obj.get("role") in {"tool", "function"}:
        # tool/function role is OpenAI-specific
        lc = _try_convert_lc(obj)
        return DetectionResult("OpenAI", "high", f'"role": "{obj["role"]}" is an OpenAI-specific role', lc)

    if openai and obj.get("role") in {"user", "assistant", "system"}:
        lc = _try_convert_lc(obj)
        return DetectionResult(
            "OpenAI or Anthropic",
            "medium",
            f'"role": "{obj["role"]}" with string content is valid in both OpenAI and Anthropic formats',
            lc,
        )

    return DetectionResult("Unknown", "low", "No known format pattern matched", None)


def detect_list(messages: list) -> DetectionResult:
    if not messages or not all(isinstance(m, dict) for m in messages):
        return DetectionResult("Unknown", "low", "Not a list of message objects", None)

    results = [detect_single(m) for m in messages]
    formats = {r.format for r in results}

    # All agree → high confidence
    if len(formats) == 1:
        fmt = next(iter(formats))
        lc = _try_convert_lc(messages)
        return DetectionResult(fmt, "high", f"All {len(messages)} messages match {fmt} format", lc)

    # Mixed — pick most specific
    priority = ["LangChain", "Gemini", "Anthropic", "OpenAI", "OpenAI or Anthropic"]
    for f in priority:
        if f in formats:
            lc = _try_convert_lc(messages)
            return DetectionResult(f, "medium", f"Mixed signals across messages; dominant format is {f}", lc)

    return DetectionResult("Unknown", "low", "Mixed formats with no clear winner", None)


def detect(raw: str) -> DetectionResult:
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        return DetectionResult("Unknown", "low", f"Input is not valid JSON: {e}", None)

    if isinstance(data, list):
        return detect_list(data)
    if isinstance(data, dict):
        return detect_single(data)

    return DetectionResult("Unknown", "low", "Input is not a JSON object or array", None)


def lc_type_name(msg) -> str:
    return type(msg).__name__


def main():
    if len(sys.argv) > 1:
        raw = " ".join(sys.argv[1:])
    elif not sys.stdin.isatty():
        raw = sys.stdin.read().strip()
    else:
        print("Usage: detect_message_format.py '<json message>'", file=sys.stderr)
        sys.exit(1)

    result = detect(raw)

    print(f"Format     : {result.format}")
    print(f"Confidence : {result.confidence}")
    print(f"Reason     : {result.reason}")

    if result.lc_messages:
        print(f"LangChain  : {[lc_type_name(m) for m in result.lc_messages]}")


if __name__ == "__main__":
    main()
