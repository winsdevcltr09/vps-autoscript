#!/usr/bin/env bash
# =============================================================================
# menu/main.sh — Main interactive dashboard
# Entry: type 'menu' or 'autoscript' after installation
# =============================================================================

BASE_LIB="/usr/local/lib/vps-autoscript"

# Source all library files
for lib in common logger validation service_manager; do
  source "${BASE_LIB}/library/${lib}.sh"
done
source "${BASE_LIB}/config/defaults.conf"
[[ -f "${CONFIG_DIR}/autoscript.conf" ]] && source "${CONFIG_DIR}/autoscript.conf"

require_root

# Preload update check in background (non-blocking)
UPDATE_MSG=""
_check_update_bg() {
  local local_ver remote_ver
  local_ver=$(cat "${VERSION_FILE}" 2>/dev/null || echo "3.0.0")
  remote_ver=$(curl -fsSL --max-time 5 "${UPDATE_SOURCE}/version" 2>/dev/null || echo "${local_ver}")
  if [[ "${local_ver}" != "${remote_ver}" ]]; then
    echo "UPDATE AVAILABLE: v${remote_ver}"
  fi
}
_UPDATE_RESULT_FILE=$(mktemp /tmp/.menu_update_XXXXXX)
_check_update_bg > "${_UPDATE_RESULT_FILE}" 2>/dev/null &
UPDATE_CHECK_PID=$!
register_cleanup "kill ${UPDATE_CHECK_PID} 2>/dev/null; rm -f ${_UPDATE_RESULT_FILE}"

# Gather system info once per menu open
_load_info() {
  SERVER_IP=$(get_public_ip)
  DOMAIN=$(get_domain)
  OS_INFO=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}" || uname -s)
  CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.1f", $2+$4}')
  RAM_USED=$(free -m | awk '/^Mem:/{print $3}')
  RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
  DISK_PCT=$(df / --output=pcent | tail -n1 | tr -d ' %')
  SCRIPT_VER=$(cat "${VERSION_FILE}" 2>/dev/null || echo "3.0.0")

  # Service status symbols
  _svc_sym() { svc_is_active "$1" && echo "${GREEN}●${RESET}" || echo "${RED}✗${RESET}"; }
  SYM_SSH=$(_svc_sym ssh)
  SYM_NGINX=$(_svc_sym nginx)
  SYM_XRAY=$(_svc_sym xray)
  SYM_TROJAN=$(_svc_sym trojan-go)
  SYM_OVPN=$(_svc_sym openvpn@server-tcp)
  SYM_DBR=$(_svc_sym dropbear)
  SYM_STUN=$(_svc_sym stunnel4)

  # User counts
  SSH_COUNT=$(awk -F',' 'NR>1&&!/^#/{c++}END{print c+0}' "${SSH_USERS_DB}" 2>/dev/null || echo 0)
  VMESS_COUNT=$(grep -c "^vmess," "${XRAY_USERS_DB}" 2>/dev/null || echo 0)
  VLESS_COUNT=$(grep -c "^vless," "${XRAY_USERS_DB}" 2>/dev/null || echo 0)
  TROJAN_COUNT=$(grep -c "^trojan," "${XRAY_USERS_DB}" 2>/dev/null || echo 0)

  # Update check result
  wait "${UPDATE_CHECK_PID}" 2>/dev/null || true
  UPDATE_MSG=$(cat "${_UPDATE_RESULT_FILE}" 2>/dev/null || echo "")
}

# -----------------------------------------------------------------------------
# Dashboard header
# -----------------------------------------------------------------------------

