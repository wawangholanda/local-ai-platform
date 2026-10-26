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

# Static check: interactive authentication must only be handled by Bash.
if grep -Eq 'tailscale[[:space:]]+up|ansible\.builtin\.pause|Wait for interactive Tailscale authentication' "$PLAYBOOK"; then
  fail "Playbook still performs login or interactive pauses"
fi
pass "Playbook does not run tailscale up or interactive pauses"

grep -q 'tailscale_auth_flow()' "$QUICK_START" ||
  fail "Bash authentication function not found"

grep -q 'Verify published client backup matches its staging file' "$PLAYBOOK" ||
  fail "Verified local state backup step not found"

if grep -Eq 'tailscaled\.state\.pre-fresh-login|Move old Tailscale state into quarantine|Require successful state quarantine before fresh login' "$PLAYBOOK"; then
  fail "Obsolete quarantine logic remains in the client playbook"
fi
pass "Client playbook does not quarantine existing state"

grep -q 'run_playbook tailscale-state-restore' "$QUICK_START" ||
  fail "Restore attempt is missing from the Bash authentication flow"

grep -q 'backup_tailscale' "$QUICK_START" ||
  fail "Backup call is missing from the authentication flow"

if grep -q 'Refuse implicit recovery when a local Tailscale backup exists' "$PLAYBOOK"; then
  fail "Obsolete guard still blocks fresh login when a local backup exists"
fi

# Extract the function without running the quick-start.sh dispatcher.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

awk '
  /^tailscale_auth_flow\(\)[[:space:]]*\{/ { extracting=1 }
  /^backup_tailscale\(\)[[:space:]]*\{/ { extracting=0 }
  extracting { print }
' "$QUICK_START" > "$tmpdir/auth-function.sh"

grep -q '^tailscale_auth_flow()' "$tmpdir/auth-function.sh" ||
  fail "Failed to extract the authentication function"

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

# Mock direct SSH so tests never contact a real server.
ssh() {
  printf '%s\n' 'tailscale up' >> "$CALL_LOG"
  case "$SCENARIO" in
    login-success|login-success-after-restore-failure|login-timeout|state-exists)
      printf '%s\n' 'To authenticate, visit: https://login.tailscale.com/a/mock'
      return 0
      ;;
    *)
      echo "Unexpected direct SSH invocation" >&2
      return 91
      ;;
  esac
}

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
        restore-success)
          if (( status_count == 1 )); then
            printf '{"BackendState":"NeedsLogin"}\n'
          else
            printf '{"BackendState":"Running"}\n'
          fi
          ;;
        login-success|login-success-after-restore-failure|state-exists)
          if (( status_count <= 2 )); then
            printf '{"BackendState":"NeedsLogin"}\n'
          else
            printf '{"BackendState":"Running"}\n'
          fi
          ;;
        login-timeout)
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
        running-valid-ip|restore-success|login-success|login-success-after-restore-failure|state-exists)
          printf 'ai-server | CHANGED | rc=0 >>\n100.100.83.33\n'
          ;;
        running-invalid-ip)
          printf 'ai-server | CHANGED | rc=0 >>\n999.999.999.999\n'
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
      if [[ "$SCENARIO" == "login-success" || "$SCENARIO" == "login-success-after-restore-failure" || "$SCENARIO" == "login-timeout" || "$SCENARIO" == "state-exists" ]]; then
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

run_playbook() {
  local playbook="${1:-}"
  printf 'playbook:%s\n' "$playbook" >> "$CALL_LOG"
  case "$SCENARIO" in
    restore-success)
      [[ "$playbook" == "tailscale-state-restore" ]] || return 90
      return 0
      ;;
    *)
      [[ "$playbook" == "tailscale-state-restore" ]] || return 90
      echo "mock restore unavailable: no usable backup" >&2
      return 1
      ;;
  esac
}

backup_tailscale() {
  printf '%s\n' 'backup_tailscale' >> "$CALL_LOG"
  return 0
}

