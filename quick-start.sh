#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ANSIBLE_BIN="$ROOT_DIR/.venv/bin/ansible"
ANSIBLE_PLAYBOOK_BIN="$ROOT_DIR/.venv/bin/ansible-playbook"
ANSIBLE_GALAXY_BIN="$ROOT_DIR/.venv/bin/ansible-galaxy"

[[ -x "$ANSIBLE_BIN" ]] ||
  ANSIBLE_BIN="$(command -v ansible || true)"
[[ -x "$ANSIBLE_PLAYBOOK_BIN" ]] ||
  ANSIBLE_PLAYBOOK_BIN="$(command -v ansible-playbook || true)"
[[ -x "$ANSIBLE_GALAXY_BIN" ]] ||
  ANSIBLE_GALAXY_BIN="$(command -v ansible-galaxy || true)"

INVENTORY_FILE="$ROOT_DIR/ansible/inventory/dev/hosts.yml"
export INVENTORY_FILE

ENV_FILE="${LOCAL_AI_ENV_FILE:-.secrets/.env}"
AUTH_PASSWORD_FILE=""
BECOME_PASSWORD_FILE=""
SSH_PASSWORD_FILE=""
SSH_AUTH_ARGS=()
SSH_AUTH_READY=0
SSH_HOST_KEY_ARGS=()

cleanup() {
  [[ -z "${AUTH_PASSWORD_FILE:-}" ]] ||
    rm -f -- "$AUTH_PASSWORD_FILE"
  [[ -z "${BECOME_PASSWORD_FILE:-}" ]] ||
    rm -f -- "$BECOME_PASSWORD_FILE"
  [[ -z "${SSH_PASSWORD_FILE:-}" ]] ||
    rm -f -- "$SSH_PASSWORD_FILE"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  ./quick-start.sh [phase]

Available phases:
  setup
  workstation
  preflight
  ansible
  test
  baseline
  gpu
  runtime
  tailscale
  restore-tailscale
  services
  proxy
  backup-webui
  fetch-webui-backup
  ollama-test
  api-test
  validate
  all

Default:
  all
EOF
}

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$1"
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