_draw_header() {
  clear
  echo ""
  echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════════════╗${RESET}"
  printf   "${BOLD}${CYAN}  ║  VPS AUTOSCRIPT v%-40s║${RESET}\n" "${SCRIPT_VER}  "
  echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════════════╝${RESET}"
  [[ -n "${UPDATE_MSG}" ]] && \
    echo -e "  ${YELLOW}⬆  ${UPDATE_MSG} — run option [u] to update${RESET}"
  echo ""
  printf "  ${BOLD}%-18s${RESET}%s\n" "OS"     "${OS_INFO}"
  printf "  ${BOLD}%-18s${RESET}%s\n" "IP / Domain" "${SERVER_IP} / ${DOMAIN}"
  printf "  ${BOLD}%-18s${RESET}CPU: ${cpu_color}${CPU_USAGE}%%${RESET}  RAM: ${ram_color}${RAM_USED}/${RAM_TOTAL}MB${RESET}  Disk: ${disk_color}${DISK_PCT}%%${RESET}\n" "Resources"
  echo ""
  echo -e "  ${BOLD}Services:${RESET}  SSH$(echo -e ${SYM_SSH})  Nginx$(echo -e ${SYM_NGINX})  Xray$(echo -e ${SYM_XRAY})  Trojan-Go$(echo -e ${SYM_TROJAN})  OpenVPN$(echo -e ${SYM_OVPN})  Dropbear$(echo -e ${SYM_DBR})  Stunnel4$(echo -e ${SYM_STUN})"
  echo ""
  separator "─" 64
  printf "  ${BOLD}Users:${RESET}  SSH:%-4s  VMess:%-4s  VLESS:%-4s  Trojan:%-4s\n" \
    "${SSH_COUNT}" "${VMESS_COUNT}" "${VLESS_COUNT}" "${TROJAN_COUNT}"
  separator "─" 64
}

# Color thresholds
_set_colors() {
  [[ ${CPU_USAGE%.*} -ge 80 ]] && cpu_color="${RED}" || \
  [[ ${CPU_USAGE%.*} -ge 60 ]] && cpu_color="${YELLOW}" || cpu_color="${GREEN}"
  [[ ${RAM_USED} -ge $((RAM_TOTAL * 80 / 100)) ]] && ram_color="${RED}" || \
  [[ ${RAM_USED} -ge $((RAM_TOTAL * 60 / 100)) ]] && ram_color="${YELLOW}" || ram_color="${GREEN}"
  [[ ${DISK_PCT} -ge 80 ]] && disk_color="${RED}" || \
  [[ ${DISK_PCT} -ge 60 ]] && disk_color="${YELLOW}" || disk_color="${GREEN}"
}

# -----------------------------------------------------------------------------
# Main menu options
# -----------------------------------------------------------------------------

_draw_menu() {
  echo ""
  echo -e "  ${BOLD}Account Management${RESET}"
  echo -e "   ${CYAN}[1]${RESET} Manage SSH / OpenVPN Accounts"
  echo -e "   ${CYAN}[2]${RESET} Manage VMess Accounts"
  echo -e "   ${CYAN}[3]${RESET} Manage VLESS Accounts"
  echo -e "   ${CYAN}[4]${RESET} Manage Trojan Accounts"
  echo ""
  echo -e "  ${BOLD}Tools${RESET}"
  echo -e "   ${CYAN}[5]${RESET} Server Settings"
  echo -e "   ${CYAN}[6]${RESET} Backup & Restore"
  echo -e "   ${CYAN}[7]${RESET} Service Status & Monitoring"
  echo -e "   ${CYAN}[8]${RESET} Port Management"
  echo -e "   ${CYAN}[9]${RESET} SSL Certificate Management"
  echo ""
  echo -e "  ${BOLD}System${RESET}"
  echo -e "   ${CYAN}[r]${RESET} Restart All Services"
  echo -e "   ${CYAN}[c]${RESET} Clear Cache"
  echo -e "   ${CYAN}[u]${RESET} Check & Apply Updates"
  echo -e "   ${CYAN}[l]${RESET} View System Logs"
  echo -e "   ${CYAN}[q]${RESET} Quit"
  separator "─" 64
}

# -----------------------------------------------------------------------------
# Sub-menus
# -----------------------------------------------------------------------------

