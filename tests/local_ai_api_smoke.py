#!/usr/bin/env python3
"""Smoke test for the Local AI FastAPI gateway."""

import json
import os
import sys
import urllib.error
import urllib.request


BASE_URL = os.environ.get("LOCAL_AI_API_URL", "http://127.0.0.1:8000")
TIMEOUT = int(os.environ.get("LOCAL_AI_API_TIMEOUT", "180"))


def request_json(path: str, payload: dict | None = None) -> dict:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {} if data is None else {"Content-Type": "application/json"}
    request = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=data,
        headers=headers,
        method="GET" if data is None else "POST",
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.loads(response.read().decode("utf-8"))


def main() -> int:
    try:
        health = request_json("/health")
        if health.get("status") != "ok":
            raise ValueError(f"Unexpected health response: {health!r}")
        print("PASS: FastAPI health endpoint is healthy.")

        result = request_json(
            "/api/chat",
            {"prompt": "Reply with one short sentence saying the API is ready."},
        )
        answer = result.get("answer")
        model = result.get("model")
        if not isinstance(answer, str) or not answer.strip():
            raise ValueError("Gateway returned an empty answer.")
        if not isinstance(model, str) or not model.strip():
            raise ValueError("Gateway did not report a model.")

        print(json.dumps(
            {"model": model, "answer": answer},
            ensure_ascii=False,
            indent=2,
        ))
        print("PASS: FastAPI chat endpoint returned a non-empty answer.")
        return 0

    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
        OSError,
        ValueError,
        json.JSONDecodeError,
    ) as exc:
        print(f"FAIL: Local AI API smoke test failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
