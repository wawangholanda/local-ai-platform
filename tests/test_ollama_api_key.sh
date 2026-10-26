#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

QUICK_START_PATH="$ROOT_DIR/quick-start.sh" \
FUNCTION_OUTPUT="$TMP_DIR/load_env_function.sh" \
python3 <<'PY'
import os
from pathlib import Path

source = Path(os.environ["QUICK_START_PATH"]).read_text()
start_marker = "load_env() {\n"
end_marker = "\n}\n\npreflight() {"

start = source.find(start_marker)
end = source.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("Unable to extract load_env().")

Path(os.environ["FUNCTION_OUTPUT"]).write_text(source[start:end + 2] + "\n")
PY

cd "$TMP_DIR"
source "$TMP_DIR/load_env_function.sh"

export ENV_FILE="$TMP_DIR/custom/.env"
mkdir -p "$(dirname "$ENV_FILE")"

cat > "$ENV_FILE" <<'ENV'
CLOUDFLARE_API_TOKEN=dummy-test-token-123
OPEN_WEBUI_DOMAIN=chat.example.org
ENV

exec </dev/null

load_env >"$TMP_DIR/output.log" 2>&1 ||
  fail "Key generation failed"

key="$(sed -n 's/^OLLAMA_API_KEY=//p' "$ENV_FILE")"
[[ "$key" =~ ^[a-fA-F0-9]{64}$ ]] ||
  fail "Generated key is missing or has an invalid format"
pass "Missing key is generated and persisted"

if grep -Fq -- "$key" "$TMP_DIR/output.log"; then
  fail "Key value appeared in command output"
fi
pass "Key value is not printed"

[[ "$(stat -c '%a' "$ENV_FILE")" == "600" ]] ||
  fail "Configuration file permission is not 600"

inode_before="$(stat -c '%i' "$ENV_FILE")"
load_env >"$TMP_DIR/output.log" 2>&1 ||
  fail "Second load failed"
key_after="$(sed -n 's/^OLLAMA_API_KEY=//p' "$ENV_FILE")"

[[ "$key_after" == "$key" ]] ||
  fail "Key changed on second load"
[[ "$(stat -c '%i' "$ENV_FILE")" == "$inode_before" ]] ||
  fail "Identical configuration file was replaced"
pass "Key is stable and identical configuration is not rewritten"

printf 'OLLAMA_API_KEY=invalid\n' >> "$ENV_FILE"
load_env >"$TMP_DIR/output.log" 2>&1 ||
  fail "Invalid key recovery failed"
recovered_key="$(sed -n 's/^OLLAMA_API_KEY=//p' "$ENV_FILE")"

[[ "$recovered_key" =~ ^[a-fA-F0-9]{64}$ ]] ||
  fail "Invalid key was not replaced with a valid key"
[[ "$recovered_key" != "invalid" ]] ||
  fail "Invalid key was retained"
pass "Malformed key is replaced"

[[ "$(stat -c '%a' "$ENV_FILE")" == "600" ]] ||
  fail "Configuration permission changed"
pass "Configuration permissions remain 600"

printf '\n%s\n' 'All Ollama API key tests passed.'
