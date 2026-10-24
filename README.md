# Local AI Platform

Ansible-managed private AI server running Ollama and Open WebUI on Debian or Ubuntu, with NVIDIA GPU acceleration and HTTPS access restricted to the Tailscale network.

The repository is the source of truth for host configuration, container deployment, and the Nginx reverse proxy. Secrets, application backups, and Tailscale state are kept outside Git.

## Overview

### Current deployment

| Component | Current configuration |
|---|---|
| Host | `debian12ai` |
| Operating system | Debian GNU/Linux 12 (Bookworm) |
| LAN address | `192.168.1.4` |
| Tailscale IPv4 | `100.100.83.33` (current; may change if the node identity changes) |
| GPU | NVIDIA T600, 4 GiB VRAM |
| NVIDIA driver | `580.178.04` |
| Container runtime | Docker Engine, Docker Compose plugin, NVIDIA Container Toolkit |
| Ollama image | `ollama/ollama:0.40.3` |
| Default model | `qwen3.5:2b-q4_K_M` |
| Open WebUI image | `ghcr.io/open-webui/open-webui:v0.12.0` |
| Open WebUI URL | `https://chat.wawangholanda.biz.id` |
| Reverse proxy | Nginx + Certbot + Cloudflare DNS-01 |
| Private networking | Tailscale |
| Configuration management | Ansible Core; workstation currently uses `2.21.2` |

These values describe the current host. Review the inventory and role defaults before reusing the repository for another machine.

### Request flow

```text
Browser on an authorized Tailscale device
             |
             | HTTPS :443
             v
chat.wawangholanda.biz.id
Cloudflare DNS-only A record -> Tailscale IPv4
             |
             v
Nginx bound only to the Tailscale interface
             |
             | reverse proxy to 127.0.0.1:3000
             v
Open WebUI container :8080
             |
             | Docker network: ai_backend
             v
Ollama container :11434 -> persistent model storage
```

Security boundaries:

- Open WebUI is published on the host as `127.0.0.1:3000`; it is not intended to be accessed directly from the LAN.
- Ollama's API is available to services on the Docker `ai_backend` network and is not published as a host port.
- Nginx listens on the host's Tailscale IPv4 address, not on the LAN address or `0.0.0.0`.
- Cloudflare DNS is configured as **DNS-only** (`proxied: false`). DNS-01 is used to issue/renew the certificate, so inbound public HTTP validation is not required.
- The hostname resolves to a Tailscale address. Clients must be connected to the authorized tailnet to reach the service.

## Repository layout

```text
.
├── quick-start.sh
├── ansible.cfg
├── ansible/
│   ├── inventory/dev/hosts.yml
│   ├── requirements.yml
│   ├── playbooks/
│   └── roles/
│       ├── apt_baseline/
│       ├── bootstrap/
│       ├── docker/
│       ├── nvidia_container_toolkit/
│       ├── nvidia_gpu/
│       ├── ollama/
│       ├── open_webui/
│       ├── open_webui_reverse_proxy/
│       ├── packages_baseline/
│       ├── security_baseline/
│       └── tailscale_client/
├── docs/
└── .secrets/
    ├── .env.example       # safe template; tracked by Git
    ├── .env                # real values; ignored by Git
    ├── tailscale/          # sensitive node state backup; ignored
    └── open-webui-backups/ # sensitive application archives; ignored
```

## Prerequisites

On the Ansible controller/workstation:

- Python 3 and an Ansible environment. The current workstation environment uses Python `3.14.7` and Ansible Core `2.21.2`.
- Git, SSH access to the target, and sudo privilege for the inventory user.
- Network access to Debian/Docker/NVIDIA/Tailscale package repositories, GHCR, and the Cloudflare API.
- A Cloudflare API token restricted to the domain's zone, with `Zone: Read`, `DNS: Read`, and `DNS: Edit` permissions.
- A hostname within a Cloudflare-managed zone.

The target OS must be Debian or Ubuntu on a supported architecture. The target address and SSH account are configured in the local inventory; do not assume example IP addresses or usernames match your environment.

## Configure secrets

Run all commands below from the repository root.

The script reads `.secrets/.env`. If the file is missing or required values are empty, `quick-start.sh` prompts interactively for the missing values. The Cloudflare token prompt is hidden. It creates the file with restrictive permissions.

To create the file manually from the template instead:

```bash
mkdir -p .secrets
chmod 700 .secrets
cp .secrets/.env.example .secrets/.env
chmod 600 .secrets/.env
nano .secrets/.env
```

The file needs these values:

```dotenv
CLOUDFLARE_API_TOKEN=replace_with_a_scoped_cloudflare_api_token
OPEN_WEBUI_DOMAIN=chat.wawangholanda.biz.id
```

