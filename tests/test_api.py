"""Unit tests for the FastAPI gateway; no live Ollama server required."""

import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from local_ai_platform.api.main import app
from local_ai_platform.ollama_client import OllamaError


class LocalAIAPITests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)

    def test_health_returns_ok(self):
        response = self.client.get("/health")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "ok"})

    def test_empty_prompt_is_rejected(self):
        response = self.client.post(
            "/api/chat",
            json={"prompt": ""},
        )

        self.assertEqual(response.status_code, 422)

    def test_whitespace_prompt_is_rejected(self):
        response = self.client.post(
            "/api/chat",
            json={"prompt": "   "},
        )

        self.assertEqual(response.status_code, 422)

    @patch("local_ai_platform.api.main.ollama_client.chat")
    def test_chat_returns_answer_and_model(self, mock_chat):
        mock_chat.return_value = "API siap."

        response = self.client.post(
            "/api/chat",
            json={"prompt": "Balas: API siap."},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "answer": "API siap.",
                "model": "qwen3.5:2b-q4_K_M",
            },
        )
        mock_chat.assert_called_once_with("Balas: API siap.")

    @patch("local_ai_platform.api.main.ollama_client.chat")
    def test_ollama_error_returns_502(self, mock_chat):
        mock_chat.side_effect = OllamaError("Ollama unavailable")

        response = self.client.post(
            "/api/chat",
            json={"prompt": "Halo"},
        )

        self.assertEqual(response.status_code, 502)
        self.assertEqual(
            response.json(),
            {"detail": "Ollama unavailable"},
        )


if __name__ == "__main__":
    unittest.main()
