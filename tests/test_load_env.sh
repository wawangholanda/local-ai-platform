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

# Extract only load_env(), without sourcing quick-start.sh or its dispatch.
QUICK_START_PATH="$ROOT_DIR/quick-start.sh" \
FUNCTION_OUTPUT="$TMP_DIR/load_env_function.sh" \
python3 <<'PY'
import os
from pathlib import Path

source = Path(os.environ["QUICK_START_PATH"]).read_text()
start_marker = "load_env() {\n"
end_marker = "\n}\n\npreflight() {"

start = source.find(start_marker)
if start < 0:
    raise SystemExit("Tidak menemukan awal load_env().")

end = source.find(end_marker, start)
if end < 0:
    raise SystemExit("Tidak menemukan batas akhir load_env().")

function = source[start:end + 2]
Path(os.environ["FUNCTION_OUTPUT"]).write_text(function + "\n")
PY

# All test files and configuration are isolated in TMP_DIR.
cd "$TMP_DIR"
# shellcheck disable=SC1091
source "$TMP_DIR/load_env_function.sh"

# Make load_env() fail rather than prompt for missing values.
# Its prompt guard checks whether stdin is a terminal.
exec </dev/null

export LOCAL_AI_ENV_FILE="$TMP_DIR/custom config/.env"
ENV_FILE="$LOCAL_AI_ENV_FILE"
mkdir -p -- "$(dirname -- "$ENV_FILE")"

# Dummy values only; never use the real .secrets/.env here.
cat > "$ENV_FILE" <<'ENV'
CLOUDFLARE_API_TOKEN=dummy-test-token-123
OPEN_WEBUI_DOMAIN=chat.example.org
ENV

load_env >/dev/null 2>&1 || fail "Failed to load valid configuration"
[[ "$(stat -c '%a' "$ENV_FILE")" == "600" ]] ||
  fail "Permission file bukan 600"
pass "Valid configuration and permissions 600"

# The second run must leave both content and inode unchanged.
cp -- "$ENV_FILE" "$TMP_DIR/expected.env"
inode_before="$(stat -c '%i' "$ENV_FILE")"

load_env >/dev/null 2>&1 || fail "Second invocation failed"

cmp -s "$TMP_DIR/expected.env" "$ENV_FILE" ||
  fail "File contents changed on the second invocation"
[[ "$(stat -c '%i' "$ENV_FILE")" == "$inode_before" ]] ||
  fail "File diganti meskipun kontennya identik"
pass "Idempotency: second invocation does not replace the file"

# Invalid domains must fail and leave the original content unchanged.
for invalid_domain in 'bad..example.org' '-bad.example.org' 'bad_domain.example.org'; do
  printf 'CLOUDFLARE_API_TOKEN=dummy-test-token-123\nOPEN_WEBUI_DOMAIN=%s\n' \
    "$invalid_domain" > "$ENV_FILE"
  cp -- "$ENV_FILE" "$TMP_DIR/expected.env"

  if (load_env >/dev/null 2>&1); then
    fail "Domain invalid diterima"
  fi

  cmp -s "$TMP_DIR/expected.env" "$ENV_FILE" ||
    fail "File changed when the invalid domain was rejected"
done
pass "Invalid domain is rejected without changing configuration"

# Placeholder domain must be rejected without interactive prompting.
cat > "$ENV_FILE" <<'ENV'
CLOUDFLARE_API_TOKEN=dummy-test-token-123
OPEN_WEBUI_DOMAIN=example.com
ENV
cp -- "$ENV_FILE" "$TMP_DIR/expected.env"

if (load_env >/dev/null 2>&1); then
  fail "Domain placeholder diterima"
fi

cmp -s "$TMP_DIR/expected.env" "$ENV_FILE" ||
  fail "File changed when the placeholder was rejected"
pass "Placeholder domain is rejected without changing configuration"

# Placeholder token must fail in non-interactive mode.
cat > "$ENV_FILE" <<'ENV'
CLOUDFLARE_API_TOKEN=your_token_here
OPEN_WEBUI_DOMAIN=chat.example.org
ENV
cp -- "$ENV_FILE" "$TMP_DIR/expected.env"

if (load_env >/dev/null 2>&1); then
  fail "Token placeholder diterima"
fi

cmp -s "$TMP_DIR/expected.env" "$ENV_FILE" ||
  fail "File changed when the placeholder token was rejected"
pass "Placeholder token is rejected without changing configuration"

printf '\n%s\n' 'All load_env() tests passed.'
