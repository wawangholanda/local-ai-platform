"""API request and response schemas."""

from pydantic import BaseModel, Field, field_validator


class ChatRequest(BaseModel):
    """Request payload for AI chat."""

    prompt: str = Field(
        min_length=1,
        description="User prompt sent to the local AI model.",
    )

    @field_validator("prompt")
    @classmethod
    def validate_prompt(cls, value: str) -> str:
        """Reject prompts that are empty or contain only whitespace."""
        value = value.strip()
        if not value:
            raise ValueError("Prompt must not be empty or whitespace.")
        return value


class ChatResponse(BaseModel):
    """Response payload from the AI service."""

    answer: str
    model: str
