#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK_START="$ROOT_DIR/quick-start.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

helper="$(sed -n '/^extract_tailscale_ipv4()/,/^}/p' "$QUICK_START")"
[[ -n "$helper" ]] || fail "IPv4 extraction helper not found"

test_extract() {
  local description="$1" input="$2" expected_rc="$3" expected_output="${4:-}"
  local actual="" rc=0

  actual="$(bash -c "$helper"$'\n''extract_tailscale_ipv4 "$1"' _ "$input" 2>/dev/null)" || rc=$?

  if [[ "$rc" -ne "$expected_rc" || "$actual" != "$expected_output" ]]; then
    printf 'FAIL: %s (rc=%s, output=%q)\n' "$description" "$rc" "$actual" >&2
    exit 1
  fi

  pass "$description"
}

test_extract \
  'Extracts one IP from Ansible output' \
  $'ai-server | CHANGED | rc=0 >>\n100.100.83.33' \
  0 '100.100.83.33'

test_extract \
  'Rejects output without an IP' \
  'mock: no IPv4' \
  1 ''

test_extract \
  'Rejects multiple IP addresses as ambiguous' \
  $'100.100.83.33\n100.100.83.34' \
  1 ''

test_extract \
  'Extracts one IP-shaped candidate for separate validation' \
  '999.999.999.999' \
  0 '999.999.999.999'

printf '\n%s\n' 'All IPv4 parser tests passed.'