source "$FUNCTION_FILE"
tailscale_auth_flow
DRIVER

# Run the extracted function with mocks, not against a real server.
run_case() {
  local scenario="$1"
  local expected_rc="$2"
  local expected_up="$3"
  local log_file="$tmpdir/$scenario.calls"
  local output_file="$tmpdir/$scenario.output"
  local rc=0

  : > "$log_file"

  mkdir -p "$tmpdir/.secrets"

  local inventory_file="$tmpdir/$scenario.inventory.yml"
  local password_file="$tmpdir/$scenario.sudo-password"

  cat > "$inventory_file" <<'INVENTORY'
all:
  children:
    ai_servers:
      hosts:
        ai_server:
          ansible_host: 192.0.2.10
          ansible_user: testuser
INVENTORY

  printf '%s\n' 'test-only-password' > "$password_file"
  chmod 600 "$password_file"

  ROOT_DIR="$tmpdir" \
    FUNCTION_FILE="$tmpdir/auth-function.sh" \
    INVENTORY_FILE="$inventory_file" \
    BECOME_PASSWORD_FILE="$password_file" \
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
grep -q 'Tailscale status check failed' "$out" ||
  fail "status-fail did not produce the expected safe message"
pass "Status-check failure does not trigger a new login"

out="$(run_case unknown-state 42 0)"
grep -q 'Unrecognized BackendState' "$out" ||
  fail "Unknown state was not rejected"
pass "Unknown BackendState is rejected without a new login"

out="$(run_case running-valid-ip 0 0)"
grep -q 'skipping restore and new login' "$out" ||
  fail "Running with a valid IPv4 address was not recognized"
pass "Running with a valid IPv4 address skips login"

out="$(run_case running-invalid-ip 42 0)"
grep -q 'Tailscale IPv4 address not found' "$out" ||
  fail "Invalid IPv4 was not rejected"
pass "An invalid Tailscale IPv4 address is rejected"

out="$(run_case restore-success 0 0)"
grep -q 'identity restored and IPv4 validated' "$out" ||
  fail "Successful restore was not confirmed"
grep -q '^playbook:tailscale-state-restore$' "$tmpdir/restore-success.calls" ||
  fail "Restore playbook was not invoked"
grep -q '^backup_tailscale$' "$tmpdir/restore-success.calls" ||
  fail "Successful restore did not trigger backup"
pass "Successful restore skips login and validates the IPv4 address"

out="$(run_case state-exists 0 1)"
grep -q 'login.tailscale.com/a/mock' "$out" ||
  fail "Existing state incorrectly blocked login after restore was attempted"
grep -q '^playbook:tailscale-state-restore$' "$tmpdir/state-exists.calls" ||
  fail "Restore was not attempted before login"
grep -q '^backup_tailscale$' "$tmpdir/state-exists.calls" ||
  fail "Successful login did not trigger backup"
up_line="$(grep -nFx 'tailscale up' "$tmpdir/state-exists.calls" | head -n1 | cut -d: -f1)"
restore_line="$(grep -nFx 'playbook:tailscale-state-restore' "$tmpdir/state-exists.calls" | head -n1 | cut -d: -f1)"
[[ -n "$restore_line" && -n "$up_line" && "$restore_line" -lt "$up_line" ]] ||
  fail "Login was invoked before the restore attempt"
pass "Existing state does not block login after restore fails and NeedsLogin is confirmed"

out="$(run_case login-success-after-restore-failure 0 1)"
grep -q 'login.tailscale.com/a/mock' "$out" ||
  fail "Authentication URL was not displayed"
grep -q 'IPv4 address has been detected' "$out" ||
  fail "Successful login was not confirmed"
pass "NeedsLogin triggers one login and polls until Running"

out="$(run_case login-timeout 42 1)"
grep -q 'was not confirmed within 5 minutes' "$out" ||
  fail "Authentication timeout was not reported"
pass "An incomplete login ends with a timeout"

echo "All Tailscale login flow tests passed."
