#!/usr/bin/env bash
# =============================================================================
# xray.sh — Xray-core installation and initial configuration
# =============================================================================

[[ -n "${_INSTALLER_XRAY_SH:-}" ]] && return 0
readonly _INSTALLER_XRAY_SH=1

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"
source "${LIB_DIR_LOCAL}/dependency_manager.sh"

readonly XRAY_INSTALL_SCRIPT="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly XRAY_SERVICE_USER="www-data"
readonly XRAY_CONF_DIR="/etc/xray"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly XRAY_RUN_DIR="/run/xray"
readonly TROJAN_GO_DIR="/etc/trojan-go"

# -----------------------------------------------------------------------------
# Xray Core
# -----------------------------------------------------------------------------

install_xray_core() {
  step "Installing Xray-core (latest stable)..."
  local tmpscript
  tmpscript=$(mktemp /tmp/xray_install.XXXXXXXX.sh)
  register_cleanup "rm -f ${tmpscript}"

  # Download installer with integrity verification is handled by the official script
  safe_download "${XRAY_INSTALL_SCRIPT}" "${tmpscript}"
  bash "${tmpscript}" install -u "${XRAY_SERVICE_USER}" \
    2>&1 | while IFS= read -r line; do log_debug "xray-install: ${line}"; done

  has_command xray || fatal "Xray installation failed."
  local ver
  ver=$(xray version 2>/dev/null | head -n1)
  success "Xray installed: ${ver}"
}

uninstall_xray_core() {
  step "Uninstalling Xray-core..."
  local tmpscript
  tmpscript=$(mktemp /tmp/xray_remove.XXXXXXXX.sh)
  register_cleanup "rm -f ${tmpscript}"
  safe_download "${XRAY_INSTALL_SCRIPT}" "${tmpscript}"
  bash "${tmpscript}" remove 2>/dev/null || true
  success "Xray removed."
}

# -----------------------------------------------------------------------------
# Directories and permissions
# -----------------------------------------------------------------------------

setup_xray_dirs() {
  step "Creating Xray directories..."
  for dir in "${XRAY_CONF_DIR}" "${XRAY_LOG_DIR}" "${XRAY_RUN_DIR}"; do
    ensure_dir "${dir}" 755 "${XRAY_SERVICE_USER}:${XRAY_SERVICE_USER}"
  done
  success "Xray directories ready."
}

# -----------------------------------------------------------------------------
# Config generation from template
# -----------------------------------------------------------------------------

generate_xray_config() {
  local domain="$1"
  local template_file
  template_file="$(dirname "${BASH_SOURCE[0]}")/../config/xray_template.json"

  [[ -f "${template_file}" ]] || fatal "Xray config template not found: ${template_file}"

  step "Generating Xray config for domain: ${domain}..."

  # Load port configuration
  source "$(dirname "${BASH_SOURCE[0]}")/../config/defaults.conf"
  source "${CONFIG_DIR}/autoscript.conf" 2>/dev/null || true

  # Substitute template placeholders
  local config
  config=$(< "${template_file}")
  config="${config//\{\{PORT_XRAY_API\}\}/${PORT_XRAY_API}}"
  config="${config//\{\{PORT_XRAY_VMESS_WS\}\}/${PORT_XRAY_VMESS_WS}}"
  config="${config//\{\{PORT_XRAY_VMESS_GRPC\}\}/${PORT_XRAY_VMESS_GRPC}}"
  config="${config//\{\{PORT_XRAY_VLESS_WS\}\}/${PORT_XRAY_VLESS_WS}}"
  config="${config//\{\{PORT_XRAY_VLESS_GRPC\}\}/${PORT_XRAY_VLESS_GRPC}}"
  config="${config//\{\{PORT_XRAY_TROJAN_WS\}\}/${PORT_XRAY_TROJAN_WS}}"
  config="${config//\{\{PORT_XRAY_TROJAN_GRPC\}\}/${PORT_XRAY_TROJAN_GRPC}}"
  config="${config//\{\{XRAY_WS_PATH_VMESS\}\}/${XRAY_WS_PATH_VMESS}}"
  config="${config//\{\{XRAY_WS_PATH_VLESS\}\}/${XRAY_WS_PATH_VLESS}}"
  config="${config//\{\{XRAY_WS_PATH_TROJAN\}\}/${XRAY_WS_PATH_TROJAN}}"
  config="${config//\{\{XRAY_GRPC_SERVICE_VMESS\}\}/${XRAY_GRPC_SERVICE_VMESS}}"
  config="${config//\{\{XRAY_GRPC_SERVICE_VLESS\}\}/${XRAY_GRPC_SERVICE_VLESS}}"
  config="${config//\{\{XRAY_GRPC_SERVICE_TROJAN\}\}/${XRAY_GRPC_SERVICE_TROJAN}}"
  config="${config//\{\{DOMAIN\}\}/${domain}}"

  # Validate JSON before writing
  echo "${config}" | python3 -m json.tool > /dev/null \
    || fatal "Generated Xray config is invalid JSON."

  echo "${config}" > "${XRAY_CONF_DIR}/config.json"
  chown "${XRAY_SERVICE_USER}:${XRAY_SERVICE_USER}" "${XRAY_CONF_DIR}/config.json"
  chmod 640 "${XRAY_CONF_DIR}/config.json"
  success "Xray config written to ${XRAY_CONF_DIR}/config.json"
}

