# Initial Server State

## Host Information

| Item | Value |
|---|---|
| Hostname | debian12ai |
| Operating System | Debian GNU/Linux 12 (bookworm) |
| Kernel | Linux 6.1.0-53-amd64 |
| Architecture | x86-64 |
| Hardware Vendor | MSI |
| Hardware Model | MS-7972 |
| Firmware Version | A.60 |

---

## CPU and Memory

### CPU

| Item | Value |
|---|---|
| CPU Model | Intel(R) Core(TM) i7-6700 CPU @ 3.40GHz |
| CPU Count | 8 |
| NUMA Node | node0 |

### Memory

| Item | Value |
|---|---|
| RAM | 62 GiB |
| Swap | 976 MiB |

---

## Storage

Current system storage:

| Device | Size | Type | Mount |
|---|---|---|---|
| nvme0n1 | 931.5G | NVMe SSD | System disk |

Partition layout:

```text
nvme0n1
├── nvme0n1p1  512M     EFI System Partition
├── nvme0n1p2  930.1G   Root filesystem (/)
└── nvme0n1p3  977M     Swap
```

Current storage layout is a single-disk configuration.

Future persistent application data should be managed explicitly through
Ansible configuration.

Planned data structure:

```text
/srv/ai/
├── ollama/
├── open-webui/
├── docker/
└── backups/
```

---

## GPU

Detected GPU:

```text
NVIDIA Corporation TU117GL [T600] (rev a1)
```

Current kernel driver:

```text
nouveau
```

GPU acceleration status:

| Component | Status |
|---|---|
| NVIDIA proprietary driver | Not installed |
| CUDA | Not configured |
| nvidia-smi validation | Not completed |

The NVIDIA driver installation will be managed through Ansible in a dedicated
role.

---

## Network

Current AI server:

| Item | Value |
|---|---|
| Hostname | debian12ai |
| LAN IP | 192.168.1.4 |
| SSH User | novan |

Remote administration:

```text
SSH → novan user → sudo privilege escalation
```

---

## Security Baseline Status

SSH security baseline has been applied through Ansible.

Managed configuration:

```text
/etc/ssh/sshd_config.d/99-local-ai-platform.conf
```

Current SSH policy:

| Setting | Value |
|---|---|
| PermitRootLogin | no |
| PasswordAuthentication | yes |
| PubkeyAuthentication | yes |
| X11Forwarding | no |
| AllowTcpForwarding | yes |
| MaxAuthTries | 4 |

Validation completed:

```text
sshd -T
SSH login validation
Ansible idempotency check
```

---

## Ansible Management State

Repository:

```text
local-ai-platform
```

Current roles:

```text
ansible/roles/

├── bootstrap
└── security_baseline
```

Current playbooks:

```text
ansible/playbooks/

├── bootstrap.yml
└── security-baseline.yml
```

---

## Completed Validation

- [x] Ansible repository initialized
- [x] Inventory created
- [x] Bootstrap role created
- [x] Python availability validated
- [x] Security baseline role created
- [x] SSH hardening applied
- [x] SSH configuration validated
- [x] Ansible idempotency verified

---

## Pending Configuration

The following components are not yet deployed:

- NVIDIA proprietary driver
- CUDA runtime
- Docker Engine
- NVIDIA Container Toolkit
- Ollama
- Open WebUI
- Tailscale private access
- Backup strategy
- Monitoring and health checks

---

## Notes

This document represents the initial discovered state of the Debian 12 AI
server before application platform deployment.

All future system changes should be managed through Ansible and recorded in
the repository roadmap after successful validation.
