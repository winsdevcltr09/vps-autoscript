# VPS Autoscript v3.0.0

A clean, modular, and secure multi-protocol VPN server autoscript for Ubuntu 20.04/22.04/24.04 and Debian 10/11/12.

This is a ground-up rewrite based on reverse engineering of the `gemilangvip/autoscript-vvip` repository, redesigned with modern shell engineering practices.

---

## What This Installs

| Protocol | Transport | TLS | Notes |
|----------|-----------|-----|-------|
| SSH | TCP | via Stunnel4 | OpenSSH + Dropbear |
| SSH | WebSocket | via Nginx 443 | ws-openssh / ws-dropbear |
| VMess | WebSocket | TLS (Nginx) | Xray-core |
| VMess | gRPC | TLS (Nginx) | Xray-core |
| VLESS | WebSocket | TLS (Nginx) | Xray-core |
| VLESS | gRPC | TLS (Nginx) | Xray-core |
| Trojan | WebSocket | TLS (Nginx) | Xray-core |
| Trojan | gRPC | TLS (Nginx) | Xray-core |
| Trojan-Go | WebSocket | TLS (Nginx) | Standalone |
| OpenVPN | TCP | PAM auth | Standard port 1194 |
| OpenVPN | UDP | PAM auth | Port 2200 |

---

## Quick Install

```bash
# Interactive install
bash <(curl -fsSL https://your-domain/install.sh)

# Dry-run (checks only, no changes)
bash <(curl -fsSL https://your-domain/install.sh) --dry-run
```

---

## Requirements

