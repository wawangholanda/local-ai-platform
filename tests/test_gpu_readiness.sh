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

  mkdir -p "$fixture"

  python3 - "$ROOT_DIR/quick-start.sh" "$fixture/quick-start.sh" <<'PY'
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
source = source_path.read_text()

start = "ensure_gpu_ready() {\n"
end = "\nsetup_workstation() {\n"

if source.count(start) != 1 or source.count(end) != 1:
    raise SystemExit("Fungsi ensure_gpu_ready() atau marker setup tidak unik.")

function_body = source.split(start, 1)[1].split(end, 1)[0]
function = start + function_body + "\n"
# Test-only adaptation: answers are piped, so emulate an interactive terminal.
function = function.replace(
    "if [[ ! -t 0 ]]; then",
    'if [[ "${MOCK_NONINTERACTIVE:-0}" == 1 ]]; then',
    1,
)


target_path.write_text(r'''#!/usr/bin/env bash
set -euo pipefail

''' + function + r'''
verify_count=0
verify_gpu() {
  verify_count=$((verify_count + 1))
  printf 'verify_gpu:%s\n' "$verify_count" >> "$MOCK_LOG"

  case "${MOCK_GPU_MODE:-ready}" in
    ready)
      return 0
      ;;
    fail)
      return 1
      ;;
    fail-then-ready)
      [[ "$verify_count" -ge 2 ]]
      ;;
    *)
      return 2
      ;;
  esac
}

run_ansible() {
  printf 'run_ansible' >> "$MOCK_LOG"
  printf ' <%s>' "$@" >> "$MOCK_LOG"
  printf '\n' >> "$MOCK_LOG"

  # Semua pemanggilan Ansible dimock; tidak ada koneksi ke host sungguhan.
  return "${MOCK_REBOOT_STATUS:-0}"
}

log() {
  printf 'log:%s\n' "$*" >> "$MOCK_LOG"
}

ensure_gpu_ready
''')
PY
}

run_case() {
  local name="$1"
  local mode="$2"
  local answer="$3"
  local expected_status="$4"
  local reboot_status="${5:-0}"
  local fixture="$TMP_DIR/$name"
  local log_file="$TMP_DIR/$name.log"
  local status=0

  make_fixture "$fixture"

  if printf '%s\n' "$answer" |
    MOCK_LOG="$log_file" \
    MOCK_GPU_MODE="$mode" \
    MOCK_REBOOT_STATUS="$reboot_status" \
    bash "$fixture/quick-start.sh" >"$TMP_DIR/$name.out" 2>&1; then
    status=0
  else
    status=$?
  fi

  [[ "$status" -eq "$expected_status" ]] ||
    fail "$name: status $status, diharapkan $expected_status"

  printf '%s' "$log_file"
}

# 1. GPU sudah siap: tidak boleh reboot.
log_file="$(run_case gpu-ready ready '' 0)"
grep -qx 'verify_gpu:1' "$log_file" ||
  fail "GPU siap: pemeriksaan awal tidak tercatat"
if grep -q '^run_ansible' "$log_file"; then
  fail "GPU siap: Ansible tidak boleh dipanggil untuk reboot"
fi
pass "GPU sudah siap: reboot dilewati"

# 2. GPU gagal dan pengguna menolak: tidak boleh reboot.
log_file="$(run_case decline fail n 1)"
grep -qx 'verify_gpu:1' "$log_file" ||
  fail "Penolakan: pemeriksaan GPU tidak tercatat"
if grep -q '^run_ansible' "$log_file"; then
  fail "Penolakan: reboot tidak boleh dijalankan"
fi
pass "Pengguna menolak: proses berhenti tanpa reboot"

# 3. GPU gagal, pengguna setuju, reboot sukses, GPU siap.
log_file="$(run_case approve fail-then-ready y 0)"
[[ "$(grep -c '^verify_gpu:' "$log_file")" -eq 2 ]] ||
  fail "Persetujuan: seharusnya ada dua pemeriksaan GPU"
grep -q '^run_ansible .*ansible.builtin.reboot' "$log_file" ||
  fail "Persetujuan: perintah reboot Ansible tidak tercatat"
pass "Pengguna setuju: reboot dimock dan GPU diverifikasi ulang"

# 4. Reboot gagal: proses harus berhenti.
log_file="$(run_case reboot-failure fail y 1 1)"
grep -q '^run_ansible .*ansible.builtin.reboot' "$log_file" ||
  fail "Reboot gagal: perintah reboot tidak tercatat"
[[ "$(grep -c '^verify_gpu:' "$log_file")" -eq 1 ]] ||
  fail "Reboot gagal: pemeriksaan GPU tidak boleh dilanjutkan"
pass "Reboot gagal: proses berhenti tanpa validasi lanjutan"

printf '\n%s\n' 'Semua tes GPU readiness lulus.'
