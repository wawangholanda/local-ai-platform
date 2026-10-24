#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYBOOK="$ROOT_DIR/ansible/playbooks/tailscale-client.yml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

[[ -f "$PLAYBOOK" ]] || fail "Playbook Tailscale tidak ditemukan"

python3 - "$PLAYBOOK" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()

decision_name = "- name: Decide which Tailscale path to use"
guard_name = (
    "- name: Refuse fresh login when an unconnected Tailscale state exists"
)
backup_guard_name = "- name: Refuse implicit recovery when a local Tailscale backup exists"

def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"PASS: {message}")

require(text.count(decision_name) == 1,
        "Tailscale decision task appears only once")
require(text.count(guard_name) == 1,
        "Existing-state guard appears only once")
require(text.count(backup_guard_name) == 1,
        "Local-backup guard remains present")

decision_pos = text.index(decision_name)
guard_pos = text.index(guard_name)
report_pos = text.index("- name: Report the Tailscale decision")
install_pos = text.index("- name: Install Tailscale client", decision_pos) if \
    "- name: Install Tailscale client" in text[decision_pos:] else -1

require(decision_pos < guard_pos < report_pos,
        "Guard is placed after the decision and before reporting")
require(
    "not (tailscale_server_state_stat.stat.exists | default(false) | bool)"
    in text,
    "Fresh login requires existing state to be absent",
)
require(
    "(tailscale_client_connected | bool)\n"
    "            or not (tailscale_server_state_stat.stat.exists | default(false) | bool)\n"
    "            or (tailscale_local_backup_stat.stat.exists | default(false) | bool)"
    in text,
    "Guard rejects existing state when the client is unhealthy and no local backup exists",
)
require(
    "run quick-start.sh restore-tailscale explicitly"
    in text,
    "Backup recovery still requires an explicit phase",
)
PY

printf '\n%s\n' '=== Syntax check ==='
.venv/bin/ansible-playbook \
  -i ansible/inventory/dev/hosts.yml \
  --syntax-check \
  "$PLAYBOOK"

printf '\n%s\n' 'All state-guard checks passed.'