| Item | Requirement |
|------|------------|
| OS | Ubuntu 20.04 / 22.04 / 24.04 or Debian 10 / 11 / 12 |
| Architecture | x86_64 (amd64) |
| Virtualization | KVM, Xen, VMware, Bare metal (NOT OpenVZ/LXC) |
| Root access | Required |
| Kernel | ≥ 4.9 (for BBR support) |
| RAM | ≥ 512 MB (1 GB recommended) |
| Disk | ≥ 5 GB free |
| Domain | Optional (IP-only supported, but SSL cert won't work without domain) |

---

## Repository Structure

```
vps-autoscript/
├── install.sh                   ← Entry point (clone + run)
├── library/
│   ├── common.sh                ← Colors, utilities, global constants
│   ├── logger.sh                ← Structured logging with rotation
│   ├── validation.sh            ← Input validation + sanitization
│   ├── service_manager.sh       ← systemd service operations
│   └── dependency_manager.sh   ← APT + BBR + sysctl
├── installer/
│   ├── main.sh                  ← Installation orchestrator
│   ├── system_check.sh          ← Pre-flight checks + dry-run
│   ├── ssl.sh                   ← Let's Encrypt via acme.sh
│   ├── xray.sh                  ← Xray-core + Trojan-Go
│   ├── nginx.sh                 ← Nginx reverse proxy config
│   ├── ssh_setup.sh             ← SSH, Dropbear, Stunnel4, WS proxy
│   └── openvpn.sh               ← OpenVPN TCP + UDP
├── menu/
│   └── main.sh                  ← Interactive dashboard (type: menu)
├── service/
│   ├── xray_user.sh             ← VMess/VLESS/Trojan user CRUD (jq-based)
│   └── ssh_user.sh              ← SSH/OpenVPN user lifecycle
├── backup/
│   ├── backup.sh                ← Multi-backend backup (rclone/SFTP/local)
│   └── restore.sh               ← Restore with rollback + validation
├── monitoring/
│   ├── status.sh                ← Real-time service/resource dashboard
│   └── health_check.sh          ← Auto-heal + Telegram alerts
├── update/
│   └── updater.sh               ← Integrity-verified self-update
├── utils/
│   ├── port_manager.sh          ← Port change with conflict detection
│   └── cert_manager.sh          ← SSL certificate operations
├── config/
│   ├── defaults.conf            ← All default configuration values
│   └── xray_template.json       ← Xray config.json template
└── docs/
    ├── architecture.md          ← System architecture + port map
    └── troubleshooting.md       ← Common issues + solutions
```

---

## Post-Install Commands

```bash
menu              # Open the interactive dashboard
autoscript        # Alias for menu

autoscript-status # Show service/resource status
autoscript-health-check  # Run health checks
autoscript-backup # Run manual backup
autoscript-update # Check and apply updates
```

---

## User Management

### SSH Users

```bash
# From menu: [1] SSH Management
# - Create / Delete / Renew / Lock / Unlock accounts
# - Multi-login limiter (kills excess sessions without restarting SSH service)
# - Auto-delete expired accounts via daily cron
```

### Xray Users (VMess / VLESS / Trojan)

```bash
# From menu: [2] VMess / [3] VLESS / [4] Trojan
# - Create account with expiry
# - Auto-generates vmess:// vless:// trojan:// connection links
# - Traffic stats via Xray API
# - Auto-delete expired accounts via daily cron
```

---

## Backup & Restore

```bash
# Configure rclone (Google Drive, S3, etc.)
rclone config --config /etc/vps-autoscript/config/rclone.conf

# Or configure via menu: [6] Backup & Restore → [5] Configure Backend

# Manual backup
autoscript-backup

# Enable auto-backup (daily at 00:05)
autoscript → [6] → [2]
```

**What is backed up:**
- `/etc/xray/config.json` + SSL certs
- `/etc/vps-autoscript/config/` (user databases + config)
- `/etc/openvpn/` PKI (CA + client certs)
- `/etc/nginx/conf.d/xray.conf`
- `/etc/trojan-go/config.json`
- acme.sh certificates

**What is NOT backed up (by design):**
- `/etc/shadow` — contains password hashes, never backed up to cloud storage
- `/etc/passwd`, `/etc/group` — regenerated from user DB on restore

---

## Security Improvements Over Original

| Issue | Original | This Version |
|-------|----------|-------------|
| Gmail password hardcoded | ✗ Yes, in plaintext | ✓ User-provided, stored encrypted |
| `/etc/shadow` in backup | ✗ Yes, uploaded to cloud | ✓ Explicitly excluded |
| Binary payloads unauditable | ✗ bzip2/UPX binaries | ✓ All plaintext shell scripts |
| IP-based DRM | ✗ Remote check required | ✓ Removed (unnecessary for self-hosted) |
| JSON edited with sed/grep | ✗ Fragile, corruption-prone | ✓ `jq` with atomic writes + validation |
| SSH restart on each autokill | ✗ Drops all connections | ✓ Per-user `pkill -HUP` only |
| Hardcoded UUID for all protocols | ✗ All protocols share one UUID | ✓ Per-user UUID per protocol |
| curl \| bash without verify | ✗ Multiple remote scripts | ✓ SHA256 verification where possible |
| eval-based obfuscation | ✗ jam.sh, slow.sh | ✓ No obfuscation |

---

## Configuration

All configuration is in `/etc/vps-autoscript/config/autoscript.conf`.
Defaults are in `config/defaults.conf`.

Key settings:

```bash
INSTALL_DOMAIN=vpn.example.com
ADMIN_EMAIL=admin@example.com
PORT_SSHWS=2095
ENABLE_BBR=true
BACKUP_ENABLED=true
BACKUP_BACKEND=rclone
BACKUP_RCLONE_REMOTE=gdrive
NOTIFY_TELEGRAM_ENABLED=true
NOTIFY_TELEGRAM_BOT_TOKEN=...
NOTIFY_TELEGRAM_CHAT_ID=...
```

---

## Cron Jobs

Installed automatically:

| Schedule | Job | Purpose |
|----------|-----|---------|
| `0 0 * * *` | ssh_user.sh --purge-expired | Delete expired SSH users |
| `5 0 * * *` | xray_user.sh --purge-expired | Delete expired Xray users |
| `*/5 * * * *` | autoscript-health-check | Auto-heal services + alert |
| `15 3 */2 * *` | acme.sh --cron | SSL auto-renewal |
| `0 2 * * *` | /sbin/reboot | Auto-reboot (if enabled) |
| `5 0 * * *` | autoscript-backup | Auto-backup (if enabled) |
| `*/1 * * * *` | ssh_user.sh --enforce-limit | Multi-login limiter (if set) |

---

## Acknowledgements

Protocol implementations use:
- [Xray-core](https://github.com/XTLS/Xray-core) — XTLS Project
- [Trojan-Go](https://github.com/p4gefau1t/trojan-go) — p4gefau1t
- [acme.sh](https://github.com/acmesh-official/acme.sh) — neilpang
- [OpenVPN](https://openvpn.net/)
- [Let's Encrypt](https://letsencrypt.org/)

---

## License

MIT License — see LICENSE file.