_menu_ssh() {
  source "${BASE_LIB}/service/ssh_user.sh"
  while true; do
    clear
    echo ""
    echo -e "${BOLD}  SSH / OpenVPN Management${RESET}"
    separator "─" 40
    echo "  [1] Create SSH Account"
    echo "  [2] Delete SSH Account"
    echo "  [3] Renew SSH Account"
    echo "  [4] List All SSH Accounts"
    echo "  [5] Lock Account"
    echo "  [6] Unlock Account"
    echo "  [7] Configure Multi-Login Limit"
    echo "  [8] Check Active Sessions"
    echo "  [0] Back"
    separator "─" 40
    read -rp "$(echo -e "${CYAN}  Choice: ${RESET}")" opt
    case "${opt}" in
      1) ssh_add_user_interactive ;;
      2) read -rp "$(echo -e "${CYAN}Username to delete: ${RESET}")" u; ssh_del_user "${u}" ;;
      3) read -rp "$(echo -e "${CYAN}Username: ${RESET}")" u
         read -rp "$(echo -e "${CYAN}New expiry (YYYY-MM-DD): ${RESET}")" e
         ssh_renew_user "${u}" "${e}" ;;
      4) ssh_list_users ;;
      5) read -rp "$(echo -e "${CYAN}Username to lock: ${RESET}")" u; ssh_lock_user "${u}" ;;
      6) read -rp "$(echo -e "${CYAN}Username to unlock: ${RESET}")" u; ssh_unlock_user "${u}" ;;
      7) local ml interval
         prompt_max_login "Max concurrent logins" ml
         prompt_port "Interval in minutes [1-5]" interval
         ssh_setup_autokill "${ml}" "${interval}" ;;
      8) who ;;
      0) break ;;
    esac
    [[ "${opt}" != "0" ]] && read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" || true
  done
}

_menu_xray_protocol() {
  local protocol="$1"
  local label="$2"
  source "${BASE_LIB}/service/xray_user.sh"
  while true; do
    clear
    echo ""
    echo -e "${BOLD}  ${label} Management${RESET}"
    separator "─" 40
    echo "  [1] Create Account"
    echo "  [2] Delete Account"
    echo "  [3] Renew Account"
    echo "  [4] List All Accounts"
    echo "  [5] Check Traffic"
    echo "  [0] Back"
    separator "─" 40
    read -rp "$(echo -e "${CYAN}  Choice: ${RESET}")" opt
    case "${opt}" in
      1) local u e days
         prompt_username "Username" u
         prompt_days "Valid for days" days
         e=$(date -d "+${days} days" '+%Y-%m-%d')
         xray_add_user "${protocol}" "${u}" "${e}" ;;
      2) read -rp "$(echo -e "${CYAN}Username: ${RESET}")" u
         xray_del_user "${protocol}" "${u}" ;;
      3) read -rp "$(echo -e "${CYAN}Username: ${RESET}")" u
         local e; prompt_expiry "New expiry (YYYY-MM-DD)" e
         xray_renew_user "${protocol}" "${u}" "${e}" ;;
      4) xray_list_users "${protocol}" ;;
      5) read -rp "$(echo -e "${CYAN}Username (blank for all): ${RESET}")" u
         xray_check_traffic "${u}" ;;
      0) break ;;
    esac
    [[ "${opt}" != "0" ]] && read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" || true
  done
}

