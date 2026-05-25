#!/usr/bin/env bash
# =============================================================================
# installer/main.sh — Main installation orchestrator
# Coordinates all installer modules in correct order with rollback support
# =============================================================================

set -euo pipefail

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/validation.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"
source "${LIB_DIR_LOCAL}/dependency_manager.sh"

INSTALLER_DIR="$(dirname "${BASH_SOURCE[0]}")"
INSTALLER_START_TIME=${SECONDS}

# Collect rollback steps (executed in reverse on failure)
declare -a ROLLBACK_STEPS=()

register_rollback() {
  ROLLBACK_STEPS=("$1" "${ROLLBACK_STEPS[@]}")
}

run_rollback() {
  if [[ ${#ROLLBACK_STEPS[@]} -gt 0 ]]; then
    warn "Installation failed. Running rollback..."
    for step in "${ROLLBACK_STEPS[@]}"; do
      log_warn "Rollback: ${step}"
      eval "${step}" 2>/dev/null || true
    done
    error "Installation rolled back. Check logs at ${LOG_DIR}/autoscript.log"
  fi
}

trap 'run_rollback' ERR

# -----------------------------------------------------------------------------
# Collect installation parameters interactively
# -----------------------------------------------------------------------------

collect_params() {
  clear
  echo ""
  echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}  ║     VPS Autoscript v${AUTOSCRIPT_VERSION} — Installer         ║${RESET}"
  echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════╝${RESET}"
  echo ""

  # Domain
  echo -e "  ${DIM}Enter the domain/subdomain pointing to this server's IP.${RESET}"
  echo -e "  ${DIM}Example: vpn.myserver.com${RESET}"
  echo ""
  prompt_domain "Domain or IP" INSTALL_DOMAIN

  # Admin email (for SSL cert notifications)
  echo ""
  read -rp "$(echo -e "${CYAN}  Admin email (for SSL notifications): ${RESET}")" ADMIN_EMAIL
  [[ -z "${ADMIN_EMAIL}" ]] && ADMIN_EMAIL="admin@${INSTALL_DOMAIN}"

  # SSH WebSocket port
  echo ""
  local default_ws_port=2095
  read -rp "$(echo -e "${CYAN}  SSH WebSocket port [${default_ws_port}]: ${RESET}")" WS_PORT
  WS_PORT="${WS_PORT:-${default_ws_port}}"
  is_valid_port "${WS_PORT}" || WS_PORT="${default_ws_port}"

  # BBR option
  echo ""
  ENABLE_BBR=false
  confirm "Enable BBR TCP congestion control?" && ENABLE_BBR=true

  echo ""
  echo -e "  ${BOLD}Summary:${RESET}"
  echo -e "    Domain:    ${CYAN}${INSTALL_DOMAIN}${RESET}"
  echo -e "    Email:     ${ADMIN_EMAIL}"
  echo -e "    WS Port:   ${WS_PORT}"
  echo -e "    BBR:       ${ENABLE_BBR}"
  echo ""
  confirm "Proceed with installation?" || { info "Installation cancelled."; exit 0; }
}

# -----------------------------------------------------------------------------
# Phase 1: System preparation
# -----------------------------------------------------------------------------

phase_system_prep() {
  step "[Phase 1/7] System Preparation"

  source "${INSTALLER_DIR}/system_check.sh"
  run_preflight

  # Timezone
  local tz="${TIMEZONE:-Asia/Jakarta}"
  timedatectl set-timezone "${tz}" 2>/dev/null || true
  log_info "Timezone set to ${tz}"

  # Apply kernel tuning
  apply_sysctl_tuning
  configure_limits

  # BBR
  [[ "${ENABLE_BBR}" == "true" ]] && enable_bbr || true

  register_rollback "echo 'Rollback: Phase 1 — no destructive changes to undo.'"
  success "Phase 1 complete."
}

# -----------------------------------------------------------------------------
# Phase 2: Install system dependencies
# -----------------------------------------------------------------------------

phase_dependencies() {
  step "[Phase 2/7] Installing Dependencies"
  install_core_deps
  install_vpn_deps
  install_nodejs
  register_rollback "echo 'Rollback: packages remain (apt-get autoremove to clean if desired)'"
  success "Phase 2 complete."
}

# -----------------------------------------------------------------------------
# Phase 3: SSL Certificate
# -----------------------------------------------------------------------------

phase_ssl() {
  step "[Phase 3/7] SSL Certificate"
  source "${INSTALLER_DIR}/ssl.sh"
  install_acme
  set_default_ca

  # Check if domain resolves to this server (warn only, don't block)
  check_domain_points_here "${INSTALL_DOMAIN}" 2>/dev/null || \
    warn "Domain may not resolve to this server. SSL issuance might fail."

  issue_cert "${INSTALL_DOMAIN}"
  setup_autorenew_cron

  register_rollback "rm -f '${SSL_CERT}' '${SSL_KEY}'"
  success "Phase 3 complete."
}

# -----------------------------------------------------------------------------
# Phase 4: Install Xray + Trojan-Go
# -----------------------------------------------------------------------------

phase_xray() {
  step "[Phase 4/7] Xray + Trojan-Go"
  source "${INSTALLER_DIR}/xray.sh"
  setup_xray_dirs
  install_xray_core
  generate_xray_config "${INSTALL_DOMAIN}"
  install_xray_socket_shim
  install_trojan_go "${INSTALL_DOMAIN}"

  register_rollback "source '${INSTALLER_DIR}/xray.sh'; uninstall_xray_core 2>/dev/null; \
    rm -f /usr/local/bin/trojan-go /etc/xray/config.json"
  success "Phase 4 complete."
}

# -----------------------------------------------------------------------------
# Phase 5: Nginx
# -----------------------------------------------------------------------------

phase_nginx() {
  step "[Phase 5/7] Nginx Reverse Proxy"
  source "${INSTALLER_DIR}/nginx.sh"
  setup_nginx "${INSTALL_DOMAIN}"
  register_rollback "systemctl stop nginx 2>/dev/null; rm -f '${XRAY_VHOST_CONF}'"
  success "Phase 5 complete."
}

# -----------------------------------------------------------------------------
# Phase 6: SSH stack (Dropbear, Stunnel4, WebSocket proxy)
# -----------------------------------------------------------------------------

phase_ssh_stack() {
  step "[Phase 6/7] SSH Stack"
  source "${INSTALLER_DIR}/ssh_setup.sh"
  setup_ssh_stack "${WS_PORT}"
  register_rollback "svc_stop dropbear; svc_stop stunnel4; svc_stop ws-openssh; svc_stop ws-dropbear"
  success "Phase 6 complete."
}

# -----------------------------------------------------------------------------
# Phase 7: OpenVPN
# -----------------------------------------------------------------------------

phase_openvpn() {
  step "[Phase 7/7] OpenVPN"
  source "${INSTALLER_DIR}/openvpn.sh"
  install_openvpn
  register_rollback "svc_stop openvpn@server-tcp; svc_stop openvpn@server-udp"
  success "Phase 7 complete."
}

# -----------------------------------------------------------------------------
# Post-install: config directory, symlinks, crons
# -----------------------------------------------------------------------------

phase_finalize() {
  step "[Finalize] Writing config and symlinks..."

  # Config directory
  ensure_dir "${CONFIG_DIR}" 700
  ensure_dir "${LOG_DIR}" 750
  ensure_dir "${LOCK_DIR}" 750

  # Write autoscript.conf
  cat > "${CONFIG_DIR}/autoscript.conf" <<EOF
# VPS Autoscript — runtime configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
INSTALL_DOMAIN=${INSTALL_DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
PORT_SSHWS=${WS_PORT}
ENABLE_BBR=${ENABLE_BBR}
EOF

  # Write domain file
  echo "${INSTALL_DOMAIN}" > "${DOMAIN_FILE}"

  # Write version
  echo "${AUTOSCRIPT_VERSION}" > "${VERSION_FILE}"

  # Install library to system path
  ensure_dir "${LIB_DIR}" 755
  cp -r "$(dirname "${BASH_SOURCE[0]}")/.."/* "${LIB_DIR}/"
  chmod -R 755 "${LIB_DIR}"

  # Symlinks for convenience commands
  ln -sf "${LIB_DIR}/menu/main.sh" "${BIN_DIR}/menu"
  ln -sf "${LIB_DIR}/menu/main.sh" "${BIN_DIR}/autoscript"
  ln -sf "${LIB_DIR}/monitoring/status.sh" "${BIN_DIR}/autoscript-status"
  ln -sf "${LIB_DIR}/monitoring/health_check.sh" "${BIN_DIR}/autoscript-health-check"
  ln -sf "${LIB_DIR}/backup/backup.sh" "${BIN_DIR}/autoscript-backup"
  ln -sf "${LIB_DIR}/update/updater.sh" "${BIN_DIR}/autoscript-update"
  chmod +x "${BIN_DIR}/menu" "${BIN_DIR}/autoscript"

  # Crons: auto-delete expired users, health check
  cat > /etc/cron.d/vps-autoscript-maintenance <<EOF
# VPS Autoscript — maintenance crons
0 0 * * * root ${LIB_DIR}/service/ssh_user.sh --purge-expired >> ${LOG_DIR}/cron.log 2>&1
5 0 * * * root ${LIB_DIR}/service/xray_user.sh --purge-expired >> ${LOG_DIR}/cron.log 2>&1
*/5 * * * * root ${BIN_DIR}/autoscript-health-check >> ${LOG_DIR}/health.log 2>&1
EOF
  chmod 644 /etc/cron.d/vps-autoscript-maintenance

  # fail2ban SSH config
  cat > /etc/fail2ban/jail.d/sshd.conf <<'EOF'
[sshd]
enabled = true
port    = ssh,2095
filter  = sshd
maxretry = 5
bantime  = 3600
EOF
  svc_restart fail2ban 2>/dev/null || true

  success "Post-install finalization complete."
}

# -----------------------------------------------------------------------------
# Installation summary
# -----------------------------------------------------------------------------

print_summary() {
  local elapsed=$(( SECONDS - INSTALLER_START_TIME ))
  echo ""
  echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}  ║         INSTALLATION COMPLETE ✓                  ║${RESET}"
  echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}Domain:     ${RESET}${INSTALL_DOMAIN}"
  echo -e "  ${BOLD}IP:         ${RESET}$(get_public_ip)"
  echo -e "  ${BOLD}SSH Port:   ${RESET}22"
  echo -e "  ${BOLD}SSH WS:     ${RESET}${WS_PORT}"
  echo -e "  ${BOLD}Stunnel:    ${RESET}445 (SSL over Dropbear)"
  echo -e "  ${BOLD}Nginx:      ${RESET}80 / 443 (TLS)"
  echo -e "  ${BOLD}Xray:       ${RESET}VMess/VLESS/Trojan WS+gRPC (via Nginx 443)"
  echo -e "  ${BOLD}Trojan-Go:  ${RESET}via Nginx 443 /trojango"
  echo -e "  ${BOLD}OpenVPN:    ${RESET}TCP 1194 / UDP 2200"
  echo -e "  ${BOLD}Logs:       ${RESET}${LOG_DIR}/"
  echo -e "  ${BOLD}Duration:   ${RESET}${elapsed}s"
  echo ""
  echo -e "  ${BOLD}Run ${CYAN}menu${RESET} or ${CYAN}autoscript${RESET} to open the dashboard."
  echo ""
}

# -----------------------------------------------------------------------------
# Dry-run mode
# -----------------------------------------------------------------------------

if [[ "${1:-}" == "--dry-run" ]]; then
  source "${INSTALLER_DIR}/system_check.sh"
  run_dry_run
  source "${LIB_DIR_LOCAL}/dependency_manager.sh"
  show_dependency_versions
  exit 0
fi

# -----------------------------------------------------------------------------
# Main installation flow
# -----------------------------------------------------------------------------

require_root
collect_params
acquire_lock "installer"

log_info "Installation started for domain: ${INSTALL_DOMAIN}"

phase_system_prep
phase_dependencies
phase_ssl
phase_xray
phase_nginx
phase_ssh_stack
phase_openvpn
phase_finalize

log_audit "install_complete" "domain=${INSTALL_DOMAIN} version=${AUTOSCRIPT_VERSION}"
print_summary

release_lock