ensure_target_inventory() {
  local inventory_file="$INVENTORY_FILE"
  local server_host=""
  local server_user=""
  local temp_file=""
  local inventory_example="ansible/inventory/dev/hosts.yml.example"

  # Create a local inventory from the example only when it does not exist.
  if [[ ! -e "$inventory_file" ]]; then
    [[ -f "$inventory_example" ]] ||
      fail "Inventory template not found: $inventory_example"

    cp -- "$inventory_example" "$inventory_file" ||
      fail "Failed to create inventory from template."

    chmod 600 "$inventory_file" ||
      fail "Failed to set inventory permissions."
    log "Created local inventory from $inventory_example"
  fi

  [[ -f "$inventory_file" ]] ||
    fail "Inventory not found or is not a regular file: $inventory_file"

  # Read the configured target without executing inventory content.
  server_host="$(python -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
host = data["all"]["children"]["ai_servers"]["hosts"]["ai_server"]
print(host.get("ansible_host", "") or "")
' "$inventory_file")" ||
    fail "Invalid inventory YAML or ai_server host structure not found."

  server_user="$(python -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
host = data["all"]["children"]["ai_servers"]["hosts"]["ai_server"]
print(host.get("ansible_user", "") or "")
' "$inventory_file")" ||
    fail "Failed to read ansible_user from inventory."

  # Prompt until a valid target hostname/IP is supplied.
  while :; do
    if [[ -n "$server_host" && "$server_host" != "CHANGE_ME" &&
          "$server_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
      break
    fi

    [[ -t 0 ]] ||
      fail "ansible_host is empty or invalid. Run from an interactive terminal."

    if [[ -n "$server_host" && "$server_host" != "CHANGE_ME" ]]; then
      printf 'Invalid IP address/hostname format. Try again.\n' >&2
    fi
    read -r -p "IP address or hostname of the Debian AI server: " server_host
  done

  # Require a valid non-root SSH account.
  while :; do
    if [[ -n "$server_user" && "$server_user" != "CHANGE_ME" &&
          "$server_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ &&
          "$server_user" != "root" ]]; then
      break
    fi

    [[ -t 0 ]] ||
      fail "ansible_user is empty or invalid. Run from an interactive terminal."

    if [[ "$server_user" == "root" ]]; then
      printf 'SSH login as root is not allowed; use a non-root account with sudo.\n' >&2
    elif [[ -n "$server_user" && "$server_user" != "CHANGE_ME" ]]; then
      printf 'Invalid SSH username format. Try again.\n' >&2
    fi
    read -r -p "SSH username (use a non-root account with sudo): " server_user
  done

  # Preserve comments and formatting; change only the two target values.
  temp_file="$(mktemp "${inventory_file}.XXXXXX")"
  if ! python - "$inventory_file" "$temp_file" "$server_host" "$server_user" <<'PYINVENTORY'
import os
import re
import sys
import yaml

source, destination, server_host, server_user = sys.argv[1:]
text = open(source, encoding="utf-8").read()
data = yaml.safe_load(text)

# Validate the expected inventory structure before editing any text.
host = data["all"]["children"]["ai_servers"]["hosts"]["ai_server"]
if not isinstance(host, dict):
    raise SystemExit("ai_server inventory entry must be a mapping")

lines = text.splitlines(keepends=True)
host_line = next(
    (i for i, line in enumerate(lines)
     if re.match(r"^\s*ai_server:\s*(?:#.*)?(?:\r?\n)?$", line)),
    None,
)
if host_line is None:
    raise SystemExit("Could not locate ai_server block")

host_indent = len(lines[host_line]) - len(lines[host_line].lstrip())
block_end = len(lines)
for i in range(host_line + 1, len(lines)):
    line = lines[i]
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(line) - len(line.lstrip())
    if indent <= host_indent:
        block_end = i
        break

def replace_field(field, value):
    pattern = re.compile(
        rf'^(\s+{re.escape(field)}:\s*)([^#\r\n]*?)(\s+#.*)?(\r?\n)?$'
    )
    matches = [
        i for i in range(host_line + 1, block_end)
        if pattern.match(lines[i])
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"Expected exactly one {field} field in ai_server block; found {len(matches)}"
        )
    i = matches[0]
    match = pattern.match(lines[i])
    comment = match.group(3) or ""
    newline = match.group(4) or ""
    lines[i] = f"{match.group(1)}{value}{comment}{newline}"

replace_field("ansible_host", server_host)
replace_field("ansible_user", server_user)

updated = "".join(lines)
updated_data = yaml.safe_load(updated)
updated_host = updated_data["all"]["children"]["ai_servers"]["hosts"]["ai_server"]
if updated_host.get("ansible_host") != server_host:
    raise SystemExit("ansible_host validation failed after update")
if updated_host.get("ansible_user") != server_user:
    raise SystemExit("ansible_user validation failed after update")

with open(destination, "w", encoding="utf-8") as f:
    f.write(updated)
os.chmod(destination, os.stat(source).st_mode & 0o777)
PYINVENTORY
  then
    rm -f -- "$temp_file"
    fail "Failed to update inventory."
  fi

  mv -f -- "$temp_file" "$inventory_file"
  printf 'SSH target: %s@%s\n' "$server_user" "$server_host"
}

load_env() {
  local env_file_dir=""
  local domain_default=""
  local entered_domain=""
  local temp_env=""
  local source_status=0

  # Prevent accidental dependence on inherited shell values.
  CLOUDFLARE_API_TOKEN=""
  OPEN_WEBUI_DOMAIN=""

  env_file_dir="$(dirname -- "$ENV_FILE")"

  [[ -n "$ENV_FILE" && "$ENV_FILE" != "/" ]] ||
    fail "Invalid configuration file path."

  mkdir -p -- "$env_file_dir" ||
    fail "Unable to create configuration directory: $env_file_dir"

  if [[ "$ENV_FILE" == ".secrets/.env" ]]; then
    chmod 700 "$env_file_dir" ||
      fail "Unable to secure configuration directory."
  fi

  if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
    [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" && -r "$ENV_FILE" ]] ||
      fail "Configuration file is not a regular file or is not readable: $ENV_FILE"

    chmod 600 "$ENV_FILE" ||
      fail "Unable to secure configuration file: $ENV_FILE"

    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE" || source_status=$?
    set +a

    (( source_status == 0 )) ||
      fail "Failed to read configuration file: $ENV_FILE"
  fi

  # Read a suggested domain from the tracked example file.
  if [[ -z "${OPEN_WEBUI_DOMAIN:-}" && -f ".secrets/.env.example" ]]; then
    domain_default="$(
      sed -n 's/^OPEN_WEBUI_DOMAIN=//p' ".secrets/.env.example" |
        head -n 1 | tr -d '\r' | sed -E "s/^[\"']//; s/[\"']$//"
    )"
    [[ "$domain_default" == *"example.com"* ]] && domain_default=""
    [[ "$domain_default" == *"example.net"* ]] && domain_default=""
  fi

  # Treat obvious token placeholders as missing.
  if [[ "${CLOUDFLARE_API_TOKEN:-}" == *"isi_token"* ||
        "${CLOUDFLARE_API_TOKEN:-}" == *"your_token"* ||
        "${CLOUDFLARE_API_TOKEN:-}" == *"<"* ]]; then
    CLOUDFLARE_API_TOKEN=""
  fi

  if [[ "${OPEN_WEBUI_DOMAIN:-}" == *"example.com"* ||
        "${OPEN_WEBUI_DOMAIN:-}" == *"example.net"* ]]; then
    OPEN_WEBUI_DOMAIN=""
  fi

  # Prompt only when required values are missing.
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ||
        -z "${OPEN_WEBUI_DOMAIN:-}" ]]; then
    [[ -t 0 ]] ||
      fail "Configuration is incomplete. Run ./quick-start.sh from an interactive terminal to populate $ENV_FILE."

    log "Configure required secrets"

    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      while [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; do
        read -r -s -p "Cloudflare API token (input hidden): " CLOUDFLARE_API_TOKEN
        printf '\n'
        [[ -n "$CLOUDFLARE_API_TOKEN" ]] ||
          echo "Token must not be empty."
      done
    fi

    if [[ -z "${OPEN_WEBUI_DOMAIN:-}" ]]; then
      if [[ -n "$domain_default" ]]; then
        read -r -p "Domain Open WebUI [$domain_default]: " entered_domain
        OPEN_WEBUI_DOMAIN="${entered_domain:-$domain_default}"
      else
        read -r -p "Open WebUI domain (e.g. chat.example.net): " OPEN_WEBUI_DOMAIN
      fi
    fi
  fi

  # Validate before writing anything.
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] ||
    fail "CLOUDFLARE_API_TOKEN must not be empty."

  [[ -n "${OPEN_WEBUI_DOMAIN:-}" ]] ||
    fail "OPEN_WEBUI_DOMAIN must not be empty."

  [[ "$OPEN_WEBUI_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] ||
    fail "Invalid OPEN_WEBUI_DOMAIN format."

  [[ "$OPEN_WEBUI_DOMAIN" != *"example.com"* &&
     "$OPEN_WEBUI_DOMAIN" != *"example.net"* ]] ||
    fail "Ganti domain placeholder dengan domain yang sebenarnya."

  # Build a protected temporary file in the same directory.
  temp_env="$(mktemp "$env_file_dir/.$(basename -- "$ENV_FILE").XXXXXX")" ||
    fail "Unable to create temporary configuration file."

  chmod 600 "$temp_env" || {
    rm -f -- "$temp_env"
    fail "Unable to secure temporary configuration file."
  }

  # Preserve unrelated settings; replace only the required assignments.
  if [[ -f "$ENV_FILE" ]]; then
    if ! awk '
      /^[[:space:]]*(export[[:space:]]+)?CLOUDFLARE_API_TOKEN=/ { next }
      /^[[:space:]]*(export[[:space:]]+)?OPEN_WEBUI_DOMAIN=/ { next }
      { print }
    ' "$ENV_FILE" > "$temp_env"; then
      rm -f -- "$temp_env"
      fail "Failed to preserve existing configuration."
    fi
  fi

  if ! {
    printf 'CLOUDFLARE_API_TOKEN=%q\n' "$CLOUDFLARE_API_TOKEN"
    printf 'OPEN_WEBUI_DOMAIN=%q\n' "$OPEN_WEBUI_DOMAIN"
  } >> "$temp_env"; then
    rm -f -- "$temp_env"
    fail "Failed to write configuration."
  fi

  # Do not replace the active file when its content is already identical.
  if [[ -f "$ENV_FILE" ]] && cmp -s -- "$temp_env" "$ENV_FILE"; then
    rm -f -- "$temp_env"
  else
    if ! mv -f -- "$temp_env" "$ENV_FILE"; then
      rm -f -- "$temp_env"
      fail "Failed to save configuration."
    fi
  fi

  chmod 600 "$ENV_FILE" ||
    fail "Configuration was saved, but applying permission 600 failed."

  export CLOUDFLARE_API_TOKEN OPEN_WEBUI_DOMAIN
}

preflight() {
  log "Preflight"

  [[ -f ansible.cfg ]] || fail "ansible.cfg not found"
  [[ -d ansible/roles ]] || fail "Ansible roles not found"

  [[ -n "$ANSIBLE_PLAYBOOK_BIN" && -x "$ANSIBLE_PLAYBOOK_BIN" ]] ||
    fail "ansible-playbook not found"
  [[ -n "$ANSIBLE_GALAXY_BIN" && -x "$ANSIBLE_GALAXY_BIN" ]] ||
    fail "ansible-galaxy not found"
  [[ -n "$ANSIBLE_BIN" && -x "$ANSIBLE_BIN" ]] ||
    fail "Ansible not found"

  load_env
  ensure_target_inventory

  echo "Repository : $ROOT_DIR"
  echo "Domain     : $OPEN_WEBUI_DOMAIN"
  echo "Ansible    : $("$ANSIBLE_PLAYBOOK_BIN" --version | head -n1)"
}

ansible_prepare() {
  log "Install Ansible collections"

  "$ANSIBLE_GALAXY_BIN" collection install \
    -r ansible/requirements.yml

  log "Syntax validation"

  for playbook in ansible/playbooks/*.yml; do
    echo "Checking $playbook"
    "$ANSIBLE_PLAYBOOK_BIN" \
      -i "$INVENTORY_FILE" "$playbook" --syntax-check
  done
}

ensure_ssh_auth() {
  (( SSH_AUTH_READY == 1 )) && return 0

  local server_host="" server_user="" target output answer password
  local inventory_file="$INVENTORY_FILE"

  server_host="$(awk '
    /^[[:space:]]*ai_server:[[:space:]]*$/ { in_host=1; next }
    in_host && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ { exit }
    in_host && /^[[:space:]]*ansible_host:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/[\042\047]/, "")
      print
      exit
    }
  ' "$inventory_file")"

  server_user="$(awk '
    /^[[:space:]]*ai_server:[[:space:]]*$/ { in_host=1; next }
    in_host && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ { exit }
    in_host && /^[[:space:]]*ansible_user:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/[\042\047]/, "")
      print
      exit
    }
  ' "$inventory_file")"

  [[ -n "$server_host" && -n "$server_user" ]] ||
    fail "Unable to read ansible_host/ansible_user for ai_server."

  target="${server_user}@${server_host}"
  log "Checking SSH key authentication for $target"

  if output="$(ssh "${SSH_HOST_KEY_ARGS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$target" true 2>&1)"; then
    SSH_AUTH_READY=1
    echo "SSH key authentication: OK"
    return 0
  fi

  if grep -Eqi 'host key verification failed|remote host identification has changed|no matching host key type' <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "SSH host-key verification failed. Verify the server fingerprint before continuing."
  fi

  if ! grep -Eqi 'permission denied|authentication failed' <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "SSH authentication check failed for a reason other than a clear authentication rejection."
  fi

  printf '%s\n' "$output" >&2
  [[ -t 0 ]] || fail "Password fallback requires an interactive terminal."
  read -r -p "SSH key was rejected. Use the same password for SSH and sudo? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || fail "SSH authentication cancelled."

  command -v sshpass >/dev/null 2>&1 ||
    fail "Fallback password membutuhkan sshpass. Pasang dengan: sudo apt install sshpass"

  read -r -s -p "SSH and sudo password for $target: " password
  printf '\n'
  [[ -n "$password" ]] || fail "Password must not be empty."

  umask 077
  AUTH_PASSWORD_FILE="$(mktemp "$ROOT_DIR/.secrets/.auth-password.XXXXXX")"
  chmod 600 "$AUTH_PASSWORD_FILE"
  printf '%s\n' "$password" > "$AUTH_PASSWORD_FILE"
  unset password

  SSH_PASSWORD_FILE="$AUTH_PASSWORD_FILE"
  BECOME_PASSWORD_FILE="$AUTH_PASSWORD_FILE"
  SSH_AUTH_ARGS=(--connection-password-file "$AUTH_PASSWORD_FILE")
  SSH_AUTH_READY=1
  echo "Shared password stored temporarily with permission 600."
}


configure_ssh_host_key_checking() {
  local answer

  if [[ ! -t 0 ]]; then
    export ANSIBLE_HOST_KEY_CHECKING=True
    return 0
  fi

  read -r -p "Bypass SSH host-key checking for this run? [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES|Yes)
      export ANSIBLE_HOST_KEY_CHECKING=False
      SSH_HOST_KEY_ARGS=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o GlobalKnownHostsFile=/dev/null
      )
      export ANSIBLE_SSH_COMMON_ARGS="${SSH_HOST_KEY_ARGS[*]}${ANSIBLE_SSH_COMMON_ARGS:+ ${ANSIBLE_SSH_COMMON_ARGS}}"
      printf '%s\n' "WARNING: SSH host identity verification is disabled for this run." >&2
      printf '%s\n' "Use only on a trusted lab network; verify the server fingerprint whenever possible." >&2
      ;;
    *)
      export ANSIBLE_HOST_KEY_CHECKING=True
      printf '%s\n' "SSH host-key checking remains enabled."
      ;;
  esac
}

ask_become_password() {
  if [[ -n "$BECOME_PASSWORD_FILE" ]]; then
    return 0
  fi

  local password
  read -r -s -p "BECOME password (sudo): " password
  printf '\n'
  [[ -n "$password" ]] || fail "Sudo password must not be empty."

  umask 077
  AUTH_PASSWORD_FILE="$(mktemp "$ROOT_DIR/.secrets/.auth-password.XXXXXX")"
  chmod 600 "$AUTH_PASSWORD_FILE"
  printf '%s\n' "$password" > "$AUTH_PASSWORD_FILE"
  unset password

  BECOME_PASSWORD_FILE="$AUTH_PASSWORD_FILE"
}

run_playbook() {
  local playbook="$1"

  log "Running $playbook"
  ensure_ssh_auth
  ask_become_password

  "$ANSIBLE_PLAYBOOK_BIN" \
    -i "$INVENTORY_FILE" \
    "${SSH_AUTH_ARGS[@]}" \
    --become-password-file "$BECOME_PASSWORD_FILE" \
    "ansible/playbooks/${playbook}.yml"
}

run_ansible() {
  ensure_ssh_auth
  ask_become_password

  "$ANSIBLE_BIN" \
    -i "$INVENTORY_FILE" \
    "${SSH_AUTH_ARGS[@]}" \
    --become-password-file "$BECOME_PASSWORD_FILE" "$@"
}

tailscale_auth_flow() {
  log "Memeriksa status autentikasi Tailscale"

  local output="" login_url="" elapsed=0 backend_state="" ts_ip="" ts_output=""
  local status_command="tailscale status --json"
  local restore_output="" restore_log=""

  # Jangan memulai pemulihan jika status server tidak bisa dibaca.
  if ! output="$(run_ansible ai_servers -b -m command \
      -a "$status_command" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "Tailscale status check failed. A new login will not be initiated."
  fi

  if grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"' <<<"$output"; then
    backend_state="Running"
  elif grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"NeedsLogin"' <<<"$output"; then
    backend_state="NeedsLogin"
  else
    printf '%s\n' "$output" >&2
    fail "Unrecognized BackendState. A new login will not be initiated."
  fi

  # Jika sudah sehat, pertahankan identitas dan lewati restore/login.
  if [[ "$backend_state" == "Running" ]]; then
    if ! ts_output="$(run_ansible ai_servers -b -m command \
        -a 'tailscale ip -4' 2>&1)"; then
      printf '%s\n' "$ts_output" >&2
      fail "Tailscale is running, but its IPv4 address could not be read."
    fi

    ts_ip="$(extract_tailscale_ipv4 "$ts_output" 2>/dev/null || true)"
    if ! is_valid_tailscale_ipv4 "$ts_ip"; then
      printf '%s\n' "$ts_ip" >&2
      fail "Tailscale IPv4 address not found or invalid."
    fi

    echo "Tailscale is already connected; skipping restore and new login."
    backup_tailscale
    return 0
  fi

  # Fresh login: invoke tailscale up directly over SSH, not through Ansible.
  local server_host="" server_user="" target=""
  local -a direct_ssh

  server_host="$(awk '
    /^[[:space:]]*ai_server:[[:space:]]*$/ { in_host=1; next }
    in_host && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ { exit }
    in_host && /^[[:space:]]*ansible_host:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/[\042\047]/, "")
      print
      exit
    }
  ' "$INVENTORY_FILE")"

  server_user="$(awk '
    /^[[:space:]]*ai_server:[[:space:]]*$/ { in_host=1; next }
    in_host && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ { exit }
    in_host && /^[[:space:]]*ansible_user:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/[\042\047]/, "")
      print
      exit
    }
  ' "$INVENTORY_FILE")"

  [[ -n "$server_host" && -n "$server_user" ]] ||
    fail "Unable to read ansible_host/ansible_user for ai_server."

  [[ -n "${BECOME_PASSWORD_FILE:-}" && -r "$BECOME_PASSWORD_FILE" ]] ||
    fail "Sudo password file is unavailable."

  target="${server_user}@${server_host}"
  direct_ssh=(ssh "${SSH_HOST_KEY_ARGS[@]}" -tt)

  if [[ -n "${SSH_PASSWORD_FILE:-}" ]]; then
    command -v sshpass >/dev/null 2>&1 ||
      fail "sshpass is required for SSH password authentication."
    direct_ssh=(sshpass -f "$SSH_PASSWORD_FILE" ssh "${SSH_HOST_KEY_ARGS[@]}" -tt)
  fi

  printf '\n%s\n' "Starting tailscale up directly on $target."
  printf '%s\n\n' "Complete authentication using the URL displayed below."

  if ! "${direct_ssh[@]}" "$target" \
      "sudo -S -p '' tailscale up" < "$BECOME_PASSWORD_FILE"; then
    fail "Direct SSH invocation of tailscale up failed."
  fi

  echo "Waiting for authentication (up to 5 minutes)..."
  while (( elapsed < 300 )); do
    if ! output="$(run_ansible ai_servers -b -m command \
        -a "$status_command" 2>&1)"; then
      printf '%s\n' "$output" >&2
      fail "Status check failed during polling."
    fi

    if grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"' <<<"$output"; then
      if ! ts_output="$(run_ansible ai_servers -b -m command \
          -a 'tailscale ip -4' 2>&1)"; then
        printf '%s\n' "$ts_output" >&2
        fail "Backend is running, but its IPv4 address could not be read."
      fi

      ts_ip="$(extract_tailscale_ipv4 "$ts_output" 2>/dev/null || true)"
      if is_valid_tailscale_ipv4 "$ts_ip"; then
        echo "Tailscale is connected and an IPv4 address has been detected."
        backup_tailscale
        return 0
      fi
    elif ! grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"NeedsLogin"' <<<"$output"; then
      printf '%s\n' "$output" >&2
      fail "Unrecognized BackendState during polling."
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  printf '%s\n' "$output" >&2
  fail "Tailscale authentication was not confirmed within 5 minutes."
}

extract_tailscale_ipv4() {
  local line candidate=""
  local count=0

  while IFS= read -r line; do
    line="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$line")"
    if [[ "$line" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      candidate="$line"
      count=$((count + 1))
    fi
  done <<<"${1:-}"

  # Reject ambiguous output rather than guessing which address is intended.
  [[ "$count" -eq 1 ]] || return 1
  printf '%s\n' "$candidate"
}

is_valid_tailscale_ipv4() {
  local ip octet second_octet
  local -a octets

  ip="$(tr -d '[:space:]\r' <<<"${1:-}")"
  [[ "$ip" =~ ^100\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1

  IFS='.' read -r -a octets <<<"$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done

  second_octet=$((10#${octets[1]}))
  (( second_octet >= 64 && second_octet <= 127 )) || return 1

  return 0
}

tailscale_auth_and_proxy_flow() {
  tailscale_auth_flow || return $?
  run_playbook open-webui-proxy
}

backup_tailscale() {
  run_playbook tailscale-state-backup
}


fetch_existing_webui_backup() {
  log "Fetch existing Open WebUI backup through Ansible"
  ensure_ssh_auth

  local backup_dir=".secrets/open-webui-backups"
  local listing remote_record remote_archive archive_name local_archive
  local remote_size remote_hash_output remote_hash local_hash
  local fetch_pid current_bytes percentage last_bytes poll_count fetch_rc

  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"

  log "Step 1/4: Discover remote backup archive"
  echo "Checking /var/tmp on the configured AI server through Ansible; verbose output follows."

  if ! listing="$(
    ANSIBLE_TIMEOUT=15 "$ANSIBLE_BIN" -i "$INVENTORY_FILE" "${SSH_AUTH_ARGS[@]}" ai_servers -o \
      -e '{"ansible_become": false}' \
      -m shell \
      -a "find /var/tmp -maxdepth 1 -type f -name 'open-webui-pre-v0.12.0-*.tar.gz' -printf '%T@|%s|%p\\n' | sort -nr | head -n1 | cut -d'|' -f2-" \
      2>&1 | tee /dev/stderr
  )"; then
    printf '%s\n' "$listing" >&2
    fail "Remote archive discovery failed."
  fi

  remote_record="$(
    printf '%s\n' "$listing" |
      grep -Eo '[0-9]+\|/var/tmp/open-webui-pre-v0\.12\.0-[0-9]{8}T[0-9]{6}Z\.tar\.gz' |
      tail -n1 || true
  )"

  [[ -n "$remote_record" ]] ||
    fail "No existing v0.12.0 pre-upgrade archive found on the server."

  remote_size="${remote_record%%|*}"
  remote_archive="${remote_record#*|}"
  archive_name="$(basename "$remote_archive")"
  local_archive="$backup_dir/$archive_name"

  [[ "$remote_size" =~ ^[0-9]+$ ]] ||
    fail "Could not determine remote archive size."

  [[ ! -e "$local_archive" ]] ||
    fail "Local archive already exists: $local_archive; refusing to overwrite it."

  printf 'Archive : %s\n' "$archive_name"
  printf 'Size    : %s bytes (%s MiB)\n' \
    "$remote_size" "$((remote_size / 1048576))"

  log "Step 2/4: Fetch archive (Ansible verbosity level 3)"
  echo "The transfer will run in the foreground; progress is reported below."

  ANSIBLE_TIMEOUT=30 "$ANSIBLE_BIN" -i "$INVENTORY_FILE" "${SSH_AUTH_ARGS[@]}" -vvv ai_servers \
    -e '{"ansible_become": false}' \
    -m ansible.builtin.fetch \
    -a "src=${remote_archive} dest=${backup_dir}/ flat=true validate_checksum=true" &
  fetch_pid=$!

  last_bytes=-1
  poll_count=0

  while kill -0 "$fetch_pid" 2>/dev/null; do
    if [[ -f "$local_archive" ]]; then
      current_bytes="$(stat -c '%s' "$local_archive" 2>/dev/null || printf '0')"

      if [[ "$remote_size" -gt 0 ]]; then
        percentage=$((current_bytes * 100 / remote_size))
        ((percentage > 100)) && percentage=100
      else
        percentage=0
      fi

      if [[ "$current_bytes" != "$last_bytes" ]] || ((poll_count % 5 == 0)); then
        printf '[fetch] %3d%% — %s / %s MiB\n' \
          "$percentage" \
          "$((current_bytes / 1048576))" \
          "$((remote_size / 1048576))" >&2
        last_bytes="$current_bytes"
      fi
    elif ((poll_count % 5 == 0)); then
      echo "[fetch] Ansible is running; waiting for the local file to appear..." >&2
    fi

    poll_count=$((poll_count + 1))
    sleep 2
  done

  if wait "$fetch_pid"; then
    :
  else
    fetch_rc=$?
    rm -f -- "$local_archive"
    fail "Ansible fetch failed (exit ${fetch_rc}); incomplete local archive removed."
  fi

  printf '\n'
  [[ -f "$local_archive" ]] ||
    fail "Fetch completed but the expected local archive was not found."

  chmod 600 "$local_archive"

  log "Step 3/4: Verify local archive integrity"
  if ! tar -tzf "$local_archive" >/dev/null 2>&1; then
    rm -f -- "$local_archive"
    fail "Archive integrity verification failed; the local file was removed."
  fi
  echo "Local tar.gz integrity: OK"

  log "Step 4/4: Compare SHA-256 checksums"
  echo "Calculating checksum on the remote archive; this reads the complete file."

  if ! remote_hash_output="$(
    ANSIBLE_TIMEOUT=60 "$ANSIBLE_BIN" -i "$INVENTORY_FILE" "${SSH_AUTH_ARGS[@]}" ai_servers -o \
      -e '{"ansible_become": false}' \
      -m command \
      -a "sha256sum ${remote_archive}" 2>&1
  )"; then
    printf '%s\n' "$remote_hash_output" >&2
    fail "Could not calculate the remote checksum. Keep both copies for investigation."
  fi

  remote_hash="$(
    printf '%s\n' "$remote_hash_output" |
      grep -Eo '[0-9a-f]{64}' |
      tail -n1 || true
  )"
  local_hash="$(sha256sum "$local_archive" | awk '{print $1}')"

  [[ -n "$remote_hash" && "$remote_hash" == "$local_hash" ]] ||
    fail "SHA-256 mismatch. Keep the server archive and investigate before upgrading."

  printf '\nBackup fetched and verified.\n'
  printf 'Local file : %s\n' "$local_archive"
  printf 'Size       : %s bytes\n' "$(stat -c '%s' "$local_archive")"
  printf 'Permissions: %s\n' "$(stat -c '%a' "$local_archive")"
  printf 'SHA-256    : %s\n' "$local_hash"
}


verify_gpu() {
  log "Verify NVIDIA GPU readiness"

  if ! run_ansible ai_servers -m command -a "nvidia-smi"; then
    echo "ERROR: NVIDIA GPU is not ready." >&2
    echo "Check the driver and reboot the target if necessary." >&2
    echo "Then rerun: ./quick-start.sh all" >&2
    return 1
  fi
}


ensure_gpu_ready() {
  if verify_gpu; then
    return 0
  fi

  echo
  echo "The NVIDIA GPU is not ready on the target host."
  echo "A reboot is only required if the driver is not active after installation."
  echo "Reboot akan memutus layanan pada host target sementara."
  echo

  local answer=""
  if [[ ! -t 0 ]]; then
    echo "ERROR: No interactive terminal is available to request reboot approval." >&2
    echo "Check the target host, then rerun the GPU phase." >&2
    return 1
  fi

  read -r -p "Reboot the target host now? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES|Yes)
      ;;
    *)
      echo "Reboot cancelled. The target host was not rebooted." >&2
      return 1
      ;;
  esac

  log "Reboot target untuk mengaktifkan NVIDIA driver"
  run_ansible ai_servers -b -m ansible.builtin.reboot \
    -a "reboot_timeout=600" || {
      echo "ERROR: Reboot or reconnection to the target host failed." >&2
      return 1
    }

  verify_gpu
}

setup_workstation() {
  log "Local workstation setup"

  local os_name=""
  local python_bin=""
  local python_version=""

  os_name="$(uname -s)"
  case "$os_name" in
    Linux|Darwin) ;;
    *) fail "Unsupported OS: $os_name (supported: Linux and macOS)." ;;
  esac

  if command -v python3 >/dev/null 2>&1; then
    python_bin="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    python_bin="$(command -v python)"
  else
    fail "Python 3 not found. Install Python 3.11+, then rerun setup."
  fi

  python_version="$("$python_bin" -c '
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
')"

  "$python_bin" -c '
import sys
if sys.version_info < (3, 11):
    raise SystemExit("Python 3.11 atau lebih baru diperlukan.")
' || fail "Python $python_version is not supported; Python 3.11+ is required."

  if [[ -e "$ROOT_DIR/.venv" ]]; then
    [[ -x "$ROOT_DIR/.venv/bin/python" ]] ||
      fail ".venv already exists but is not a valid Unix virtual environment. Inspect it manually; it will not be deleted."
  else
    "$python_bin" -m venv "$ROOT_DIR/.venv" ||
      fail "Failed to create .venv. Ensure venv support is available."
  fi

  [[ -f "$ROOT_DIR/requirements-dev.txt" ]] ||
    fail "Dependency file not found: requirements-dev.txt"

  log "Installing workstation dependencies"
  "$ROOT_DIR/.venv/bin/python" -m pip install \
    -r "$ROOT_DIR/requirements-dev.txt" ||
    fail "Failed to install workstation dependencies."

  log "Workstation environment ready"
  printf 'OS: %s\n' "$os_name"
  printf 'Base Python: %s\n' "$python_version"
  printf 'Virtual environment: %s/.venv\n' "$ROOT_DIR"
  printf 'Ansible: %s\n' "$("$ROOT_DIR/.venv/bin/ansible" --version | head -n 1)"
  printf '\nActivate with:\n'
  printf '  source .venv/bin/activate\n'
  printf 'Then run the tests:\n'
  printf '  ./quick-start.sh test\n'
}

unit_test() {
  log "Local shell unit tests"

  local test_script=""
  for test_script in \
    "$ROOT_DIR/tests/test_load_env.sh" \
    "$ROOT_DIR/tests/test_dispatcher.sh" \
    "$ROOT_DIR/tests/test_default_flow.sh" \
    "$ROOT_DIR/tests/test_gpu_readiness.sh" \
    "$ROOT_DIR/tests/test_tailscale_state_guard.sh" \
    "$ROOT_DIR/tests/test_tailscale_login_flow.sh"; do
    [[ -f "$test_script" ]] ||
      fail "Shell test file not found: $test_script"

    log "Running shell test: ${test_script##*/}"
    bash "$test_script" ||
      fail "Shell test failed: ${test_script##*/}"
  done

  log "Local Python unit tests"

  local python_bin=""

  if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
    python_bin="$ROOT_DIR/.venv/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    python_bin="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    python_bin="$(command -v python)"
  else
    fail "Python not found. Run ./quick-start.sh setup first."
  fi

  [[ -d "$ROOT_DIR/tests" ]] ||
    fail "Unit test directory not found: tests/"

  log "Python interpreter: $python_bin"

  PYTHONPATH="$ROOT_DIR/src${PYTHONPATH:+:$PYTHONPATH}" \
    "$python_bin" -m unittest discover \
      -s "$ROOT_DIR/tests" -p 'test_*.py' -v
}

ollama_test() {
  log "Ollama API smoke test"

  [[ -n "$ANSIBLE_BIN" && -x "$ANSIBLE_BIN" ]] ||
    fail "Ansible not found. Run ./quick-start.sh setup first."

  [[ -f "$INVENTORY_FILE" ]] ||
    fail "Inventory not found: $INVENTORY_FILE"

  [[ -f tests/ollama_api_smoke.py ]] ||
    fail "tests/ollama_api_smoke.py not found."

  ensure_ssh_auth

  log "Copy smoke test to the server"
  "$ANSIBLE_BIN" -i "$INVENTORY_FILE" "${SSH_AUTH_ARGS[@]}" ai_servers -o \
    -e '{"ansible_become": false}' \
    -m ansible.builtin.copy \
    -a "src=$ROOT_DIR/tests/ollama_api_smoke.py dest=/tmp/ollama_api_smoke.py mode=0644"

  log "Run smoke test inside the Docker network"
  "$ANSIBLE_BIN" -i "$INVENTORY_FILE" "${SSH_AUTH_ARGS[@]}" ai_servers -o \
    -e '{"ansible_become": false}' \
    -m ansible.builtin.shell \
    -a 'set -eu; trap "rm -f /tmp/ollama_api_smoke.py" EXIT; docker run --rm --network ai_backend -v /tmp/ollama_api_smoke.py:/tmp/ollama_api_smoke.py:ro -e OLLAMA_API_URL=http://ollama:11434/api/chat python:3.11-slim python /tmp/ollama_api_smoke.py'
}


api_test() {
  log "FastAPI gateway smoke test"

  [[ -n "$ANSIBLE_BIN" && -x "$ANSIBLE_BIN" ]] ||
    fail "Ansible not found. Run ./quick-start.sh setup first."

  [[ -f "$INVENTORY_FILE" ]] ||
    fail "Inventory not found: $INVENTORY_FILE"

  [[ -f "$ROOT_DIR/tests/local_ai_api_smoke.py" ]] ||
    fail "tests/local_ai_api_smoke.py not found."

  ensure_ssh_auth

  log "Test FastAPI through host loopback"
  "$ANSIBLE_BIN" -i "$INVENTORY_FILE" "${SSH_AUTH_ARGS[@]}" ai_servers -o \
    -e '{"ansible_become": false}' \
    -m ansible.builtin.script \
    -a "$ROOT_DIR/tests/local_ai_api_smoke.py"
}
validate() {
  log "Validation"

  echo "--- SSH ---"
  run_ansible ai_servers -m ping

  echo "--- Tailscale ---"
  run_ansible ai_servers -m command -a "tailscale status"

  echo "--- Docker ---"
  run_ansible ai_servers -m command -a "docker ps"

  echo "--- GPU ---"
  run_ansible ai_servers -m command -a "nvidia-smi"

  echo "--- HTTPS ---"
  curl -fsS --max-time 20 --output /dev/null \
    --write-out "HTTPS status: %{http_code}\n" \
    "https://${OPEN_WEBUI_DOMAIN}"

  api_test
}


refresh_tool_paths() {
  ANSIBLE_BIN="$ROOT_DIR/.venv/bin/ansible"
  ANSIBLE_PLAYBOOK_BIN="$ROOT_DIR/.venv/bin/ansible-playbook"
  ANSIBLE_GALAXY_BIN="$ROOT_DIR/.venv/bin/ansible-galaxy"

  [[ -x "$ANSIBLE_BIN" ]] ||
    ANSIBLE_BIN="$(command -v ansible || true)"
  [[ -x "$ANSIBLE_PLAYBOOK_BIN" ]] ||
    ANSIBLE_PLAYBOOK_BIN="$(command -v ansible-playbook || true)"
  [[ -x "$ANSIBLE_GALAXY_BIN" ]] ||
    ANSIBLE_GALAXY_BIN="$(command -v ansible-galaxy || true)"

  [[ -n "$ANSIBLE_BIN" && -x "$ANSIBLE_BIN" ]] ||
    fail "Ansible not found after workstation setup."
  [[ -n "$ANSIBLE_PLAYBOOK_BIN" && -x "$ANSIBLE_PLAYBOOK_BIN" ]] ||
    fail "ansible-playbook not found after workstation setup."
  [[ -n "$ANSIBLE_GALAXY_BIN" && -x "$ANSIBLE_GALAXY_BIN" ]] ||
    fail "ansible-galaxy not found after workstation setup."
}

# Handle help and reject extra arguments before any phase runs.
if [[ $# -gt 1 ]]; then
  printf '%s\n' "ERROR: Hanya satu argumen fase yang diperbolehkan." >&2
  usage
  exit 2
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

phase="${1:-all}"

# No-argument invocation: prepare the local workstation if needed,
# then run local tests before allowing the existing "all" phase to proceed.
if [[ $# -eq 0 ]]; then
  if [[ ! -x "$ROOT_DIR/.venv/bin/python" ||
        ! -x "$ROOT_DIR/.venv/bin/ansible" ||
        ! -x "$ROOT_DIR/.venv/bin/ansible-playbook" ||
        ! -x "$ROOT_DIR/.venv/bin/ansible-galaxy" ]]; then
    setup_workstation
  fi

  refresh_tool_paths
  unit_test
fi

case "$phase" in
  setup|workstation|preflight|ansible|test)
    ;;
  baseline|gpu|runtime|tailscale|restore-tailscale|services|proxy|backup-webui|fetch-webui-backup|ollama-test|api-test|validate|all)
    configure_ssh_host_key_checking
    ;;
esac

case "$phase" in
  setup)
    setup_workstation
    ;;

  workstation)
    [[ -x "$ROOT_DIR/.venv/bin/ansible-playbook" ]] ||
      fail "Ansible is not available yet. Run ./quick-start.sh setup first."
    "$ROOT_DIR/.venv/bin/ansible-playbook" \
      -i localhost, "$ROOT_DIR/ansible/playbooks/workstation.yml"
    ;;

  preflight)
    preflight
    ;;

  ansible)
    preflight
    ansible_prepare
    ;;

  baseline)
    preflight
    run_playbook bootstrap
    run_playbook security-baseline
    ;;

  gpu)
    preflight
    run_playbook bootstrap
    run_playbook security-baseline
    run_playbook gpu
    ensure_gpu_ready
    echo "GPU verification passed. Continue with ./quick-start.sh runtime"
    ;;

  runtime)
    preflight
    verify_gpu
    run_playbook container-runtime
    ;;

  tailscale)
    preflight
    run_playbook bootstrap
    run_playbook tailscale-client
    tailscale_auth_and_proxy_flow
    ;;

  restore-tailscale)
    preflight
    run_playbook tailscale-state-restore
    ;;

  services)
    preflight
    run_playbook ai-services
    ;;

  proxy)
    preflight
    run_playbook open-webui-proxy
    ;;

  backup-webui)
    preflight
    run_playbook open-webui-backup
    ;;

  fetch-webui-backup)
    preflight
    fetch_existing_webui_backup
    ;;

  test)
    unit_test
    ;;

  ollama-test)
    ollama_test
    ;;
  api-test)
    api_test
    ;;

  validate)
    preflight
    validate
    ;;

  all)
    preflight
    ansible_prepare

    run_playbook bootstrap
    run_playbook security-baseline
    run_playbook tailscale-client
    tailscale_auth_flow

    run_playbook gpu
    ensure_gpu_ready

    run_playbook container-runtime
    run_playbook ai-services
    run_playbook open-webui-proxy

    validate
    ;;

  *)
    usage
    exit 1
    ;;
esac
