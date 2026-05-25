#!/usr/bin/env bash
# =============================================================================
# health_check.sh — Automated health checks and alerting
# Can be run as a cron job or on-demand
# =============================================================================

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"

readonly HEALTH_LOG="${LOG_DIR}/health.log"
declare -a HEALTH_ISSUES=()

_health_ok()   { log_debug "HEALTH OK: $*"; }
_health_fail() { log_warn  "HEALTH FAIL: $*"; HEALTH_ISSUES+=("$*"); }

# -----------------------------------------------------------------------------
# Individual checks
# -----------------------------------------------------------------------------

check_service_health() {
  local critical_services=(nginx xray ssh)
  for svc in "${critical_services[@]}"; do
    if ! svc_is_active "${svc}"; then
      _health_fail "Service ${svc} is DOWN"
      # Attempt auto-heal
      auto_heal "${svc}" 2>/dev/null && _health_ok "${svc} auto-healed" || true
    else
      _health_ok "Service ${svc} is UP"
    fi
  done
}

check_disk_health() {
  local pct
  pct=$(df / --output=pcent | tail -n1 | tr -d ' %')
  if [[ ${pct} -ge 90 ]]; then
    _health_fail "Disk usage critical: ${pct}%"
  elif [[ ${pct} -ge 75 ]]; then
    _health_fail "Disk usage warning: ${pct}%"
  else
    _health_ok "Disk usage OK: ${pct}%"
  fi
}

check_ram_health() {
  local available_mb
  available_mb=$(free -m | awk '/^Mem:/{print $7}')
  if [[ ${available_mb} -lt 50 ]]; then
    _health_fail "Critical low RAM: ${available_mb}MB available"
    # Attempt cache drop
    sync; echo 1 > /proc/sys/vm/drop_caches
    log_info "Dropped page cache to free RAM."
  else
    _health_ok "RAM OK: ${available_mb}MB available"
  fi
}

check_ssl_health() {
  local cert="${SSL_CERT:-/etc/xray/xray.crt}"
  [[ -f "${cert}" ]] || { _health_fail "SSL certificate not found"; return; }
  local days_left
  days_left=$(( ( $(date -d "$(openssl x509 -noout -enddate -in "${cert}" \
    | sed 's/notAfter=//')" +%s) - $(date +%s) ) / 86400 ))
  if [[ ${days_left} -lt 7 ]]; then
    _health_fail "SSL certificate expires in ${days_left} days — CRITICAL"
  elif [[ ${days_left} -lt 30 ]]; then
    _health_fail "SSL certificate expires in ${days_left} days — WARNING"
  else
    _health_ok "SSL certificate valid for ${days_left} days"
  fi
}

check_load_health() {
  local load1
  load1=$(awk '{print $1}' /proc/loadavg | cut -d. -f1)
  local cpu_count
  cpu_count=$(nproc)
  if [[ ${load1} -gt $((cpu_count * 3)) ]]; then
    _health_fail "High load average: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
  else
    _health_ok "Load OK: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
  fi
}

check_port_health() {
  local critical_ports=(22 80 443)
  for port in "${critical_ports[@]}"; do
    if nc -z 127.0.0.1 "${port}" &>/dev/null; then
      _health_ok "Port ${port} is open"
    else
      _health_fail "Port ${port} is NOT listening"
    fi
  done
}

# -----------------------------------------------------------------------------
# Alert via Telegram if issues found
# -----------------------------------------------------------------------------

_send_alert() {
  local message="$1"
  local bot_token
  bot_token=$(get_config NOTIFY_TELEGRAM_BOT_TOKEN 2>/dev/null || echo "")
  local chat_id
  chat_id=$(get_config NOTIFY_TELEGRAM_CHAT_ID 2>/dev/null || echo "")
  [[ -z "${bot_token}" || -z "${chat_id}" ]] && return 0
  curl -fsSL --max-time 10 \
    "https://api.telegram.org/bot${bot_token}/sendMessage" \
    -d "chat_id=${chat_id}" -d "text=${message}" -d "parse_mode=HTML" \
    &>/dev/null || true
}

# -----------------------------------------------------------------------------
# Full health check run
# -----------------------------------------------------------------------------

run_health_check() {
  HEALTH_ISSUES=()
  log_info "Running health checks..."
  check_service_health
  check_disk_health
  check_ram_health
  check_ssl_health
  check_load_health
  check_port_health

  if [[ ${#HEALTH_ISSUES[@]} -gt 0 ]]; then
    local summary
    summary=$(printf '• %s\n' "${HEALTH_ISSUES[@]}")
    log_warn "Health check found ${#HEALTH_ISSUES[@]} issue(s):\n${summary}"
    _send_alert "⚠️ <b>VPS Health Alert</b> — $(hostname)
$(date '+%Y-%m-%d %H:%M:%S')

${summary}"
    return 1
  else
    log_info "Health check passed. All systems OK."
    return 0
  fi
}

# Setup health check cron (every 5 minutes)
setup_health_check_cron() {
  local cron_file="/etc/cron.d/vps-health-check"
  cat > "${cron_file}" <<EOF
# VPS Autoscript — health check
*/5 * * * * root /usr/local/bin/autoscript-health-check
EOF
  chmod 644 "${cron_file}"
  success "Health check cron configured (every 5 minutes)."
}

# CLI
run_health_check