_menu_settings() {
  source "${BASE_LIB}/installer/ssl.sh"
  while true; do
    clear
    echo ""
    echo -e "${BOLD}  Server Settings${RESET}"
    separator "─" 40
    echo "  [1] Configure Auto-Reboot"
    echo "  [2] Renew SSL Certificate"
    echo "  [3] Show SSL Certificate Info"
    echo "  [4] Set Domain"
    echo "  [5] Configure Telegram Notifications"
    echo "  [6] Show Dependency Versions"
    echo "  [0] Back"
    separator "─" 40
    read -rp "$(echo -e "${CYAN}  Choice: ${RESET}")" opt
    case "${opt}" in
      1) local h
         read -rp "$(echo -e "${CYAN}Auto-reboot hour (0-23, blank to disable): ${RESET}")" h
         if [[ -z "${h}" ]]; then
           rm -f /etc/cron.d/auto-reboot && success "Auto-reboot disabled."
         elif is_int_in_range "${h}" 0 23; then
           echo "0 ${h} * * * root /sbin/reboot" > /etc/cron.d/auto-reboot
           success "Auto-reboot set for ${h}:00 daily."
         else
           warn "Invalid hour."
         fi ;;
      2) renew_cert "$(get_domain)" ;;
      3) show_cert_info ;;
      4) local d; prompt_domain "New domain" d
         echo "${d}" > "${DOMAIN_FILE}"
         success "Domain set to: ${d}" ;;
      5) local bot_token chat_id
         read -rsp "$(echo -e "${CYAN}Telegram bot token: ${RESET}")" bot_token; echo
         read -rp  "$(echo -e "${CYAN}Telegram chat ID: ${RESET}")" chat_id
         set_config NOTIFY_TELEGRAM_BOT_TOKEN "${bot_token}"
         set_config NOTIFY_TELEGRAM_CHAT_ID "${chat_id}"
         set_config NOTIFY_TELEGRAM_ENABLED true
         success "Telegram notifications configured." ;;
      6) source "${BASE_LIB}/library/dependency_manager.sh"; show_dependency_versions ;;
      0) break ;;
    esac
    [[ "${opt}" != "0" ]] && read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" || true
  done
}

_menu_backup() {
  while true; do
    clear
    echo ""
    echo -e "${BOLD}  Backup & Restore${RESET}"
    separator "─" 40
    echo "  [1] Run Manual Backup Now"
    echo "  [2] Enable Auto-Backup (daily)"
    echo "  [3] Disable Auto-Backup"
    echo "  [4] Restore from Backup"
    echo "  [5] Configure Backup Backend"
    echo "  [0] Back"
    separator "─" 40
    read -rp "$(echo -e "${CYAN}  Choice: ${RESET}")" opt
    case "${opt}" in
      1) source "${BASE_LIB}/backup/backup.sh" ;;
      2) local h m
         read -rp "$(echo -e "${CYAN}Hour (0-23) [default 0]: ${RESET}")" h; h=${h:-0}
         read -rp "$(echo -e "${CYAN}Minute (0-59) [default 5]: ${RESET}")" m; m=${m:-5}
         source "${BASE_LIB}/backup/backup.sh"; setup_autobackup_cron "${h}" "${m}" ;;
      3) source "${BASE_LIB}/backup/backup.sh"; remove_autobackup_cron ;;
      4) source "${BASE_LIB}/backup/restore.sh" ;;
      5) echo -e "\nBackend options: ${BOLD}rclone${RESET} | sftp | local"
         read -rp "$(echo -e "${CYAN}Backend: ${RESET}")" backend
         set_config BACKUP_BACKEND "${backend}" ;;
      0) break ;;
    esac
    [[ "${opt}" != "0" ]] && read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" || true
  done
}

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

_load_info
_set_colors

while true; do
  _draw_header
  _draw_menu
  read -rp "$(echo -e "${CYAN}  Select option: ${RESET}")" choice

  case "${choice}" in
    1) _menu_ssh ;;
    2) _menu_xray_protocol "vmess"  "VMess" ;;
    3) _menu_xray_protocol "vless"  "VLESS" ;;
    4) _menu_xray_protocol "trojan" "Trojan" ;;
    5) _menu_settings ;;
    6) _menu_backup ;;
    7) source "${BASE_LIB}/monitoring/status.sh"; read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" ;;
    8) source "${BASE_LIB}/utils/port_manager.sh"; port_menu ;;
    9) source "${BASE_LIB}/installer/ssl.sh"; show_cert_info; read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" ;;
    r|R) restart_all; read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" ;;
    c|C) sync; echo 3 > /proc/sys/vm/drop_caches; success "Cache cleared."; read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" ;;
    u|U) source "${BASE_LIB}/update/updater.sh"; run_update; read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" ;;
    l|L) show_log 50; read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" ;;
    q|Q) echo ""; exit 0 ;;
    *) warn "Invalid option: ${choice}" ;;
  esac

  # Refresh info for next iteration
  _load_info
  _set_colors
done