# -----------------------------------------------------------------------------
# systemd service — socket activation shim for www-data permission
# -----------------------------------------------------------------------------

install_xray_socket_shim() {
  install_service_unit "runn" "[Unit]
Description=Set Xray socket permissions on boot
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'chown ${XRAY_SERVICE_USER}:${XRAY_SERVICE_USER} ${XRAY_RUN_DIR}'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"
  success "Xray socket shim service installed."
}

# -----------------------------------------------------------------------------
# Trojan-Go
# -----------------------------------------------------------------------------

install_trojan_go() {
  local domain="$1"
  local cert_file="${XRAY_CONF_DIR}/xray.crt"
  local key_file="${XRAY_CONF_DIR}/xray.key"

  step "Installing Trojan-Go..."
  ensure_dir "${TROJAN_GO_DIR}" 755

  # Fetch latest release URL from GitHub API
  local latest_url
  latest_url=$(curl -fsSL "https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); \
      print([a['browser_download_url'] for a in d['assets'] \
        if 'linux-amd64' in a['name'] and a['name'].endswith('.zip')][0])" 2>/dev/null) \
    || fatal "Cannot fetch Trojan-Go release URL."

  local tmpzip
  tmpzip=$(mktemp /tmp/trojan_go.XXXXXXXX.zip)
  register_cleanup "rm -f ${tmpzip}"
  safe_download "${latest_url}" "${tmpzip}"

  local tmpdir
  tmpdir=$(mktemp -d /tmp/trojan_go_XXXXXXXX)
  register_cleanup "rm -rf ${tmpdir}"
  unzip -q "${tmpzip}" -d "${tmpdir}"

  install -m 755 "${tmpdir}/trojan-go" /usr/local/bin/trojan-go
  has_command trojan-go || fatal "Trojan-Go installation failed."

  # Write config
  local source_port="${PORT_TROJAN_GO:-2087}"
  cat > "${TROJAN_GO_DIR}/config.json" <<EOF
{
  "run_type": "server",
  "local_addr": "127.0.0.1",
  "local_port": ${source_port},
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": [],
  "ssl": {
    "cert": "${cert_file}",
    "key": "${key_file}",
    "sni": "${domain}"
  },
  "websocket": {
    "enabled": true,
    "path": "/trojango",
    "host": "${domain}"
  },
  "router": {
    "enabled": true,
    "block": ["geoip:private"]
  }
}
EOF

  # Systemd unit
  install_service_unit "trojan-go" "[Unit]
Description=Trojan-Go — TLS Trojan proxy server
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/trojan-go -config ${TROJAN_GO_DIR}/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target"

  svc_enable trojan-go
  success "Trojan-Go installed (port ${source_port})."
}