Use your own domain and token. Do not put a real token in `.secrets/.env.example`, inventory, playbooks, role defaults, or README files. Never print the token into terminal logs or commit it to Git.

Verify local permissions without displaying the values:

```bash
stat -c '%a %n' .secrets .secrets/.env
```

Expected permissions are `700` for `.secrets` and `600` for `.secrets/.env`.

The `.gitignore` file excludes local secret files and backups, while allowing `.secrets/.env.example` to be tracked. To verify a sensitive file is ignored:

```bash
git check-ignore -v .secrets/.env
git check-ignore -v .secrets/tailscale/debian12ai/tailscaled.state
```

## Quick start

Make the script executable once:

```bash
chmod +x quick-start.sh
```

### Recommended staged deployment

For a new host, use phases so that driver reboots, Tailscale enrollment, and service exposure can be checked individually.

1. Validate the workstation and secret configuration:

   ```bash
   ./quick-start.sh preflight
   ```

2. Install required Ansible collections and syntax-check every playbook:

   ```bash
   ./quick-start.sh ansible
   ```

3. Bootstrap Python if needed, update the APT cache without replacing existing repository configuration, install baseline tools, and apply the SSH baseline:

   ```bash
   ./quick-start.sh baseline
   ```

4. Install/ensure the Tailscale client and back up any existing client state:

   ```bash
   ./quick-start.sh tailscale
   ```

   The role ensures the package and daemon are present; it does **not** run `tailscale up` or authenticate a new node automatically. For a new host, enroll it in the correct tailnet and verify `tailscale ip -4` before setting up the proxy. Do not re-authenticate an already-enrolled node as part of routine reconciliation.

5. Configure the NVIDIA driver and verify the GPU:

   ```bash
   ./quick-start.sh gpu
   ```

   Installing a driver can require a reboot. If `nvidia-smi` fails immediately after driver changes, reboot the host through your normal maintenance procedure, reconnect, and rerun this phase to verify the driver before continuing.

6. Install Docker and NVIDIA Container Toolkit:

   ```bash
   ./quick-start.sh runtime
   ```

7. Deploy or reconcile Ollama and Open WebUI:

   ```bash
   ./quick-start.sh services
   ```

8. Configure Cloudflare DNS, Certbot DNS-01, and the private Nginx reverse proxy:

   ```bash
   ./quick-start.sh proxy
   ```

9. Run end-to-end validation:

   ```bash
   ./quick-start.sh validate
   ```

The phases are idempotent where supported by their Ansible roles. Review playbook output, especially where package installation, kernel drivers, service restarts, or database migrations are involved.

### Full orchestration

For a host whose SSH access and sudo work, whose Tailscale node is already enrolled, and which does not need an intervening driver reboot, the script also provides:

```bash
./quick-start.sh all
```

A brand-new Tailscale node may require manual enrollment, and a newly installed NVIDIA driver may require a reboot. For those situations, prefer the staged deployment above rather than expecting `all` to be completely unattended.

### Available phases

| Command | Purpose |
|---|---|
| `./quick-start.sh setup` | Create the workstation virtual environment and install pinned development dependencies |
| `./quick-start.sh workstation` | Validate workstation OS and Python version |
| `./quick-start.sh test` | Run local unit tests |
| `./quick-start.sh preflight` | Check repository prerequisites and required configuration |
| `./quick-start.sh ansible` | Install collections and syntax-check playbooks |
| `./quick-start.sh baseline` | Bootstrap Python and apply Debian/Ubuntu security baseline |
| `./quick-start.sh tailscale` | Back up existing Tailscale state and ensure the client package/service |
| `./quick-start.sh gpu` | Apply NVIDIA GPU configuration and verify `nvidia-smi` |
| `./quick-start.sh runtime` | Configure Docker and NVIDIA Container Toolkit after GPU readiness |
| `./quick-start.sh services` | Deploy Ollama, the local AI API gateway, and Open WebUI |
| `./quick-start.sh api-test` | Smoke-test the FastAPI gateway health and chat endpoints on the target |
| `./quick-start.sh ollama-test` | Run the Ollama API smoke test inside the Docker network |
| `./quick-start.sh proxy` | Deploy Nginx, Cloudflare DNS automation, and HTTPS |
| `./quick-start.sh validate` | Check SSH/Ansible connectivity, Tailscale, Docker, GPU, and HTTPS |
| `./quick-start.sh backup-webui` | Create and fetch a consistent Open WebUI backup before maintenance/upgrades |
| `./quick-start.sh fetch-webui-backup` | Fetch and verify the existing pre-`v0.12.0` archive under `.secrets/open-webui-backups/`; intended for recovery of that existing archive |

