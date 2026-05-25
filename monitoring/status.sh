#!/usr/bin/env bash
# =============================================================================
# status.sh — Real-time service and resource monitoring
# =============================================================================

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"

# -----------------------------------------------------------------------------
# Service status table
# -----------------------------------------------------------------------------

show_service_status() {
  local services=(
    "ssh:OpenSSH"
    "dropbear:Dropbear"
    "stunnel4:Stunnel4"
    "nginx:Nginx"
    "xray:Xray-core"
    "trojan-go:Trojan-Go"
    "openvpn@server-tcp:OpenVPN TCP"
    "openvpn@server-udp:OpenVPN UDP"
    "fail2ban:Fail2Ban"
    "ws-openssh:WS-OpenSSH"
    "ws-dropbear:WS-Dropbear"
  )

  separator "─" 50
  printf "  %-22s %s\n" "SERVICE" "STATUS"
  separator "─" 50
  for entry in "${services[@]}"; do
    local svc="${entry%%:*}"
    local label="${entry##*:}"
    if ! systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
      continue
    fi
    local status
    status=$(systemctl is-active "${svc}" 2>/dev/null || echo "inactive")
    if [[ "${status}" == "active" ]]; then
      printf "  %-22s ${GREEN}● running${RESET}\n" "${label}"
    else
      printf "  %-22s ${RED}✗ ${status}${RESET}\n" "${label}"
    fi
  done
  separator "─" 50
}

# -----------------------------------------------------------------------------
# Resource usage
# -----------------------------------------------------------------------------

show_resource_usage() {
  # CPU
  local cpu_usage
  cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' | cut -d. -f1)

  # RAM
  local ram_total ram_used ram_free
  ram_total=$(free -m | awk '/^Mem:/{print $2}')
  ram_used=$(free -m | awk '/^Mem:/{print $3}')
  ram_free=$(free -m | awk '/^Mem:/{print $4}')

  # Disk
  local disk_used disk_total disk_pct
  disk_used=$(df / --output=used -BG | tail -n1 | tr -d 'G ')
  disk_total=$(df / --output=size -BG | tail -n1 | tr -d 'G ')
  disk_pct=$(df / --output=pcent | tail -n1 | tr -d ' %')

  # Load
  local load
  load=$(uptime | awk -F'load average:' '{print $2}' | xargs)

  # Uptime
  local uptime_str
  uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | cut -d',' -f1)

  separator "─" 50
  printf "  %-20s %s\n" "CPU Usage"    "${cpu_usage}%"
  printf "  %-20s %s\n" "RAM"          "${ram_used}/${ram_total} MB (free: ${ram_free}MB)"
  printf "  %-20s %s\n" "Disk (/)"     "${disk_used}/${disk_total} GB (${disk_pct}%)"
  printf "  %-20s %s\n" "Load Average" "${load}"
  printf "  %-20s %s\n" "Uptime"       "${uptime_str}"
  separator "─" 50
}

# -----------------------------------------------------------------------------
# Network stats
# -----------------------------------------------------------------------------

show_network_info() {
  local public_ip
  public_ip=$(get_public_ip)
  local domain
  domain=$(get_domain)
  local iface
  iface=$(ip route | grep default | awk '{print $5}' | head -n1)
  local rx_mb tx_mb
  rx_mb=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null | awk '{printf "%.1f", $1/1048576}')
  tx_mb=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null | awk '{printf "%.1f", $1/1048576}')

  separator "─" 50
  printf "  %-20s %s\n" "Public IP"    "${public_ip}"
  printf "  %-20s %s\n" "Domain"       "${domain}"
  printf "  %-20s %s\n" "Interface"    "${iface}"
  printf "  %-20s %s\n" "RX (session)" "${rx_mb} MB"
  printf "  %-20s %s\n" "TX (session)" "${tx_mb} MB"
  separator "─" 50
}

# -----------------------------------------------------------------------------
# Open ports
# -----------------------------------------------------------------------------

