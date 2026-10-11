# Local AI Platform

Ansible-managed private AI server built on Debian, NVIDIA GPU, Ollama, and Open WebUI.

## Project Goals

Build a secure, reproducible, private local AI platform that can be operated
and maintained through Infrastructure as Code.

## Scope

- Debian server baseline and security hardening
- NVIDIA GPU driver and GPU acceleration
- Docker Engine and container lifecycle management
- Ollama model serving
- Open WebUI with authentication
- Private remote access through Tailscale
- Persistent storage, backup, and recovery
- Health checks, operational documentation, and validation

## Out of Scope

The Kubernetes platform, GitOps platform, and application deployment
infrastructure remain managed by the separate `platform-engineering-lab`
repository.

## Repository Structure

- `ansible/inventory/`: hosts and environment variables
- `ansible/playbooks/`: entry-point playbooks
- `ansible/roles/`: reusable, idempotent configuration roles
- `docs/`: architecture, operational procedures, and decisions

## Roadmap

### Phase 1 - Discovery and Repository Foundation

- [x] Create a dedicated Git repository
- [x] Establish the initial Ansible directory structure
- [ ] Document the initial server state and hardware
- [ ] Define inventory, variables, and Ansible conventions
- [ ] Define storage layout and service ports

### Phase 2 - Debian Baseline and Security

- [ ] Validate SSH access and privilege escalation
- [ ] Configure package repositories through Ansible
- [ ] Apply system updates and install required utilities
- [ ] Establish a non-root administrative account
- [ ] Harden SSH and validate access before disabling root login
- [ ] Configure firewall rules with an explicit access policy
- [ ] Review unattended security updates and time synchronization

### Phase 3 - NVIDIA GPU

- [ ] Verify Debian repository and driver support
- [ ] Install kernel headers and NVIDIA driver through Ansible
- [ ] Reboot safely when required
- [ ] Validate driver loading and `nvidia-smi`
- [ ] Verify GPU acceleration with an inference workload

### Phase 4 - Container Runtime

- [ ] Install and configure Docker Engine through Ansible
- [ ] Define persistent data directories and permissions
- [ ] Configure container restart policies and logging
- [ ] Validate runtime health and recovery after reboot

### Phase 5 - AI Services

- [ ] Deploy Ollama
- [ ] Persist models and application data
- [ ] Deploy Open WebUI
- [ ] Configure authentication and restrict direct service exposure
- [ ] Validate model downloads, inference, and GPU utilization

### Phase 6 - Private Access and Security Validation

- [ ] Configure Tailscale through Ansible
- [ ] Restrict remote access to authorized devices
- [ ] Ensure Ollama is not exposed directly to the public internet
- [ ] Validate firewall, service binding, and authentication
- [ ] Test access from the LAN and the private network

### Phase 7 - Operations and Recovery

- [ ] Document backup and restore procedures
- [ ] Test recovery of configuration and persistent data
- [ ] Add service health checks and resource monitoring
- [ ] Document troubleshooting and maintenance procedures
- [ ] Validate full service recovery after a host reboot

## Working Principles

- Ansible is the source of truth for managed system configuration.
- Prefer idempotent roles and explicit variables over ad-hoc changes.
- Inspect the current state before applying changes.
- Validate syntax and use check mode where practical before making changes.
- Keep credentials, tokens, and secrets out of Git.
- Do not expose administrative interfaces or model-serving endpoints publicly
  without an explicit security design.
- Mark roadmap items complete only after verification.

## Initial Server State

The initial target is `debian12ai`, running Debian 12.

Initial discovery found an NVIDIA T600 GPU using the `nouveau` kernel driver.
Secure Boot is disabled. The NVIDIA proprietary driver and Ollama have not yet
been verified as installed.

The APT sources were manually updated to include `contrib` and `non-free`,
in addition to `main` and `non-free-firmware`. This change must be reconciled
into Ansible before the repository is treated as the source of truth.

The dedicated NVMe SSD was intentionally repurposed for this server; its
previous data is out of scope.

## Change Workflow

1. Inspect and record the current state.
2. Make changes through Ansible where practical.
3. Review the diff and validate playbook syntax.
4. Apply changes in controlled steps.
5. Verify service health and security properties.
6. Update this roadmap only after successful validation.