The script asks for the sudo/become password when needed. It uses a temporary password file during execution and removes it on exit; do not store the sudo password in the repository or `.secrets/.env`.

## Services and persistent data

| Service | Container/host setting | Persistent location |
|---|---|---|
| Ollama | Container `ollama`; internal API port `11434` on `ai_backend` | `/srv/ai/ollama/data` |
| Open WebUI | Container `open-webui`; host bind `127.0.0.1:3000` to container port `8080` | `/srv/ai/open-webui/data` |
| Open WebUI Compose | Host-managed Compose file | `/srv/ai/open-webui/compose.yml` |
| Open WebUI application secret | Host environment file, mode `0600` | `/srv/ai/open-webui/.env` |
| Nginx site | Tailscale-only listener on ports `80` and `443` | `/etc/nginx/sites-available/local-ai-open-webui` |
| Cloudflare Certbot credentials | Root-only token file, mode `0600` | `/etc/letsencrypt/cloudflare-local-ai-platform.ini` |
| TLS certificate | Certbot-managed certificate for the configured domain | `/etc/letsencrypt/live/` |
| Tailscale state backup | Sensitive node identity/state | `.secrets/tailscale/debian12ai/tailscaled.state` |
| Open WebUI backup archive | Sensitive application data and config | `.secrets/open-webui-backups/` |

Ollama model weights persist independently of the Open WebUI backup. Back up `/srv/ai/ollama/data` separately if model downloads would be expensive or time-consuming to reproduce.

### Local AI API

The FastAPI gateway provides an HTTP interface to the configured Ollama model:

- `GET http://127.0.0.1:8000/health` — API process health check.
- `POST http://127.0.0.1:8000/api/chat` — submit a JSON prompt; the response contains `answer` and `model`.
- `http://127.0.0.1:8000/docs` — interactive API documentation, accessible from the target host.

Example request from the target host:

```bash
curl -fsS http://127.0.0.1:8000/health
curl -fsS http://127.0.0.1:8000/api/chat \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Explain Kubernetes briefly"}'
```

The API host port is bound to loopback, not the LAN interface. Ollama's API remains internal to the Docker network; do not publish port `11434` to the host or expose the gateway publicly without an intentional authentication and access-control design. The health endpoint checks the API process, not whether Ollama can generate a response.

## Operating and troubleshooting

### Check current state

```bash
# From the controller; these commands do not require sudo on the target.
ansible ai_servers -e '{"ansible_become": false}' -m ansible.builtin.ping
ansible ai_servers -e '{"ansible_become": false}' -m ansible.builtin.command -a 'docker ps'
ansible ai_servers -e '{"ansible_become": false}' -m ansible.builtin.command -a 'docker exec ollama ollama list'

# Commands requiring elevated access on the target
ansible ai_servers -K -m ansible.builtin.shell -a 'systemctl status nginx tailscaled --no-pager'
ansible ai_servers -K -m ansible.builtin.shell -a 'journalctl -u nginx -n 100 --no-pager'
```

When inventory has `ansible_become: true`, ad-hoc commands can ask for a sudo password even for simple modules. Use `-K` for become-password prompting, or explicitly set `-e '{"ansible_become": false}'` for read-only checks that need no privilege escalation.

### Open WebUI is healthy locally but HTTPS is unavailable

The Open WebUI host binding is intentionally loopback-only, so direct access to `http://192.168.1.4:3000` from another LAN device is expected to fail. Use the HTTPS hostname from an authorized Tailscale device.

Check the Tailscale interface and Nginx service:

```bash
ansible ai_servers -K -m shell -a 'tailscale ip -4; ip -4 addr show dev tailscale0; systemctl status nginx --no-pager -l'
ansible ai_servers -K -m shell -a 'nginx -t; ss -lntp | grep -E ":(80|443)([[:space:]]|$)" || true'
```

Nginx is configured to depend on Tailscale and use a readiness script. This host previously experienced an Nginx startup race during boot when the Tailscale address was not yet assigned. If that happens, first verify that the correct address is present on `tailscale0`; only then start/restart Nginx and inspect the logs:

```bash
sudo systemctl restart nginx
sudo systemctl status nginx --no-pager -l
sudo journalctl -u nginx -n 80 --no-pager
```

The address check and startup dependency should be reviewed after a controlled reboot; do not assume a successful configuration test by itself means Nginx is running.

### Check Open WebUI startup or migration errors

```bash
ansible ai_servers -e '{"ansible_become": false}' -m ansible.builtin.shell -a 'docker ps -a --filter name=open-webui; docker logs --since 15m --tail 100 open-webui'
```