show_open_ports() {
  separator "─" 50
  printf "  %-10s %-10s %s\n" "PROTO" "PORT" "PROCESS"
  separator "─" 50
  ss -tlnp 2>/dev/null | awk 'NR>1 {
    split($4, a, ":")
    port = a[length(a)]
    proc = $NF
    gsub(/users:\(\("|"\)\)/, "", proc)
    split(proc, b, ",")
    printf "  %-10s %-10s %s\n", "TCP", port, b[1]
  }' | sort -k2 -n | head -20
  separator "─" 50
}

# -----------------------------------------------------------------------------
# User count per protocol
# -----------------------------------------------------------------------------

show_user_counts() {
  local ssh_count vmess_count vless_count trojan_count

  ssh_count=$(awk -F',' 'NR>1 && !/^#/{count++} END{print count+0}' \
    "${SSH_USERS_DB:-/etc/vps-autoscript/config/ssh_users.db}" 2>/dev/null || echo 0)

  local xray_db="${XRAY_USERS_DB:-/etc/vps-autoscript/config/xray_users.db}"
  vmess_count=$(grep -c "^vmess," "${xray_db}" 2>/dev/null || echo 0)
  vless_count=$(grep -c "^vless," "${xray_db}" 2>/dev/null || echo 0)
  trojan_count=$(grep -c "^trojan," "${xray_db}" 2>/dev/null || echo 0)

  separator "─" 50
  printf "  %-20s %s\n" "SSH Users"     "${ssh_count}"
  printf "  %-20s %s\n" "VMess Users"   "${vmess_count}"
  printf "  %-20s %s\n" "VLESS Users"   "${vless_count}"
  printf "  %-20s %s\n" "Trojan Users"  "${trojan_count}"
  separator "─" 50
}

# -----------------------------------------------------------------------------
# SSL certificate status
# -----------------------------------------------------------------------------

show_ssl_status() {
  local cert="${SSL_CERT:-/etc/xray/xray.crt}"
  if [[ ! -f "${cert}" ]]; then
    printf "  SSL Certificate: ${RED}NOT FOUND${RESET}\n"
    return
  fi
  local expiry_date days_left
  expiry_date=$(openssl x509 -noout -enddate -in "${cert}" 2>/dev/null \
    | sed 's/notAfter=//')
  days_left=$(( ( $(date -d "${expiry_date}" +%s) - $(date +%s) ) / 86400 ))

  separator "─" 50
  if [[ ${days_left} -lt 7 ]]; then
    printf "  SSL Expiry: ${RED}${expiry_date} (${days_left} days — CRITICAL)${RESET}\n"
  elif [[ ${days_left} -lt 30 ]]; then
    printf "  SSL Expiry: ${YELLOW}${expiry_date} (${days_left} days — WARNING)${RESET}\n"
  else
    printf "  SSL Expiry: ${GREEN}${expiry_date} (${days_left} days)${RESET}\n"
  fi
  separator "─" 50
}

# -----------------------------------------------------------------------------
# Full status dashboard
# -----------------------------------------------------------------------------

show_full_status() {
  clear
  local os_info
  os_info=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}")
  local script_ver
  script_ver=$(cat "${VERSION_FILE}" 2>/dev/null || echo "3.0.0")

  echo ""
  echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}  ║        VPS Autoscript v${script_ver} — Status           ║${RESET}"
  echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}  System Information${RESET}"
  printf "  %-20s %s\n" "OS" "${os_info}"
  printf "  %-20s %s\n" "Kernel" "$(uname -r)"
  printf "  %-20s %s\n" "Date/Time" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo ""
  echo -e "${BOLD}  Services${RESET}"
  show_service_status
  echo ""
  echo -e "${BOLD}  Resources${RESET}"
  show_resource_usage
  echo ""
  echo -e "${BOLD}  Network${RESET}"
  show_network_info
  echo ""
  echo -e "${BOLD}  Users${RESET}"
  show_user_counts
  echo ""
  echo -e "${BOLD}  SSL Certificate${RESET}"
  show_ssl_status
}

# CLI
show_full_status
