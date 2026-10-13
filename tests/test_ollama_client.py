"""Unit tests for the Ollama API client; no live server required."""

import json
import unittest
from unittest.mock import patch

from local_ai_platform.ollama_client import OllamaClient, OllamaError


def make_response(payload):
    """Create a minimal context-manager response mock."""
    response = unittest.mock.MagicMock()
    response.__enter__.return_value = response
    response.read.return_value = json.dumps(payload).encode("utf-8")
    return response


class OllamaClientTests(unittest.TestCase):
    def setUp(self):
        self.client = OllamaClient(
            api_url="http://ollama:11434/api/chat",
            model="qwen3.5:2b-q4_K_M",
        )

    @patch("local_ai_platform.ollama_client.urllib.request.urlopen")
    def test_chat_returns_final_content(self, mock_urlopen):
        mock_urlopen.return_value = make_response({
            "model": "qwen3.5:2b-q4_K_M",
            "message": {
                "role": "assistant",
                "content": "API siap.",
                "thinking": "This field must not be returned.",
            },
            "done": True,
            "done_reason": "stop",
        })

        answer = self.client.chat("Balas: API siap.")

        self.assertEqual(answer, "API siap.")
        request = mock_urlopen.call_args.args[0]
        payload = json.loads(request.data.decode("utf-8"))
        self.assertEqual(payload["model"], "qwen3.5:2b-q4_K_M")
        self.assertFalse(payload["stream"])
        self.assertFalse(payload["think"])
        self.assertEqual(payload["options"]["num_predict"], 256)
        mock_urlopen.assert_called_once()

    def test_empty_prompt_is_rejected(self):
        with self.assertRaises(ValueError):
            self.client.chat("   ")

    @patch("local_ai_platform.ollama_client.urllib.request.urlopen")
    def test_empty_answer_is_rejected(self, mock_urlopen):
        mock_urlopen.return_value = make_response({
            "message": {"content": ""},
            "done_reason": "stop",
        })

        with self.assertRaisesRegex(OllamaError, "empty final answer"):
            self.client.chat("Hello")

    @patch("local_ai_platform.ollama_client.urllib.request.urlopen")
    def test_incomplete_answer_is_rejected(self, mock_urlopen):
        mock_urlopen.return_value = make_response({
            "message": {"content": "Partial answer"},
            "done_reason": "length",
        })

        with self.assertRaisesRegex(OllamaError, "did not finish normally"):
            self.client.chat("Hello")

    @patch("local_ai_platform.ollama_client.urllib.request.urlopen")
    def test_http_error_is_reported(self, mock_urlopen):
        import urllib.error

        mock_urlopen.side_effect = urllib.error.HTTPError(
            self.client.api_url, 503, "Unavailable", {}, None
        )

        with self.assertRaisesRegex(OllamaError, "HTTP 503"):
            self.client.chat("Hello")

    @patch("local_ai_platform.ollama_client.urllib.request.urlopen")
    def test_invalid_json_is_reported(self, mock_urlopen):
        response = unittest.mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b"{invalid json"
        mock_urlopen.return_value = response

        with self.assertRaisesRegex(OllamaError, "invalid JSON"):
            self.client.chat("Hello")

    @patch("local_ai_platform.ollama_client.urllib.request.urlopen")
    def test_connection_error_is_reported(self, mock_urlopen):
        import urllib.error

        mock_urlopen.side_effect = urllib.error.URLError("connection refused")

        with self.assertRaisesRegex(OllamaError, "Could not connect"):
            self.client.chat("Hello")

    def test_invalid_configuration_is_rejected(self):
        with self.assertRaises(ValueError):
            OllamaClient(timeout=0)

        with self.assertRaises(ValueError):
            OllamaClient(model="  ")

        with self.assertRaises(ValueError):
            OllamaClient(num_predict=0)


if __name__ == "__main__":
    unittest.main()