A healthy container and `HTTP 200` from `http://127.0.0.1:3000/` confirm the local application endpoint, but still test login, chat history, model responses, and HTTPS through Tailscale from a browser.

### Slow model responses

The host has an NVIDIA T600 with 4 GiB VRAM. Response time depends on prompt length, model context, reasoning/thinking mode, generated token count, and GPU usage. Check that the model is available with `docker exec ollama ollama list`, and that the GPU driver is healthy with `nvidia-smi`.

### Cloudflare or certificate problems

- Ensure the token has the required permissions for the intended Cloudflare zone.
- Check that the hostname's A record points to the current Tailscale IPv4 and has Cloudflare proxying disabled (`proxied: false`).
- Check `/etc/letsencrypt/` and `journalctl -u nginx`; do not print or share the Cloudflare credentials file.
- DNS-01 does not require inbound public HTTP validation. Access to the application remains dependent on Tailscale connectivity.

## Backup and upgrade procedure

### Back up Open WebUI

Before upgrading Open WebUI or changing database-related settings:

```bash
./quick-start.sh backup-webui
```

The backup playbook stops the Open WebUI container while it archives `/srv/ai/open-webui`, validates the archive, fetches it to the controller, verifies the local copy, and restores the container to a running state after the archive attempt. The archive includes application data, SQLite database files, vector database, uploads, Compose configuration, and the application `.env` secret. Protect it as sensitive data.

Backups are stored under `.secrets/open-webui-backups/`, with directory/file permissions restricted. Keep a verified pre-upgrade archive until the upgraded application has been checked.

The current `fetch-webui-backup` phase is specifically for recovering an already-created pre-`v0.12.0` archive. For routine future backups, use `backup-webui`.

### Upgrade Open WebUI

1. Read the [official updating guide](https://docs.openwebui.com/getting-started/updating/) and relevant release notes.
2. Run `./quick-start.sh backup-webui` and confirm that a non-empty archive exists locally, has mode `0600`, passes `tar -tzf`, and matches the remote SHA-256 when applicable.
3. Change the pinned image in `ansible/roles/open_webui/defaults/main.yml` only after reviewing the target version:

   ```yaml
   open_webui_image: "ghcr.io/open-webui/open-webui:vX.Y.Z"
   ```

4. Validate all playbooks and whitespace:

   ```bash
   ./quick-start.sh ansible
   git diff --check
   ```

5. Apply the update through Ansible:

   ```bash
   ./quick-start.sh services
   ```

6. Validate the new image, container health, authentication, existing conversation history, model responses, and HTTPS through Tailscale.
7. Keep the backup until all checks pass. Database migrations can be one-way; reverting only the image tag may not restore compatibility with an already-migrated database. Restore the pre-upgrade data backup if necessary.

Do not use `docker compose down -v` for routine updates; deleting the persistent volume/directory can destroy application data.

### Tailscale state backup

The state file under `.secrets/tailscale/` contains sensitive node identity material. Keep it out of Git, restrict its permissions, and do not paste, email, or upload it. A state backup is for recovery of the same node; do not clone one node's state to multiple Tailscale devices.

## Security notes

- `PermitRootLogin no` is part of the SSH baseline. Password authentication remains enabled alongside public-key authentication to avoid locking out the current admin prematurely; reassess it after key-only access is independently verified.
- User `novan` belongs to the `docker` group. Membership in the Docker group is effectively root-equivalent on the host and should be limited to trusted administrators.
- Open WebUI signup is currently enabled in role defaults. Review user-registration settings after the first account is created, depending on intended usage.
- Keep package and container versions pinned in Ansible and review release notes before changing them.
- Never commit `.secrets/.env`, Tailscale state, application backup archives, generated keys, or certificates' private keys.

## Reference documentation

- [Open WebUI update and rollback guidance](https://docs.openwebui.com/getting-started/updating/)
- [Open WebUI backup guidance](https://docs.openwebui.com/tutorials/maintenance/backups/)
- [Open WebUI SQLite database export/import notes](https://docs.openwebui.com/tutorials/maintenance/database/)
- [Open WebUI quick start](https://docs.openwebui.com/getting-started/quick-start/)

## Support the Project

If this project helps you, you can
support its continued development.

### 🇮🇩 Indonesia

Support via QRIS:

![QRIS support](assets/qris.png)

Scan the QRIS code to support the project.

### 🌎 International

International supporters can use Ko-fi:

[☕ Support via Ko-fi](https://ko-fi.com/wawangholanda)

Thank you for supporting open-source learning and continued development of the project.
