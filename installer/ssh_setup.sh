#!/usr/bin/env bash
# =============================================================================
# ssh_setup.sh — SSH, Dropbear, Stunnel4, and WebSocket proxy setup
# =============================================================================

[[ -n "${_INSTALLER_SSH_SH:-}" ]] && return 0
readonly _INSTALLER_SSH_SH=1

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"
source "${LIB_DIR_LOCAL}/dependency_manager.sh"

readonly SSH_WS_PROXY_PATH="/usr/local/lib/vps-autoscript/ws_proxy.py"
readonly DROPBEAR_DEFAULT_PORT=444
readonly STUNNEL_CONF="/etc/stunnel/stunnel.conf"

# -----------------------------------------------------------------------------
# OpenSSH hardening
# -----------------------------------------------------------------------------

harden_openssh() {
  local sshd_conf="/etc/ssh/sshd_config"
  step "Hardening OpenSSH configuration..."

  # Backup original
  [[ -f "${sshd_conf}.orig" ]] || cp "${sshd_conf}" "${sshd_conf}.orig"

  # Apply secure defaults
  local settings=(
    "PermitRootLogin yes"
    "PasswordAuthentication yes"
    "ChallengeResponseAuthentication no"
    "UsePAM yes"
    "PrintMotd no"
    "AcceptEnv LANG LC_*"
    "Subsystem sftp /usr/lib/openssh/sftp-server"
    "MaxAuthTries 3"
    "LoginGraceTime 30"
    "ClientAliveInterval 60"
    "ClientAliveCountMax 3"
  )

  # Write a clean config
  {
    echo "# OpenSSH — managed by vps-autoscript"
    for setting in "${settings[@]}"; do
      echo "${setting}"
    done
  } > "${sshd_conf}"

  # Validate
  sshd -t 2>/dev/null || { cp "${sshd_conf}.orig" "${sshd_conf}"; fatal "SSH config validation failed. Restored original."; }
  systemctl reload ssh || systemctl reload sshd
  success "OpenSSH hardened."
}

# Set custom SSH banner
set_ssh_banner() {
  local banner_file="/etc/issue.net"
  cat > "${banner_file}" <<'EOF'
  ╔══════════════════════════════════════╗
  ║     VPS Server — Authorized Access   ║
  ║     Unauthorized access prohibited   ║
  ╚══════════════════════════════════════╝
EOF
  sed -i 's|^#Banner.*|Banner /etc/issue.net|' /etc/ssh/sshd_config
  systemctl reload ssh 2>/dev/null || true
  success "SSH banner set."
}

# -----------------------------------------------------------------------------
# Dropbear
# -----------------------------------------------------------------------------

install_dropbear() {
  local port="${1:-${DROPBEAR_DEFAULT_PORT}}"
  step "Installing Dropbear (port ${port})..."
  apt_install dropbear-run dropbear-bin

  # Configure
  sed -i "s/NO_START=1/NO_START=0/" /etc/default/dropbear 2>/dev/null || true
  sed -i "s/DROPBEAR_PORT=.*/DROPBEAR_PORT=${port}/" /etc/default/dropbear
  # Disable password-less and root by key only — allow password auth
  sed -i "s/DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS=\"-w -s -p ${port}\"/" /etc/default/dropbear 2>/dev/null || true

  # Write override
  mkdir -p /etc/systemd/system/dropbear.service.d
  cat > /etc/systemd/system/dropbear.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/dropbear -F -E -p ${port} -w -s
EOF

  systemctl daemon-reload
  svc_enable dropbear
  success "Dropbear installed on port ${port}."
}

# -----------------------------------------------------------------------------
# Stunnel4 — SSL tunneling for SSH
# -----------------------------------------------------------------------------

