"""Small standard-library client for the private Ollama chat API."""

import json
import os
import urllib.error
import urllib.request
from typing import Any


DEFAULT_API_URL = os.environ.get(
    "OLLAMA_API_URL",
    "http://ollama:11434/api/chat",
)
DEFAULT_MODEL = os.environ.get(
    "OLLAMA_MODEL",
    "qwen3.5:2b-q4_K_M",
)
DEFAULT_TIMEOUT = 60


class OllamaError(RuntimeError):
    """Raised when the Ollama API request or response is invalid."""


class OllamaClient:
    """Client for Ollama's non-streaming /api/chat endpoint."""

    def __init__(
        self,
        api_url: str = DEFAULT_API_URL,
        model: str = DEFAULT_MODEL,
        timeout: float = DEFAULT_TIMEOUT,
        num_predict: int = 256,
    ) -> None:
        if not api_url.startswith(("http://", "https://")):
            raise ValueError("api_url must use HTTP or HTTPS")
        if not model.strip():
            raise ValueError("model must not be empty")
        if timeout <= 0:
            raise ValueError("timeout must be greater than zero")
        if num_predict < 1:
            raise ValueError("num_predict must be at least 1")

        self.api_url = api_url
        self.model = model
        self.timeout = timeout
        self.num_predict = num_predict

    def chat(self, prompt: str) -> str:
        """Send a prompt and return the model's final answer text."""
        if not isinstance(prompt, str) or not prompt.strip():
            raise ValueError("prompt must not be empty")

        payload: dict[str, Any] = {
            "model": self.model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
            "think": False,
            "options": {"num_predict": self.num_predict},
        }
        request = urllib.request.Request(
            self.api_url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with urllib.request.urlopen(
                request, timeout=self.timeout
            ) as response:
                result = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise OllamaError(
                f"Ollama returned HTTP {exc.code}"
            ) from exc
        except urllib.error.URLError as exc:
            raise OllamaError("Could not connect to Ollama API") from exc
        except TimeoutError as exc:
            raise OllamaError("Ollama API request timed out") from exc
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise OllamaError(
                "Ollama API request failed or returned invalid JSON"
            ) from exc

        if not isinstance(result, dict):
            raise OllamaError("Ollama API response must be a JSON object")

        message = result.get("message")
        if not isinstance(message, dict):
            raise OllamaError("Ollama API response has no valid message")

        content = message.get("content")
        if not isinstance(content, str) or not content.strip():
            raise OllamaError("Ollama returned an empty final answer")

        if result.get("done_reason") != "stop":
            raise OllamaError(
                "Ollama response did not finish normally "
                f"(done_reason={result.get('done_reason')!r})"
            )

        return content.strip()


def main() -> int:
    """Provide a simple command-line entry point."""
    import argparse
    import sys

    parser = argparse.ArgumentParser(
        description="Send a prompt to a private Ollama chat API."
    )
    parser.add_argument("prompt", help="Prompt to send to the model")
    parser.add_argument("--url", default=DEFAULT_API_URL, help="Chat API URL")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Model name")
    parser.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT,
        help="Request timeout in seconds",
    )
    parser.add_argument(
        "--num-predict", type=int, default=256,
        help="Maximum generated tokens",
    )
    args = parser.parse_args()

    try:
        client = OllamaClient(
            api_url=args.url,
            model=args.model,
            timeout=args.timeout,
            num_predict=args.num_predict,
        )
        print(client.chat(args.prompt))
    except (OllamaError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
