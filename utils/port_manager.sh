#!/usr/bin/env bash
# =============================================================================
# port_manager.sh — Port configuration and conflict detection
# =============================================================================

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/validation.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"

# -----------------------------------------------------------------------------
# Port conflict detection
# -----------------------------------------------------------------------------

port_is_in_use() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep -q ":${port} " \
    || ss -ulnp 2>/dev/null | grep -q ":${port} "
}

get_port_user() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep ":${port} " \
    | grep -oP '"([^"]+)"' | head -n1 | tr -d '"'
}

# Suggest a free port near a given one
suggest_free_port() {
  local start="${1:-8000}"
  local candidate="${start}"
  while port_is_in_use "${candidate}"; do
    ((candidate++))
    [[ ${candidate} -gt 65000 ]] && { error "No free ports found near ${start}"; return 1; }
  done
  echo "${candidate}"
}

# -----------------------------------------------------------------------------
# Per-service port change functions
# Each function: validates new port, updates config, restarts service
# -----------------------------------------------------------------------------

change_stunnel_port() {
  local new_port="$1"
  is_valid_port "${new_port}" || { error "Invalid port: ${new_port}"; return 1; }
  port_is_in_use "${new_port}" && { error "Port ${new_port} is already in use."; return 1; }

  local conf="/etc/stunnel/stunnel.conf"
  [[ -f "${conf}" ]] || { error "Stunnel config not found."; return 1; }

  local old_port
  old_port=$(grep "^accept" "${conf}" | head -n1 | awk '{print $3}')

  sed -i "s/^accept  = ${old_port}/accept  = ${new_port}/" "${conf}"
  set_config PORT_STUNNEL "${new_port}"
  svc_restart stunnel4
  log_audit "change_port" "service=stunnel4 old=${old_port} new=${new_port}"
  success "Stunnel4 port changed: ${old_port} → ${new_port}"
}

change_dropbear_port() {
  local new_port="$1"
  is_valid_port "${new_port}" || { error "Invalid port: ${new_port}"; return 1; }
  port_is_in_use "${new_port}" && { error "Port ${new_port} is already in use."; return 1; }

  local old_port
  old_port=$(get_config PORT_DROPBEAR "444")

  # Update override service file
  local override="/etc/systemd/system/dropbear.service.d/override.conf"
  if [[ -f "${override}" ]]; then
    sed -i "s/-p [0-9]*/-p ${new_port}/" "${override}"
  fi
  set_config PORT_DROPBEAR "${new_port}"
  systemctl daemon-reload
  svc_restart dropbear
  log_audit "change_port" "service=dropbear old=${old_port} new=${new_port}"
  success "Dropbear port changed: ${old_port} → ${new_port}"
}

change_openvpn_tcp_port() {
  local new_port="$1"
  is_valid_port "${new_port}" || { error "Invalid port: ${new_port}"; return 1; }
  port_is_in_use "${new_port}" && { error "Port ${new_port} is already in use."; return 1; }

  local conf="/etc/openvpn/server-tcp.conf"
  [[ -f "${conf}" ]] || { error "OpenVPN TCP config not found."; return 1; }

  local old_port
  old_port=$(grep "^port " "${conf}" | awk '{print $2}')
  sed -i "s/^port ${old_port}/port ${new_port}/" "${conf}"
  set_config PORT_OPENVPN_TCP "${new_port}"
  svc_restart openvpn@server-tcp
  log_audit "change_port" "service=openvpn-tcp old=${old_port} new=${new_port}"
  success "OpenVPN TCP port changed: ${old_port} → ${new_port}"
}

change_openvpn_udp_port() {
  local new_port="$1"
  is_valid_port "${new_port}" || { error "Invalid port: ${new_port}"; return 1; }
  port_is_in_use "${new_port}" && { error "Port ${new_port} is already in use."; return 1; }

  local conf="/etc/openvpn/server-udp.conf"
  [[ -f "${conf}" ]] || { error "OpenVPN UDP config not found."; return 1; }

  local old_port
  old_port=$(grep "^port " "${conf}" | awk '{print $2}')
  sed -i "s/^port ${old_port}/port ${new_port}/" "${conf}"
  set_config PORT_OPENVPN_UDP "${new_port}"
  svc_restart openvpn@server-udp
  log_audit "change_port" "service=openvpn-udp old=${old_port} new=${new_port}"
  success "OpenVPN UDP port changed: ${old_port} → ${new_port}"
}

change_ws_proxy_port() {
  local service="${1:-ws-openssh}"
  local new_port="$2"
  is_valid_port "${new_port}" || { error "Invalid port: ${new_port}"; return 1; }
  port_is_in_use "${new_port}" && { error "Port ${new_port} is already in use."; return 1; }

  local unit_file="/etc/systemd/system/${service}.service"
  [[ -f "${unit_file}" ]] || { error "Service unit not found: ${service}"; return 1; }

  local old_port
  old_port=$(grep "ExecStart=.*ws_proxy" "${unit_file}" | grep -oP '\d+' | head -n1)

  sed -i "s/${old_port} /${new_port} /" "${unit_file}"
  systemctl daemon-reload
  svc_restart "${service}"
  log_audit "change_port" "service=${service} old=${old_port} new=${new_port}"
  success "${service} port changed: ${old_port} → ${new_port}"
}

# -----------------------------------------------------------------------------
# Interactive port management menu
# -----------------------------------------------------------------------------

port_menu() {
  while true; do
    clear
    echo ""
    echo -e "${BOLD}  Port Management${RESET}"
    separator "─" 40
    echo "  1) Change Stunnel4 port   [$(get_config PORT_STUNNEL 445)]"
    echo "  2) Change Dropbear port   [$(get_config PORT_DROPBEAR 444)]"
    echo "  3) Change OpenVPN TCP     [$(get_config PORT_OPENVPN_TCP 1194)]"
    echo "  4) Change OpenVPN UDP     [$(get_config PORT_OPENVPN_UDP 2200)]"
    echo "  5) Change SSH WS port     [$(get_config PORT_SSHWS 2095)]"
    echo "  6) Show all open ports"
    echo "  0) Back"
    separator "─" 40
    read -rp "$(echo -e "${CYAN}  Choice: ${RESET}")" opt
    case "${opt}" in
      1) local p; prompt_port "New Stunnel4 port" p; change_stunnel_port "${p}" ;;
      2) local p; prompt_port "New Dropbear port" p; change_dropbear_port "${p}" ;;
      3) local p; prompt_port "New OpenVPN TCP port" p; change_openvpn_tcp_port "${p}" ;;
      4) local p; prompt_port "New OpenVPN UDP port" p; change_openvpn_udp_port "${p}" ;;
      5) local p; prompt_port "New SSH WS port" p; change_ws_proxy_port "ws-openssh" "${p}"; set_config PORT_SSHWS "${p}" ;;
      6) echo ""; show_open_ports 2>/dev/null || ss -tlnp ;;
      0) break ;;
      *) warn "Invalid option." ;;
    esac
    [[ "${opt}" != "6" && "${opt}" != "0" ]] && read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" || true
  done
}