install_stunnel() {
  local ssl_port="${1:-445}"
  local cert_file="${XRAY_CONF_DIR:-/etc/xray}/xray.crt"
  local key_file="${XRAY_CONF_DIR:-/etc/xray}/xray.key"
  local ssh_port="${PORT_SSH:-22}"
  local dropbear_port="${DROPBEAR_DEFAULT_PORT}"

  step "Configuring Stunnel4 (SSL port ${ssl_port})..."
  apt_install stunnel4

  # Enable stunnel on boot
  sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4 2>/dev/null || true

  cat > "${STUNNEL_CONF}" <<EOF
; Stunnel4 — managed by vps-autoscript
; Generated: $(date '+%Y-%m-%d %H:%M:%S')

pid = /var/run/stunnel4/stunnel.pid
output = /var/log/stunnel4/stunnel.log

[dropbear-ssl]
accept  = ${ssl_port}
connect = 127.0.0.1:${dropbear_port}
cert    = ${cert_file}
key     = ${key_file}
TIMEOUTclose = 0

[openssh-ssl]
accept  = $((ssl_port + 1))
connect = 127.0.0.1:${ssh_port}
cert    = ${cert_file}
key     = ${key_file}
TIMEOUTclose = 0
EOF

  svc_enable stunnel4
  success "Stunnel4 configured (ports ${ssl_port}, $((ssl_port+1)))."
}

# -----------------------------------------------------------------------------
# SSH WebSocket proxy (pure Python, no binary dependencies)
# -----------------------------------------------------------------------------

write_ws_proxy() {
  local proxy_port="${1:-2095}"
  local backend_host="${2:-127.0.0.1}"
  local backend_port="${3:-22}"
  local service_name="${4:-ws-openssh}"

  ensure_dir "$(dirname "${SSH_WS_PROXY_PATH}")" 755

  cat > "${SSH_WS_PROXY_PATH}" <<'PYEOF'
#!/usr/bin/env python3
"""
ws_proxy.py — Minimal WebSocket-to-TCP bridge for SSH tunneling.
Usage: ws_proxy.py <listen_port> <backend_host> <backend_port>
"""

import asyncio
import sys
import logging

logging.basicConfig(level=logging.WARNING, format='%(asctime)s %(levelname)s %(message)s')
logger = logging.getLogger(__name__)

LISTEN_PORT  = int(sys.argv[1]) if len(sys.argv) > 1 else 2095
BACKEND_HOST = sys.argv[2]     if len(sys.argv) > 2 else "127.0.0.1"
BACKEND_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 22

WS_HANDSHAKE_RESPONSE = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n"
    b"\r\n"
)

async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
        pass
    finally:
        writer.close()

async def handle_client(client_reader, client_writer):
    peer = client_writer.get_extra_info('peername')
    try:
        # Read HTTP CONNECT or WebSocket upgrade request
        header_data = b""
        while b"\r\n\r\n" not in header_data:
            chunk = await asyncio.wait_for(client_reader.read(4096), timeout=10)
            if not chunk:
                return
            header_data += chunk

        # Send WebSocket upgrade response
        client_writer.write(WS_HANDSHAKE_RESPONSE)
        await client_writer.drain()

        # Connect to backend
        backend_reader, backend_writer = await asyncio.open_connection(BACKEND_HOST, BACKEND_PORT)

        # Bidirectional pipe
        await asyncio.gather(
            pipe(client_reader, backend_writer),
            pipe(backend_reader, client_writer),
        )
    except Exception as exc:
        logger.debug("Client %s: %s", peer, exc)
    finally:
        try:
            client_writer.close()
        except Exception:
            pass

async def main():
    server = await asyncio.start_server(handle_client, "0.0.0.0", LISTEN_PORT)
    logger.warning("WS proxy listening on :%d → %s:%d", LISTEN_PORT, BACKEND_HOST, BACKEND_PORT)
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    asyncio.run(main())
PYEOF

  chmod +x "${SSH_WS_PROXY_PATH}"

  # Systemd unit
  install_service_unit "${service_name}" "[Unit]
Description=SSH WebSocket Proxy (${service_name})
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${SSH_WS_PROXY_PATH} ${proxy_port} ${backend_host} ${backend_port}
Restart=always
RestartSec=5
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target"

  svc_enable "${service_name}"
  success "SSH WebSocket proxy installed (port ${proxy_port} → ${backend_host}:${backend_port})."
}

# -----------------------------------------------------------------------------
# Full SSH stack setup
# -----------------------------------------------------------------------------

setup_ssh_stack() {
  local ssh_ws_port="${1:-2095}"
  step "Setting up full SSH stack..."
  harden_openssh
  set_ssh_banner
  install_dropbear
  install_stunnel
  write_ws_proxy "${ssh_ws_port}" "127.0.0.1" "22" "ws-openssh"
  write_ws_proxy "$(( ssh_ws_port + 1 ))" "127.0.0.1" "${DROPBEAR_DEFAULT_PORT}" "ws-dropbear"
  success "SSH stack configured."
}
