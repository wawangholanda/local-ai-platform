# Ollama API

This project provides a private, self-hosted Ollama API for applications
running on the Docker `ai_backend` network.

## Architecture and security

- API endpoint inside Docker: `http://ollama:11434`
- Chat endpoint: `POST /api/chat`
- Default model: `qwen3.5:2b-q4_K_M`
- Ollama API is not published on a host port.
- Applications on `ai_backend` can reach Ollama by its Docker service/container
  name, `ollama`.
- Do not expose port `11434` to the LAN or the public internet just to run tests.

The Open WebUI service uses the same backend network and connects to Ollama
internally.

## Example request

Run this from a container connected to `ai_backend`:

```bash
docker run --rm --network ai_backend curlimages/curl:8.12.1 \
  -sS http://ollama:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.5:2b-q4_K_M",
    "messages": [
      {"role": "user", "content": "Balas tepat: API siap."}
    ],
    "stream": false,
    "think": false,
    "options": {"num_predict": 128}
  }'
```

Important request fields:

- `stream: false` requests one complete JSON response.
- `think: false` requests a response without the model's thinking mode.
  Verify this behavior when changing the Ollama version or model.
- `options.num_predict` limits generated tokens. A limit that is too small
  may stop generation before a useful final answer is produced.

For application integrations, consume `message.content` as the final answer.
Do not depend on or log the `message.thinking` field.

## Smoke test

The repository includes `tests/ollama_api_smoke.py`. It uses only the Python
standard library and checks that the API returns a non-empty final answer
with `done_reason` equal to `stop`.

Copy the script to the server from the workstation repository:

```bash
ansible ai_servers -e '{"ansible_become": false}' \
  -m ansible.builtin.copy \
  -a 'src=tests/ollama_api_smoke.py dest=/tmp/ollama_api_smoke.py mode=0644'
```

Run it on the AI server in a temporary Python container connected to the
internal Docker network:

```bash
docker run --rm \
  --network ai_backend \
  -v /tmp/ollama_api_smoke.py:/tmp/ollama_api_smoke.py:ro \
  -e OLLAMA_API_URL=http://ollama:11434/api/chat \
  python:3.11-slim \
  python /tmp/ollama_api_smoke.py
```

Optional environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `OLLAMA_API_URL` | `http://ollama:11434/api/chat` | Chat API URL |
| `OLLAMA_MODEL` | `qwen3.5:2b-q4_K_M` | Model to test |
| `OLLAMA_TIMEOUT` | `60` | Request timeout in seconds |
| `OLLAMA_NUM_PREDICT` | `128` | Maximum generated tokens |

A successful run prints a summary and exits with status `0`. The test fails
if the request fails, the final answer is empty, or `done_reason` is not
`stop`.

## Recorded validation

On 2026-10-13, the smoke test passed against the running `qwen3.5:2b-q4_K_M`
model using Ollama image version `0.40.3`.

Observed result:

- Final answer: `API siap.`
- `done_reason`: `stop`
- `eval_count`: `4`
- Elapsed time: approximately `3.03` seconds

This is a single smoke-test observation, not a performance benchmark.
Re-run the test after changing the model, Ollama image, or API configuration.
