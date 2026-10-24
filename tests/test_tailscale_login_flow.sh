#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYBOOK="$ROOT_DIR/ansible/playbooks/tailscale-client.yml"
QUICK_START="$ROOT_DIR/quick-start.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

# Pemeriksaan statis: autentikasi interaktif hanya boleh dijalankan Bash.
if grep -Eq 'tailscale[[:space:]]+up|ansible\.builtin\.pause|Wait for interactive Tailscale authentication' "$PLAYBOOK"; then
  fail "Playbook masih menjalankan login atau pause interaktif"
fi
pass "Playbook tidak menjalankan tailscale up atau pause interaktif"

grep -q 'tailscale_auth_flow()' "$QUICK_START" ||
  fail "Fungsi autentikasi Bash tidak ditemukan"

grep -q 'restore-tailscale' "$PLAYBOOK" ||
  grep -q 'Refuse implicit recovery when a local Tailscale backup exists' "$PLAYBOOK" ||
  fail "Guard pemulihan backup tidak ditemukan"

# Ekstrak fungsi tanpa menjalankan dispatcher quick-start.sh.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

awk '
  /^tailscale_auth_flow\(\)[[:space:]]*\{/ { extracting=1 }
  /^backup_tailscale\(\)[[:space:]]*\{/ { extracting=0 }
  extracting { print }
' "$QUICK_START" > "$tmpdir/auth-function.sh"

grep -q '^tailscale_auth_flow()' "$tmpdir/auth-function.sh" ||
  fail "Gagal mengekstrak fungsi autentikasi"

# Driver menguji fungsi dalam subprocess terisolasi.
cat > "$tmpdir/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail

SCENARIO="${1:?scenario required}"
CALL_LOG="${2:?call log required}"
STATUS_COUNT=0

log() { :; }
fail() {
  printf 'EXPECTED_FAIL: %s\n' "$1" >&2
  exit 42
}
sleep() { :; }

run_ansible() {
  local arg="" i
  local -a args=("$@")

  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "-a" ]] && (( i + 1 < ${#args[@]} )); then
      arg="${args[$((i+1))]}"
      break
    fi
  done

  printf '%s\n' "$arg" >> "$CALL_LOG"

  case "$arg" in
    "tailscale status --json")
      # Persist the count across command-substitution subshells.
      local status_count_file="${CALL_LOG}.status-count"
      local status_count=0
      if [[ -f "$status_count_file" ]]; then
        status_count="$(cat "$status_count_file" | tr -d '[:space:]')"
      fi
      [[ "$status_count" =~ ^[0-9]+$ ]] || status_count=0
      status_count=$((status_count + 1))
      printf '%s\n' "$status_count" > "$status_count_file"

      case "$SCENARIO" in
        status-fail)
          echo "mock SSH/status failure" >&2
          return 1
          ;;
        unknown-state)
          printf '{"BackendState":"NeedsMachineAuth"}\n'
          ;;
        running-valid-ip|running-invalid-ip)
          printf '{"BackendState":"Running"}\n'
          ;;
        login-success)
          if (( status_count == 1 )); then
            printf '{"BackendState":"NeedsLogin"}\n'
          else
            printf '{"BackendState":"Running"}\n'
          fi
          ;;
        login-timeout|state-exists)
          printf '{"BackendState":"NeedsLogin"}\n'
          ;;
        *)
          echo "Unknown test scenario" >&2
          return 90
          ;;
      esac
      ;;
    "tailscale ip -4")
      case "$SCENARIO" in
        running-valid-ip|login-success)
          printf '100.100.83.33\n'
          ;;
        running-invalid-ip)
          printf '999.999.999.999\n'
          ;;
        *)
          printf 'mock: no IPv4\n' >&2
          return 1
          ;;
      esac
      ;;
    "if test -f /var/lib/tailscale/tailscaled.state; then echo TAILSCALE_STATE_EXISTS; else echo TAILSCALE_STATE_ABSENT; fi")
      case "$SCENARIO" in
        state-exists)
          printf 'TAILSCALE_STATE_EXISTS\n'
          ;;
        *)
          printf 'TAILSCALE_STATE_ABSENT\n'
          ;;
      esac
      ;;
    "tailscale up")
      if [[ "$SCENARIO" == "login-success" || "$SCENARIO" == "login-timeout" ]]; then
        printf 'To authenticate, visit: https://login.tailscale.com/a/mock\n'
      else
        echo "Unexpected tailscale up invocation" >&2
        return 91
      fi
      ;;
    *)
      printf 'Unexpected Ansible command: %s\n' "$arg" >&2
      return 92
      ;;
  esac
}

source "$FUNCTION_FILE"
tailscale_auth_flow
DRIVER

# Jalankan fungsi yang diekstrak dengan mock, bukan server sungguhan.
run_case() {
  local scenario="$1"
  local expected_rc="$2"
  local expected_up="$3"
  local log_file="$tmpdir/$scenario.calls"
  local output_file="$tmpdir/$scenario.output"
  local rc=0

  : > "$log_file"

  FUNCTION_FILE="$tmpdir/auth-function.sh" \
    bash "$tmpdir/driver.sh" "$scenario" "$log_file" \
    >"$output_file" 2>&1 || rc=$?

  if [[ "$rc" != "$expected_rc" ]]; then
    cat "$output_file" >&2
    fail "$scenario: exit code $rc, expected $expected_rc"
  fi

  local up_count
  up_count="$(grep -cFx 'tailscale up' "$log_file" || true)"
  if [[ "$up_count" != "$expected_up" ]]; then
    cat "$output_file" >&2
    cat "$log_file" >&2
    fail "$scenario: tailscale up called $up_count times, expected $expected_up"
  fi

  printf '%s\n' "$output_file"
}

out="$(run_case status-fail 42 0)"
grep -q 'Pemeriksaan status Tailscale gagal' "$out" ||
  fail "status-fail tidak menghasilkan pesan aman"
pass "Kegagalan pemeriksaan status tidak memicu login baru"

out="$(run_case unknown-state 42 0)"
grep -q 'BackendState tidak dikenali' "$out" ||
  fail "unknown-state tidak ditolak"
pass "BackendState tidak dikenal ditolak tanpa login baru"

out="$(run_case running-valid-ip 0 0)"
grep -q 'login baru dilewati' "$out" ||
  fail "Running dengan IPv4 valid tidak dikenali"
pass "Running dengan IPv4 valid melewati login"

out="$(run_case running-invalid-ip 42 0)"
grep -q 'IPv4 Tailscale tidak ditemukan' "$out" ||
  fail "IPv4 invalid tidak ditolak"
pass "Alamat yang bukan IPv4 Tailscale valid ditolak"

out="$(run_case state-exists 42 0)"
grep -q 'State Tailscale lama masih ada' "$out" ||
  fail "State lama tidak memblokir login baru"
pass "State lama memblokir tailscale up tanpa mengubah state server"

out="$(run_case login-success 0 1)"
grep -q 'login.tailscale.com/a/mock' "$out" ||
  fail "URL autentikasi tidak ditampilkan"
grep -q 'IPv4 telah terdeteksi' "$out" ||
  fail "Login sukses tidak terkonfirmasi"
pass "NeedsLogin memicu satu login dan polling sampai Running"

out="$(run_case login-timeout 42 1)"
grep -q 'belum terkonfirmasi setelah 5 menit' "$out" ||
  fail "Timeout autentikasi tidak dilaporkan"
pass "Login yang tidak selesai berakhir dengan timeout"

echo "Semua tes Tailscale login flow lulus."
