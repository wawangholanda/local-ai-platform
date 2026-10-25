#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYBOOK="$ROOT_DIR/ansible/playbooks/tailscale-state-backup.yml"

python3 - "$PLAYBOOK" <<'PYTEST'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()

def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"PASS: {message}")

def pos(fragment):
    i = text.find(fragment)
    if i < 0:
        raise SystemExit(f"FAIL: missing task or fragment: {fragment}")
    return i

service = pos("- name: Require the Tailscale service to be active")
backend = pos("- name: Require a readable Running backend")
ipv4_read = pos("- name: Read the Tailscale IPv4 address")
ipv4_guard = pos("- name: Require a valid Tailscale IPv4 address")
state = pos("- name: Inspect the current Tailscale state file")
fetch = pos("- name: Fetch Tailscale state into a new staging file")

require(service < backend < ipv4_read < ipv4_guard < state < fetch,
        "Health checks precede state inspection and backup fetch")
require(
    "BackendState" in text
    and 'tailscale_backup_status.stdout | default(\'\') | from_json).BackendState == "Running"' in text,
    "Backup requires BackendState Running from parsed status JSON",
)
require("systemctl" in text and "is-active" in text,
        "Backup checks that tailscaled is active")
require("tailscale_backup_ipv4.rc == 0" in text,
        "IPv4 command must succeed")
require("Refuse to overwrite an existing staging file" in text,
        "Existing staging file is rejected")
require("It was not modified or deleted." in text,
        "Existing staging file is preserved")
require("force: false" in text,
        "Publishing backup cannot overwrite canonical destination")
require("tailscale_backup_stat.stat.size | default(0) > 2" in text,
        "Existing canonical backup must be non-empty")
require("validate_checksum: true" in text,
        "Fetched state checksum is validated")

# Validation must run even when the remote state file is missing.
validation_start = pos("- name: Require a valid remote Tailscale state file")
validation_end = text.find("\\n    - name:", validation_start + 1)
if validation_end < 0:
    validation_end = len(text)
validation_task = text[validation_start:validation_end]

require("tailscale_state_stat.stat.exists" in validation_task,
        "Remote state assertion rejects a missing state file")
require("tailscale_state_stat.stat.isreg" in validation_task,
        "Remote state assertion rejects non-regular state files")
require("tailscale_state_stat.stat.size > 2" in validation_task,
        "Remote state assertion rejects state files of 2 bytes or less")
require(
    re.search(r"^\\s*when\\s*:", validation_task, re.MULTILINE) is None,
    "Remote state assertion is not skipped when the state file is missing",
)

line = next((x.strip() for x in text.splitlines() if "is match(" in x), None)
require(line is not None, "IPv4 regex exists")
pattern = line.split("is match('", 1)[1].rsplit("')", 1)[0]
valid = ["100.64.0.1", "100.100.83.33", "100.127.255.255"]
invalid = [
    "192.168.1.10", "100.63.255.255", "100.128.0.1",
    "100.100.256.1", "100.100.1.256", "100.100.001.002",
]
for ip in valid:
    require(re.fullmatch(pattern, ip) is not None, f"Valid IP accepted: {ip}")
for ip in invalid:
    require(re.fullmatch(pattern, ip) is None, f"Invalid IP rejected: {ip}")
PYTEST

printf '\n%s\n' '=== Ansible syntax check ==='
"$ROOT_DIR/.venv/bin/ansible-playbook" \
  -i "$ROOT_DIR/ansible/inventory/dev/hosts.yml" \
  --syntax-check "$PLAYBOOK"

printf '\n%s\n' 'All backup-guard checks passed.'
