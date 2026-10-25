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

tailscale_auth_flow() {
  printf 'tailscale_auth_flow\n' >> "$MOCK_LOG"
  [[ "${MOCK_TAILSCALE_AUTH_FAIL:-0}" != 1 ]]
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

assert_tailscale_auth_order() {
  local log_file="$1"
  local auth_count tailscale_line auth_line gpu_line

  auth_count="$(grep -c '^tailscale_auth_flow$' "$log_file" || true)"
  [[ "$auth_count" == 1 ]] ||
    fail "Tailscale authentication must run exactly once in all phase"

  tailscale_line="$(grep -n '^playbook:tailscale-client$' "$log_file" | cut -d: -f1)"
  auth_line="$(grep -n '^tailscale_auth_flow$' "$log_file" | cut -d: -f1)"
  gpu_line="$(grep -n '^playbook:gpu$' "$log_file" | cut -d: -f1)"

  [[ -n "$tailscale_line" && -n "$auth_line" && -n "$gpu_line" ]] ||
    fail "Required Tailscale/GPU steps were not recorded"

  (( tailscale_line < auth_line && auth_line < gpu_line )) ||
    fail "Tailscale authentication is not between tailscale-client and GPU"
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
assert_tailscale_auth_order "$log_file"
pass "Tools missing: setup → test → all, including Tailscale authentication"

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
assert_tailscale_auth_order "$log_file"
pass "Tools available: skip setup, then test and all, including Tailscale authentication"

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


# Case 6: successful authentication must precede proxy configuration.
fixture="$TMP_DIR/tailscale-phase"
log_file="$TMP_DIR/tailscale-phase.log"
make_fixture "$fixture" yes

if MOCK_LOG="$log_file" bash "$fixture/quick-start.sh" tailscale \
    >"$TMP_DIR/tailscale-phase.output" 2>&1; then
  :
else
  fail "Fase tailscale gagal meskipun autentikasi tiruan berhasil"
fi

expected="$(printf '%s\n' \
  ssh_config \
  preflight \
  playbook:bootstrap \
  playbook:tailscale-client \
  tailscale_auth_flow \
  playbook:open-webui-proxy)"
[[ "$(cat "$log_file")" == "$expected" ]] ||
  fail "Urutan autentikasi dan proxy pada fase tailscale salah"
pass "Tailscale phase: authentication succeeds before proxy configuration"

# Case 7: failed authentication must prevent proxy configuration.
log_file="$TMP_DIR/tailscale-auth-fail.log"
if MOCK_LOG="$log_file" MOCK_TAILSCALE_AUTH_FAIL=1 \
    bash "$fixture/quick-start.sh" tailscale \
    >"$TMP_DIR/tailscale-auth-fail.output" 2>&1; then
  fail "Fase tailscale seharusnya gagal jika autentikasi gagal"
fi

if grep -qx 'playbook:open-webui-proxy' "$log_file"; then
  fail "Proxy dijalankan setelah autentikasi gagal"
fi
grep -qx 'tailscale_auth_flow' "$log_file" ||
  fail "Autentikasi tidak tercatat pada kasus gagal"
pass "Tailscale phase: failed authentication prevents proxy configuration"

printf '\n%s\n' 'All default-flow tests passed.'
