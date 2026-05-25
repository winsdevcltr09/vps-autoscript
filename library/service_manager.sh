#!/usr/bin/env bash
# =============================================================================
# service_manager.sh — Start, stop, restart, and health-check systemd services
# =============================================================================

[[ -n "${_SERVICE_MANAGER_SH:-}" ]] && return 0
readonly _SERVICE_MANAGER_SH=1

[[ -z "${RED:-}" ]] && source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# All managed services in start-order
readonly -a MANAGED_SERVICES=(
  ssh
  dropbear
  stunnel4
  nginx
  xray
  trojan-go
  openvpn
  fail2ban
  ws-dropbear
  ws-stunnel
)

# -----------------------------------------------------------------------------
# Core service operations
# -----------------------------------------------------------------------------

svc_start() {
  local svc="$1"
  systemctl start "${svc}" && success "Started: ${svc}" || warn "Failed to start: ${svc}"
}

svc_stop() {
  local svc="$1"
  systemctl stop "${svc}" 2>/dev/null && success "Stopped: ${svc}" || true
}

svc_restart() {
  local svc="$1"
  systemctl restart "${svc}" && success "Restarted: ${svc}" || warn "Failed to restart: ${svc}"
}

svc_reload() {
  local svc="$1"
  systemctl reload-or-restart "${svc}" && success "Reloaded: ${svc}" || warn "Failed to reload: ${svc}"
}

svc_enable() {
  local svc="$1"
  systemctl enable --now "${svc}" &>/dev/null && success "Enabled: ${svc}" || warn "Failed to enable: ${svc}"
}

svc_disable() {
  local svc="$1"
  systemctl disable --now "${svc}" &>/dev/null
}

svc_status() {
  local svc="$1"
  systemctl is-active "${svc}" 2>/dev/null || echo "inactive"
}

svc_is_active() {
  systemctl is-active --quiet "$1"
}

# -----------------------------------------------------------------------------
# Bulk operations
# -----------------------------------------------------------------------------

restart_all() {
  step "Restarting all managed services..."
  local failed=()
  for svc in "${MANAGED_SERVICES[@]}"; do
    systemctl is-enabled --quiet "${svc}" 2>/dev/null || continue
    if ! systemctl restart "${svc}" 2>/dev/null; then
      failed+=("${svc}")
    fi
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Failed to restart: ${failed[*]}"
  else
    success "All services restarted."
  fi
}

stop_all() {
  step "Stopping all managed services..."
  for svc in "${MANAGED_SERVICES[@]}"; do
    systemctl stop "${svc}" 2>/dev/null || true
  done
}

start_all() {
  step "Starting all managed services..."
  for svc in "${MANAGED_SERVICES[@]}"; do
    systemctl is-enabled --quiet "${svc}" 2>/dev/null || continue
    systemctl start "${svc}" 2>/dev/null || warn "Could not start: ${svc}"
  done
}

# -----------------------------------------------------------------------------
# Health check
# -----------------------------------------------------------------------------

health_check_all() {
  separator
  printf "%-20s %-10s %-20s\n" "SERVICE" "STATUS" "UPTIME"
  separator
  for svc in "${MANAGED_SERVICES[@]}"; do
    if ! systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
      continue
    fi
    local status uptime
    status=$(svc_status "${svc}")
    if [[ "${status}" == "active" ]]; then
      uptime=$(systemctl show "${svc}" -p ActiveEnterTimestamp \
        | sed 's/ActiveEnterTimestamp=//' | xargs -I{} bash -c \
        'echo $(( ($(date +%s) - $(date -d "{}" +%s)) / 60 )) min ago' 2>/dev/null || echo "-")
      printf "%-20s ${GREEN}%-10s${RESET} %-20s\n" "${svc}" "${status}" "${uptime}"
    else
      printf "%-20s ${RED}%-10s${RESET} %-20s\n" "${svc}" "${status}" "-"
    fi
  done
  separator
}

# Check a single service and restart if down
auto_heal() {
  local svc="$1"
  if ! svc_is_active "${svc}"; then
    warn "${svc} is down. Attempting restart..."
    svc_restart "${svc}"
    sleep 3
    if svc_is_active "${svc}"; then
      success "${svc} recovered."
    else
      error "${svc} failed to recover. Check: journalctl -u ${svc} -n 50"
      return 1
    fi
  fi
}

# Auto-heal all critical services
auto_heal_all() {
  local critical_services=(nginx xray ssh)
  for svc in "${critical_services[@]}"; do
    auto_heal "${svc}" || true
  done
}

# -----------------------------------------------------------------------------
# Systemd unit file management
# -----------------------------------------------------------------------------

install_service_unit() {
  local name="$1"
  local unit_content="$2"
  local unit_file="/etc/systemd/system/${name}.service"
  echo "${unit_content}" > "${unit_file}"
  chmod 644 "${unit_file}"
  systemctl daemon-reload
  systemctl enable "${name}"
  success "Installed service unit: ${name}"
}

remove_service_unit() {
  local name="$1"
  svc_disable "${name}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${name}.service"
  systemctl daemon-reload
  success "Removed service unit: ${name}"
}

# Validate a service unit file for syntax errors
validate_unit() {
  local unit_file="$1"
  systemd-analyze verify "${unit_file}" 2>&1
}

# Wait until a service reaches active state (max N seconds)
wait_active() {
  local svc="$1"
  local timeout="${2:-30}"
  local elapsed=0
  while ! svc_is_active "${svc}"; do
    [[ ${elapsed} -ge ${timeout} ]] && error "${svc} did not start within ${timeout}s" && return 1
    sleep 1
    ((elapsed++))
  done
  success "${svc} is active."
}

# Safe restart with config validation (for nginx/xray)
safe_restart_nginx() {
  nginx -t 2>&1 | while read -r line; do log_debug "nginx-t: ${line}"; done
  nginx -t &>/dev/null || { error "Nginx config test failed. Not restarting."; return 1; }
  systemctl restart nginx
}

safe_restart_xray() {
  if [[ -f "${XRAY_CONF:-/etc/xray/config.json}" ]]; then
    python3 -c "import json, sys; json.load(open(sys.argv[1]))" "${XRAY_CONF}" 2>/dev/null \
      || { error "Xray config JSON is invalid. Not restarting."; return 1; }
  fi
  systemctl restart xray
}
