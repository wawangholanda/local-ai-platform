"""FastAPI application for the local AI API gateway."""

import os

from fastapi import FastAPI, HTTPException

from local_ai_platform.ollama_client import OllamaClient, OllamaError
from local_ai_platform.api.schemas import ChatRequest, ChatResponse


app = FastAPI(
    title="Local AI API",
    version="0.1.0",
)


ollama_client = OllamaClient(
    api_url=os.environ.get(
        "OLLAMA_API_URL",
        "http://ollama:11434/api/chat",
    ),
    model=os.environ.get(
        "OLLAMA_MODEL",
        "qwen3.5:2b-q4_K_M",
    ),
)


@app.get("/health")
def health() -> dict[str, str]:
    """Return service health status."""
    return {"status": "ok"}


@app.post("/api/chat", response_model=ChatResponse)
def chat(request: ChatRequest) -> ChatResponse:
    """Send a prompt to the local AI model."""
    try:
        answer = ollama_client.chat(request.prompt)
    except OllamaError as exc:
        raise HTTPException(
            status_code=502,
            detail=str(exc),
        ) from exc

    return ChatResponse(
        answer=answer,
        model=ollama_client.model,
    )
