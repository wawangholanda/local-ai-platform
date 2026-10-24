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

make_fixture() {
  local fixture="$1"
  local tools_present="${2:-no}"

  mkdir -p "$fixture/.venv/bin"

  python3 - "$ROOT_DIR/quick-start.sh" "$fixture/quick-start.sh" <<'PY'
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
source = source_path.read_text()
marker = 'phase="${1:-all}"\n'

if source.count(marker) != 1:
    raise SystemExit("Titik injeksi dispatcher tidak unik.")

stubs = r'''
# Test-only overrides: never execute real provisioning functions.
setup_workstation() {
  printf 'setup\n' >> "$MOCK_LOG"
  [[ "${MOCK_SETUP_FAIL:-0}" != 1 ]] || return 1
  mkdir -p "$ROOT_DIR/.venv/bin"
  for tool in python ansible ansible-playbook ansible-galaxy; do
    printf '#!/bin/sh\nexit 0\n' > "$ROOT_DIR/.venv/bin/$tool"
    chmod +x "$ROOT_DIR/.venv/bin/$tool"
  done
}

unit_test() {
  printf 'test\n' >> "$MOCK_LOG"
  [[ "${MOCK_TEST_FAIL:-0}" != 1 ]]
}

preflight() {
  printf 'preflight\n' >> "$MOCK_LOG"
}

ansible_prepare() {
  printf 'ansible_prepare\n' >> "$MOCK_LOG"
}

configure_ssh_host_key_checking() {
  printf 'ssh_config\n' >> "$MOCK_LOG"
}

run_playbook() {
  printf 'playbook:%s\n' "$1" >> "$MOCK_LOG"
}

verify_gpu() {
  printf 'verify_gpu\n' >> "$MOCK_LOG"
}

validate() {
  printf 'validate\n' >> "$MOCK_LOG"
}
'''

target_path.write_text(source.replace(marker, stubs + "\n" + marker, 1))
PY

  if [[ "$tools_present" == yes ]]; then
    for tool in python ansible ansible-playbook ansible-galaxy; do
      printf '#!/bin/sh\nexit 0\n' > "$fixture/.venv/bin/$tool"
      chmod +x "$fixture/.venv/bin/$tool"
    done
  fi
}

run_default() {
  local fixture="$1"
  local log_file="$2"
  local setup_fail="${3:-0}"
  local test_fail="${4:-0}"
  local status=0

  if MOCK_LOG="$log_file" \
     MOCK_SETUP_FAIL="$setup_fail" \
     MOCK_TEST_FAIL="$test_fail" \
     bash "$fixture/quick-start.sh" >"$TMP_DIR/output" 2>&1; then
    status=0
  else
    status=$?
  fi

  printf '%s' "$status"
}

# Case 1: tools missing; setup then tests then all.
fixture="$TMP_DIR/missing-tools"
log_file="$TMP_DIR/missing.log"
make_fixture "$fixture" no
status="$(run_default "$fixture" "$log_file")"

[[ "$status" == 0 ]] || fail "Alur default dengan tool yang belum tersedia gagal"
[[ "$(sed -n '1p' "$log_file")" == setup ]] || fail "Setup bukan langkah pertama"
[[ "$(sed -n '2p' "$log_file")" == test ]] || fail "Tes tidak berjalan setelah setup"
grep -qx preflight "$log_file" || fail "Fase all tidak berlanjut setelah tes sukses"
grep -qx validate "$log_file" || fail "Validasi akhir fase all tidak berjalan"
pass "Tools missing: setup → test → all"

# Case 2: tools already available; setup must be skipped.
fixture="$TMP_DIR/tools-present"
log_file="$TMP_DIR/present.log"
make_fixture "$fixture" yes
status="$(run_default "$fixture" "$log_file")"

[[ "$status" == 0 ]] || fail "Default flow with available tools failed"
[[ "$(sed -n '1p' "$log_file")" == test ]] || fail "Test is not the first step when tools are available"
if grep -qx setup "$log_file"; then
  fail "Setup ran even though all tools are available"
fi
grep -qx preflight "$log_file" || fail "Fase all tidak berjalan"
pass "Tools available: skip setup, then test and all"

# Case 3: tests fail; all must not begin.
fixture="$TMP_DIR/test-failure"
log_file="$TMP_DIR/fail-test.log"
make_fixture "$fixture" yes
status="$(run_default "$fixture" "$log_file" 0 1)"

[[ "$status" != 0 ]] || fail "Kegagalan tes tidak menghentikan alur"
grep -qx test "$log_file" || fail "Tes tidak tercatat"
if grep -qx preflight "$log_file"; then
  fail "Provisioning started even though the tests failed"
fi
pass "Test failure: flow stops before all"

# Case 4: setup fails; tests and all must not begin.
fixture="$TMP_DIR/setup-failure"
log_file="$TMP_DIR/fail-setup.log"
make_fixture "$fixture" no
status="$(run_default "$fixture" "$log_file" 1 0)"

[[ "$status" != 0 ]] || fail "Kegagalan setup tidak menghentikan alur"
[[ "$(cat "$log_file")" == setup ]] || fail "Test or all phase ran after setup failed"
pass "Setup failure: flow stops before test and all"

# Case 5: explicit test phase must not start setup or all.
fixture="$TMP_DIR/explicit-test"
log_file="$TMP_DIR/explicit-test.log"
make_fixture "$fixture" no
status=0
if MOCK_LOG="$log_file" bash "$fixture/quick-start.sh" test \
    >"$TMP_DIR/output" 2>&1; then
  status=0
else
  status=$?
fi

[[ "$status" == 0 ]] || fail "Fase test eksplisit gagal"
[[ "$(cat "$log_file")" == test ]] || fail "Fase test memanggil setup atau all"
pass "Explicit test phase runs tests only"

printf '\n%s\n' 'All default-flow tests passed.'
