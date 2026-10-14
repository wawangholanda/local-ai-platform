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
BECOME_PASSWORD_FILE=""
SSH_PASSWORD_FILE=""
SSH_AUTH_ARGS=()
SSH_AUTH_READY=0

cleanup() {
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
      fail "Template inventory tidak ditemukan: $inventory_example"

    cp -- "$inventory_example" "$inventory_file" ||
      fail "Gagal membuat inventory dari template."

    chmod 600 "$inventory_file" ||
      fail "Gagal mengatur permission inventory."
    log "Created local inventory from $inventory_example"
  fi

  [[ -f "$inventory_file" ]] ||
    fail "Inventory tidak ditemukan atau bukan file biasa: $inventory_file"

  # Read the configured target without executing inventory content.
  server_host="$(python -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
host = data["all"]["children"]["ai_servers"]["hosts"]["ai_server"]
print(host.get("ansible_host", "") or "")
' "$inventory_file")" ||
    fail "Inventory YAML tidak valid atau struktur host ai_server tidak ditemukan."

  server_user="$(python -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
host = data["all"]["children"]["ai_servers"]["hosts"]["ai_server"]
print(host.get("ansible_user", "") or "")
' "$inventory_file")" ||
    fail "Gagal membaca ansible_user dari inventory."

  # Prompt until a valid target hostname/IP is supplied.
  while :; do
    if [[ -n "$server_host" && "$server_host" != "CHANGE_ME" &&
          "$server_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
      break
    fi

    [[ -t 0 ]] ||
      fail "ansible_host kosong atau tidak valid. Jalankan dari terminal interaktif."

    if [[ -n "$server_host" && "$server_host" != "CHANGE_ME" ]]; then
      printf 'Format IP/hostname tidak valid. Coba lagi.\n' >&2
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
      fail "ansible_user kosong atau tidak valid. Jalankan dari terminal interaktif."

    if [[ "$server_user" == "root" ]]; then
      printf 'Login SSH sebagai root tidak diperbolehkan; gunakan akun non-root dengan sudo.\n' >&2
    elif [[ -n "$server_user" && "$server_user" != "CHANGE_ME" ]]; then
      printf 'Format username SSH tidak valid. Coba lagi.\n' >&2
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
    fail "Gagal memperbarui inventory."
  fi

  mv -f -- "$temp_file" "$inventory_file"
  printf 'SSH target: %s@%s\n' "$server_user" "$server_host"
}

load_env() {
  local env_dir=".secrets"
  local example_file=".secrets/.env.example"
  local domain_default=""
  local entered_domain=""
  local temp_env=""

  mkdir -p "$env_dir"
  chmod 700 "$env_dir"

  # Do not silently rely on inherited values from the user's shell.
  CLOUDFLARE_API_TOKEN=""
  OPEN_WEBUI_DOMAIN=""

  if [[ -f "$ENV_FILE" ]]; then
    chmod 600 "$ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi

  # Read a suggested domain from the tracked example file, if available.
  if [[ -z "${OPEN_WEBUI_DOMAIN:-}" && -f "$example_file" ]]; then
    domain_default="$(
      sed -n 's/^OPEN_WEBUI_DOMAIN=//p' "$example_file" |
        head -n 1 | tr -d '\r' | sed -E "s/^[\"']//; s/[\"']$//"
    )"
    [[ "$domain_default" == *"example.com"* ]] && domain_default=""
    [[ "$domain_default" == *"example.net"* ]] && domain_default=""
  fi

  # Treat obvious placeholders as missing values.
  if [[ "${CLOUDFLARE_API_TOKEN:-}" == *"isi_token"* ||
        "${CLOUDFLARE_API_TOKEN:-}" == *"your_token"* ||
        "${CLOUDFLARE_API_TOKEN:-}" == *"<"* ]]; then
    CLOUDFLARE_API_TOKEN=""
  fi

  if [[ "${OPEN_WEBUI_DOMAIN:-}" == *"example.com"* ||
        "${OPEN_WEBUI_DOMAIN:-}" == *"example.net"* ]]; then
    OPEN_WEBUI_DOMAIN=""
  fi

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ||
        -z "${OPEN_WEBUI_DOMAIN:-}" ]]; then
    if [[ ! -t 0 ]]; then
      fail "Konfigurasi belum lengkap. Jalankan ./quick-start.sh dari terminal interaktif untuk mengisi $ENV_FILE."
    fi

    log "Configure required secrets"
    [[ -f "$ENV_FILE" ]] ||
      echo "File $ENV_FILE belum ada; kita buat sekarang."

    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      while [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; do
        read -r -s -p "Cloudflare API token (input tersembunyi): " CLOUDFLARE_API_TOKEN
        printf '\n'
        [[ -n "$CLOUDFLARE_API_TOKEN" ]] ||
          echo "Token tidak boleh kosong."
      done
    fi

    if [[ -z "${OPEN_WEBUI_DOMAIN:-}" ]]; then
      if [[ -n "$domain_default" ]]; then
        read -r -p "Domain Open WebUI [$domain_default]: " entered_domain
        OPEN_WEBUI_DOMAIN="${entered_domain:-$domain_default}"
      else
        read -r -p "Domain Open WebUI (mis. chat.example.net): " OPEN_WEBUI_DOMAIN
      fi
    fi

    [[ -n "$OPEN_WEBUI_DOMAIN" ]] ||
      fail "OPEN_WEBUI_DOMAIN tidak boleh kosong."

    [[ "$OPEN_WEBUI_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] ||
      fail "Format OPEN_WEBUI_DOMAIN tidak valid."

    [[ "$OPEN_WEBUI_DOMAIN" != *"example.com"* &&
       "$OPEN_WEBUI_DOMAIN" != *"example.net"* ]] ||
      fail "Ganti domain placeholder dengan domain yang sebenarnya."

    # Write safely with Bash-compatible quoting and atomic replacement.
    temp_env="$(mktemp "$env_dir/.env.XXXXXX")"
    chmod 600 "$temp_env"
    {
      printf 'CLOUDFLARE_API_TOKEN=%q\n' "$CLOUDFLARE_API_TOKEN"
      printf 'OPEN_WEBUI_DOMAIN=%q\n' "$OPEN_WEBUI_DOMAIN"
    } > "$temp_env"

    mv -f -- "$temp_env" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Konfigurasi tersimpan di $ENV_FILE dengan permission 600."
  fi

  [[ "$OPEN_WEBUI_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] ||
    fail "Format OPEN_WEBUI_DOMAIN tidak valid."

  export CLOUDFLARE_API_TOKEN OPEN_WEBUI_DOMAIN
}

preflight() {
  log "Preflight"

  [[ -f ansible.cfg ]] || fail "ansible.cfg tidak ditemukan"
  [[ -d ansible/roles ]] || fail "ansible roles tidak ditemukan"

  [[ -n "$ANSIBLE_PLAYBOOK_BIN" && -x "$ANSIBLE_PLAYBOOK_BIN" ]] ||
    fail "ansible-playbook tidak ditemukan"
  [[ -n "$ANSIBLE_GALAXY_BIN" && -x "$ANSIBLE_GALAXY_BIN" ]] ||
    fail "ansible-galaxy tidak ditemukan"
  [[ -n "$ANSIBLE_BIN" && -x "$ANSIBLE_BIN" ]] ||
    fail "ansible tidak ditemukan"

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

  server_host="$(python -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
host = data["all"]["children"]["ai_servers"]["hosts"]["ai_server"]
print(host.get("ansible_host", "") or "")
' "$inventory_file")" ||
    fail "Gagal membaca ansible_host dari $inventory_file."

  server_user="$(python -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
host = data["all"]["children"]["ai_servers"]["hosts"]["ai_server"]
print(host.get("ansible_user", "") or "")
' "$inventory_file")" ||
    fail "Gagal membaca ansible_user dari $inventory_file."

  [[ -n "$server_host" && "$server_host" != "CHANGE_ME" &&
     "$server_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
    fail "ansible_host kosong atau tidak valid di $inventory_file."

  [[ -n "$server_user" && "$server_user" != "CHANGE_ME" &&
     "$server_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ &&
     "$server_user" != "root" ]] ||
    fail "ansible_user tidak valid atau root tidak diizinkan di $inventory_file."

  target="${server_user}@${server_host}"
  log "Checking SSH key authentication for $target"

  if output="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" true 2>&1)"; then
    SSH_AUTH_READY=1
    echo "SSH key authentication: OK"
    return 0
  fi

  if grep -Eqi 'host key verification failed|remote host identification has changed|no matching host key type' <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "SSH host-key verification failed. Verify the server fingerprint and resolve it before continuing."
  fi

  if ! grep -Eqi 'permission denied|authentication failed' <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "SSH key check failed for a reason other than a clear authentication rejection. Check connectivity, SSH configuration, and host-key trust."
  fi

  printf '%s\n' "$output" >&2
  [[ -t 0 ]] || fail "SSH key ditolak; fallback password memerlukan terminal interaktif."
  read -r -p "SSH key ditolak. Gunakan autentikasi password SSH? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || fail "Autentikasi SSH dibatalkan."

  command -v sshpass >/dev/null 2>&1 ||
    fail "Fallback password membutuhkan sshpass. Pasang secara manual, misalnya: sudo apt install sshpass"

  read -r -s -p "SSH password untuk $target: " password
  printf '\n'
  [[ -n "$password" ]] || fail "Password SSH kosong."

  umask 077
  SSH_PASSWORD_FILE="$(mktemp "$ROOT_DIR/.secrets/.ssh-password.XXXXXX")"
  chmod 600 "$SSH_PASSWORD_FILE"
  printf '%s\n' "$password" > "$SSH_PASSWORD_FILE"
  unset password

  SSH_AUTH_ARGS=(--connection-password-file "$SSH_PASSWORD_FILE")
  SSH_AUTH_READY=1
  echo "SSH password disimpan sementara dengan permission 600."
}

ask_become_password() {
  if [[ -z "$BECOME_PASSWORD_FILE" ]]; then
    local password

    read -r -s -p "BECOME password: " password
    printf '\n'
    [[ -n "$password" ]] || fail "Password sudo kosong"

    umask 077
    BECOME_PASSWORD_FILE="$(mktemp "$ROOT_DIR/.secrets/.become-password.XXXXXX")"
    chmod 600 "$BECOME_PASSWORD_FILE"
    printf '%s\n' "$password" > "$BECOME_PASSWORD_FILE"
    unset password

  fi
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

setup_workstation() {
  log "Local workstation setup"

  local os_name=""
  local python_bin=""
  local python_version=""

  os_name="$(uname -s)"
  case "$os_name" in
    Linux|Darwin) ;;
    *) fail "OS tidak didukung: $os_name (dukungan: Linux dan macOS)." ;;
  esac

  if command -v python3 >/dev/null 2>&1; then
    python_bin="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    python_bin="$(command -v python)"
  else
    fail "Python 3 tidak ditemukan. Instal Python 3.11+ lalu jalankan setup kembali."
  fi

  python_version="$("$python_bin" -c '
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
')"

  "$python_bin" -c '
import sys
if sys.version_info < (3, 11):
    raise SystemExit("Python 3.11 atau lebih baru diperlukan.")
' || fail "Python $python_version tidak didukung; diperlukan Python 3.11+."

  if [[ -e "$ROOT_DIR/.venv" ]]; then
    [[ -x "$ROOT_DIR/.venv/bin/python" ]] ||
      fail ".venv sudah ada tetapi bukan virtual environment Unix yang valid. Periksa secara manual; tidak dihapus."
  else
    "$python_bin" -m venv "$ROOT_DIR/.venv" ||
      fail "Gagal membuat .venv. Pastikan dukungan venv tersedia."
  fi

  [[ -f "$ROOT_DIR/requirements-dev.txt" ]] ||
    fail "File dependensi tidak ditemukan: requirements-dev.txt"

  log "Installing workstation dependencies"
  "$ROOT_DIR/.venv/bin/python" -m pip install \
    -r "$ROOT_DIR/requirements-dev.txt" ||
    fail "Gagal memasang dependensi workstation."

  log "Workstation environment ready"
  printf 'OS: %s\n' "$os_name"
  printf 'Base Python: %s\n' "$python_version"
  printf 'Virtual environment: %s/.venv\n' "$ROOT_DIR"
  printf 'Ansible: %s\n' "$("$ROOT_DIR/.venv/bin/ansible" --version | head -n 1)"
  printf '\nAktifkan dengan:\n'
  printf '  source .venv/bin/activate\n'
  printf 'Lalu jalankan tes:\n'
  printf '  ./quick-start.sh test\n'
}

unit_test() {
  log "Local Python unit tests"

  local python_bin=""

  if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
    python_bin="$ROOT_DIR/.venv/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    python_bin="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    python_bin="$(command -v python)"
  else
    fail "Python tidak ditemukan. Jalankan ./quick-start.sh setup terlebih dahulu."
  fi

  [[ -d "$ROOT_DIR/tests" ]] ||
    fail "Direktori unit test tidak ditemukan: tests/"

  log "Python interpreter: $python_bin"

  PYTHONPATH="$ROOT_DIR/src${PYTHONPATH:+:$PYTHONPATH}" \
    "$python_bin" -m unittest discover \
      -s "$ROOT_DIR/tests" -p 'test_*.py' -v
}

ollama_test() {
  log "Ollama API smoke test"

  [[ -n "$ANSIBLE_BIN" && -x "$ANSIBLE_BIN" ]] ||
    fail "ansible tidak ditemukan. Jalankan ./quick-start.sh setup terlebih dahulu."

  [[ -f "$INVENTORY_FILE" ]] ||
    fail "Inventory tidak ditemukan: $INVENTORY_FILE"

  [[ -f tests/ollama_api_smoke.py ]] ||
    fail "tests/ollama_api_smoke.py tidak ditemukan."

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
    fail "ansible tidak ditemukan. Jalankan ./quick-start.sh setup terlebih dahulu."

  [[ -f "$INVENTORY_FILE" ]] ||
    fail "Inventory tidak ditemukan: $INVENTORY_FILE"

  [[ -f "$ROOT_DIR/tests/local_ai_api_smoke.py" ]] ||
    fail "tests/local_ai_api_smoke.py tidak ditemukan."

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


phase="${1:-all}"

case "$phase" in
  setup)
    setup_workstation
    ;;

  workstation)
    [[ -x "$ROOT_DIR/.venv/bin/ansible-playbook" ]] ||
      fail "Ansible belum tersedia. Jalankan ./quick-start.sh setup terlebih dahulu."
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
    verify_gpu
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
    backup_tailscale
    run_playbook tailscale-client
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
    backup_tailscale
    run_playbook security-baseline
    run_playbook tailscale-client

    run_playbook gpu
    verify_gpu

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
