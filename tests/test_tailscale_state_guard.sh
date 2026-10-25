#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYBOOK="$ROOT_DIR/ansible/playbooks/tailscale-client.yml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

python3 - "$PLAYBOOK" <<'PYTEST'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()

def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"PASS: {message}")

require(text.count("- name: Decide which Tailscale path to use") == 1,
        "Decision task appears exactly once")
require("'NeedsLogin'" in text,
        "NeedsLogin is recognized explicitly")
require("Refuse recovery when an existing state has an unknown backend" in text,
        "Unknown backend state is guarded")
require("tailscaled.state.pre-fresh-login" not in text,
        "Client playbook does not quarantine existing state")
require("Move old Tailscale state into quarantine" not in text,
        "Client playbook does not move existing state")
require("Stop tailscaled before quarantining its state" not in text,
        "Client playbook does not stop the service for quarantine")
require("Verify published client backup matches its staging file" in text,
        "Backup verification remains in place")
require("Refuse implicit recovery when a local Tailscale backup exists" not in text,
        "Existing local backup no longer blocks fresh login by itself")
require(
    "tailscale_backend_state == 'NeedsLogin'" in text,
    "Fresh-login decision is limited to explicit NeedsLogin state",
)
require(
    "and (tailscale_client_connected | bool)" in text,
    "First backup requires a healthy, validated Tailscale connection",
)
require(
    "(tailscale_client_connected | bool)\n              or tailscale_backend_state == 'NeedsLogin'"
    not in text,
    "NeedsLogin alone cannot create the first local backup",
)
PYTEST

printf '\n%s\n' '=== Ansible syntax check ==='
"$ROOT_DIR/.venv/bin/ansible-playbook" \
  -i "$ROOT_DIR/ansible/inventory/dev/hosts.yml" \
  --syntax-check "$PLAYBOOK"

printf '\n%s\n' 'All state-guard checks passed.'
