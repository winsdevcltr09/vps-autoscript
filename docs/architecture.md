# Architecture Overview

## System Architecture

```
Internet Client
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│                    VPS (Ubuntu/Debian)                       │
│                                                             │
│  Port 443 (TLS) ────────────────────────────────────────   │
│      │                                                      │
│      ▼                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    NGINX (TLS Terminator)             │  │
│  │  ssl_certificate: /etc/xray/xray.crt (Let's Encrypt) │  │
│  └──────────────────────────────────────────────────────┘  │
│      │                                                      │
│      ├─ /vmess     ──► localhost:23456  (Xray VMess WS)    │
│      ├─ /vless     ──► localhost:14016  (Xray VLESS WS)    │
│      ├─ /trojan-ws ──► localhost:25432  (Xray Trojan WS)   │
│      ├─ /trojango  ──► localhost:2087   (Trojan-Go)        │
│      ├─ /vmess-grpc──► localhost:31234  (Xray VMess gRPC)  │
│      ├─ /vless-grpc──► localhost:24456  (Xray VLESS gRPC)  │
│      └─ /trojan-grpc─► localhost:33456  (Xray Trojan gRPC) │
│                                                             │
│  Port 22  ──────────────────────► OpenSSH                  │
│  Port 2095 (WS) ───────────────── ws-openssh.py            │
│                                  └──► localhost:22 (SSH)   │
│  Port 2096 (WS) ───────────────── ws-dropbear.py           │
│                                  └──► localhost:444 (DBR)  │
│  Port 444  ────────────────────── Dropbear                 │
│  Port 445  ────────────────────── Stunnel4 ──► Dropbear    │
│  Port 446  ────────────────────── Stunnel4 ──► SSH         │
│                                                             │
│  Port 1194 TCP ────────────────── OpenVPN TCP              │
│  Port 2200 UDP ────────────────── OpenVPN UDP              │
│                                                             │
│  localhost:10085 ──────────────── Xray Stats API           │
└─────────────────────────────────────────────────────────────┘
```

## Module Dependency Graph

```
install.sh
    └── installer/main.sh
        ├── library/common.sh           ← loaded by all modules
        ├── library/logger.sh           ← centralized logging
        ├── library/validation.sh       ← input validation
        ├── library/service_manager.sh  ← systemd operations
        ├── library/dependency_manager.sh
        │
        ├── installer/system_check.sh   ← preflight checks
        ├── installer/ssl.sh            ← Let's Encrypt via acme.sh
        ├── installer/xray.sh           ← Xray-core + Trojan-Go
        ├── installer/nginx.sh          ← Nginx reverse proxy
        ├── installer/ssh_setup.sh      ← SSH stack
        └── installer/openvpn.sh        ← OpenVPN TCP+UDP

menu/main.sh (runtime)
    ├── service/ssh_user.sh             ← SSH user CRUD
    ├── service/xray_user.sh            ← Xray user CRUD (jq-based)
    ├── backup/backup.sh                ← backup
    ├── backup/restore.sh               ← restore
    ├── monitoring/status.sh            ← dashboard
    ├── monitoring/health_check.sh      ← auto-heal
    ├── utils/port_manager.sh           ← port changes
    └── update/updater.sh               ← self-update
```

## Key Design Decisions

### 1. jq for JSON manipulation
The original script used `sed`/`grep` to mutate `config.json` — extremely fragile.
This implementation uses `jq` with atomic file writes (write to temp → validate → mv).

### 2. Separate user database
Users are tracked in CSV files (`/etc/vps-autoscript/config/xray_users.db`,
`ssh_users.db`) instead of comments inside config files. This separates
configuration from data and enables safe iteration.

### 3. No hardcoded credentials
Original script had hardcoded Gmail credentials. This implementation:
- Prompts for all credentials interactively
- Stores them in `/etc/vps-autoscript/config/autoscript.conf` (mode 600)
- Never commits credentials to version control

### 4. No /etc/shadow in backups
Original backup included `/etc/shadow`. This implementation explicitly
excludes shadow files. SSH users can be recreated from the users DB on restore.

### 5. Verified downloads
All remote downloads use `safe_download()` which supports SHA256 verification.
No `curl | bash` patterns except for the official Xray installer (which itself
implements signature verification).

### 6. Privilege separation
- Xray runs as `www-data` (not root)
- Only the WS proxy Python scripts and OpenVPN run as root (required)
- Menu scripts drop privileges where possible

### 7. Structured logging
All actions go through `logger.sh`. Audit trail for user CRUD, port changes,
and installations is written to `/var/log/vps-autoscript/autoscript.log`.

### 8. Rollback mechanism
The installer registers rollback steps as it proceeds. On failure (`trap ERR`),
rollback runs in reverse order to clean up partial installations.

## Port Reference

| Port | Protocol | Service | Notes |
|------|----------|---------|-------|
| 22 | TCP | OpenSSH | Standard SSH |
| 80 | TCP | Nginx | HTTP → redirect to HTTPS |
| 443 | TCP | Nginx | TLS terminator |
| 444 | TCP | Dropbear | Alternative SSH |
| 445 | TCP | Stunnel4 | SSL over Dropbear |
| 446 | TCP | Stunnel4 | SSL over OpenSSH |
| 1194 | TCP | OpenVPN | VPN TCP |
| 2095 | TCP | ws-openssh | WS bridge → SSH:22 |
| 2096 | TCP | ws-dropbear | WS bridge → Dropbear:444 |
| 2087 | TCP | Trojan-Go | (internal, via Nginx) |
| 2200 | UDP | OpenVPN | VPN UDP |
| 10085 | TCP | Xray API | Stats, localhost only |
| 14016 | TCP | Xray | VLESS WS (localhost) |
| 23456 | TCP | Xray | VMess WS (localhost) |
| 24456 | TCP | Xray | VLESS gRPC (localhost) |
| 25432 | TCP | Xray | Trojan WS (localhost) |
| 31234 | TCP | Xray | VMess gRPC (localhost) |
| 33456 | TCP | Xray | Trojan gRPC (localhost) |
