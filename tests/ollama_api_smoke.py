#!/usr/bin/env python3
"""Minimal smoke test for a private Ollama chat API."""

import json
import os
import sys
import time
import urllib.error
import urllib.request


API_URL = os.environ.get(
    "OLLAMA_API_URL",
    "http://ollama:11434/api/chat",
)
MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.5:2b-q4_K_M")
TIMEOUT = int(os.environ.get("OLLAMA_TIMEOUT", "60"))
NUM_PREDICT = int(os.environ.get("OLLAMA_NUM_PREDICT", "128"))


def main() -> int:
    payload = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": "Balas tepat dengan teks: API siap.",
            }
        ],
        "stream": False,
        "think": False,
        "options": {"num_predict": NUM_PREDICT},
    }

    request = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    started = time.monotonic()

    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print(f"FAIL: Ollama returned HTTP {exc.code}", file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        print(f"FAIL: API request failed ({exc})", file=sys.stderr)
        return 1
    except (json.JSONDecodeError, UnicodeDecodeError):
        print("FAIL: API returned invalid JSON or text", file=sys.stderr)
        return 1

    elapsed = time.monotonic() - started
    message = result.get("message") or {}
    content = message.get("content", "")
    done_reason = result.get("done_reason")

    summary = {
        "model": result.get("model"),
        "content": content,
        "done_reason": done_reason,
        "eval_count": result.get("eval_count"),
        "elapsed_seconds": round(elapsed, 2),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))

    if not isinstance(content, str) or not content.strip():
        print("FAIL: model returned an empty final answer", file=sys.stderr)
        return 1

    if done_reason != "stop":
        print(
            f"FAIL: expected done_reason='stop', got {done_reason!r}",
            file=sys.stderr,
        )
        return 1

    print("PASS: Ollama chat API returned a completed, non-empty answer.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
