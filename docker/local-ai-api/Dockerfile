FROM python:3.11-slim

WORKDIR /app

COPY docker/local-ai-api/requirements.txt /tmp/requirements.txt

RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY src /app/src

ENV PYTHONPATH=/app/src

EXPOSE 8000

CMD ["uvicorn", "local_ai_platform.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
