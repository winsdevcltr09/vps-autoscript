#!/usr/bin/env bash
# =============================================================================
# ssh_user.sh — SSH / OpenVPN user lifecycle management
# =============================================================================

[[ -n "${_SSH_USER_SH:-}" ]] && return 0
readonly _SSH_USER_SH=1

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/validation.sh"

readonly SSH_USERS_DB="${SSH_USERS_DB:-/etc/vps-autoscript/config/ssh_users.db}"

# -----------------------------------------------------------------------------
# User DB (CSV: username,expiry,max_login,created_at)
# -----------------------------------------------------------------------------

_ssh_db_init() {
  [[ -f "${SSH_USERS_DB}" ]] && return 0
  ensure_dir "$(dirname "${SSH_USERS_DB}")" 700
  echo "# username,expiry,max_login,created_at" > "${SSH_USERS_DB}"
  chmod 600 "${SSH_USERS_DB}"
}

_ssh_db_add() {
  local username="$1" expiry="$2" max_login="${3:-2}" created_at
  created_at=$(date '+%Y-%m-%d')
  echo "${username},${expiry},${max_login},${created_at}" >> "${SSH_USERS_DB}"
}

_ssh_db_remove() {
  local username="$1"
  sed -i "/^${username},/d" "${SSH_USERS_DB}"
}

_ssh_db_get() {
  local username="$1"
  grep "^${username}," "${SSH_USERS_DB}" 2>/dev/null
}

_ssh_db_exists() {
  local username="$1"
  grep -q "^${username}," "${SSH_USERS_DB}" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Create a new SSH user
# -----------------------------------------------------------------------------

ssh_add_user() {
  local username="$1"
  local expiry="$2"       # YYYY-MM-DD
  local password="$3"
  local max_login="${4:-2}"

  # Validation
  is_valid_username "${username}" || { error "Invalid username: ${username}"; return 1; }
  is_future_date "${expiry}"      || { error "Expiry must be in future: ${expiry}"; return 1; }
  id "${username}" &>/dev/null    && { error "System user '${username}' already exists."; return 1; }

  # Convert YYYY-MM-DD expiry to days from now for chage
  local expiry_epoch today_epoch days_from_now
  expiry_epoch=$(date -d "${expiry}" +%s)
  today_epoch=$(date +%s)
  days_from_now=$(( (expiry_epoch - today_epoch) / 86400 ))
  [[ ${days_from_now} -lt 1 ]] && { error "Expiry must be at least 1 day in future."; return 1; }

  # Create user: no home dir, no login shell (restricted to SSH tunnel)
  useradd -M -s /bin/false -e "${expiry}" "${username}"
  echo "${username}:${password}" | chpasswd

  # Set account expiry via chage
  chage -E "${expiry}" -M 99999 "${username}"

  # Register in DB
  _ssh_db_init
  _ssh_db_add "${username}" "${expiry}" "${max_login}"

  log_audit "ssh_add_user" "user=${username} expiry=${expiry}"
  success "SSH user '${username}' created (expires: ${expiry})."
  _ssh_show_info "${username}" "${password}" "${expiry}" "${max_login}"
}

# Create with prompts
ssh_add_user_interactive() {
  local username expiry max_login
  prompt_username "Enter username" username
  prompt_expiry "Expiry date (YYYY-MM-DD)" expiry
  prompt_max_login "Max concurrent logins" max_login
  local password
  password=$(gen_password 12)
  ssh_add_user "${username}" "${expiry}" "${password}" "${max_login}"
}

# -----------------------------------------------------------------------------
# Delete a user
# -----------------------------------------------------------------------------

ssh_del_user() {
  local username="$1"
  id "${username}" &>/dev/null || { error "User '${username}' does not exist."; return 1; }

  # Kill all active sessions first
  pkill -u "${username}" 2>/dev/null || true
  sleep 1

  # Remove system user (no -r to avoid removing home if shared)
  userdel "${username}" 2>/dev/null
  # Clean up any lingering processes
  pkill -9 -u "${username}" 2>/dev/null || true

  _ssh_db_remove "${username}"
  log_audit "ssh_del_user" "user=${username}"
  success "SSH user '${username}' deleted."
}

# -----------------------------------------------------------------------------
# Renew user expiry
# -----------------------------------------------------------------------------

ssh_renew_user() {
  local username="$1"
  local new_expiry="$2"

  id "${username}" &>/dev/null || { error "User '${username}' does not exist."; return 1; }
  is_future_date "${new_expiry}" || { error "New expiry must be in future."; return 1; }

  chage -E "${new_expiry}" "${username}"
  usermod -e "${new_expiry}" "${username}"

  # Update DB
  sed -i "s/^${username},\([^,]*\)/\
${username},${new_expiry}/" "${SSH_USERS_DB}"

  log_audit "ssh_renew_user" "user=${username} new_expiry=${new_expiry}"
  success "SSH user '${username}' renewed until ${new_expiry}."
}

# -----------------------------------------------------------------------------
# Lock / unlock
# -----------------------------------------------------------------------------

ssh_lock_user() {
  local username="$1"
  id "${username}" &>/dev/null || { error "User '${username}' does not exist."; return 1; }
  passwd -l "${username}" &>/dev/null
  usermod -s /sbin/nologin "${username}" 2>/dev/null || true
  log_audit "ssh_lock_user" "user=${username}"
  success "SSH user '${username}' locked."
}

ssh_unlock_user() {
  local username="$1"
  id "${username}" &>/dev/null || { error "User '${username}' does not exist."; return 1; }
  passwd -u "${username}" &>/dev/null
  usermod -s /bin/false "${username}" 2>/dev/null || true
  log_audit "ssh_unlock_user" "user=${username}"
  success "SSH user '${username}' unlocked."
}

# -----------------------------------------------------------------------------
# List users
# -----------------------------------------------------------------------------

ssh_list_users() {
  _ssh_db_init
  separator
  printf "%-20s %-12s %-10s %-10s %-8s\n" "USERNAME" "EXPIRY" "MAX LOGIN" "CREATED" "STATUS"
  separator
  local today_epoch
  today_epoch=$(date +%s)
  while IFS=',' read -r username expiry max_login created_at; do
    [[ "${username}" == "#"* ]] && continue
    local expiry_epoch
    expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null || echo 0)
    local status active_sessions
    active_sessions=$(who 2>/dev/null | grep -c "^${username} " || echo 0)
    if [[ ${expiry_epoch} -lt ${today_epoch} ]]; then
      status="${RED}EXPIRED${RESET}"
    elif ! id "${username}" &>/dev/null; then
      status="${YELLOW}MISSING${RESET}"
    else
      status="${GREEN}ACTIVE(${active_sessions})${RESET}"
    fi
    printf "%-20s %-12s %-10s %-10s " "${username}" "${expiry}" "${max_login}" "${created_at}"
    echo -e "${status}"
  done < <(grep -v '^#' "${SSH_USERS_DB}" 2>/dev/null || true)
  separator
}

# -----------------------------------------------------------------------------
# Multi-login limiter (replaces tendang.sh)
# Kills excess sessions without restarting SSH service
# -----------------------------------------------------------------------------

ssh_enforce_login_limit() {
  local max_login="${1:-2}"
  local killed=0

  # Get all logged-in users grouped by username
  declare -A user_sessions
  while IFS= read -r line; do
    local uname
    uname=$(echo "${line}" | awk '{print $1}')
    user_sessions["${uname}"]="${user_sessions["${uname}"]:-0}"
    user_sessions["${uname}"]=$(( user_sessions["${uname}"] + 1 ))
  done < <(who 2>/dev/null)

  for uname in "${!user_sessions[@]}"; do
    local count="${user_sessions[${uname}]}"
    if [[ ${count} -gt ${max_login} ]]; then
      local excess=$(( count - max_login ))
      log_warn "User '${uname}' has ${count} sessions (limit: ${max_login}). Killing ${excess} excess."
      # Kill oldest sessions first (pkill sends SIGHUP per process, not global restart)
      local pids=()
      mapfile -t pids < <(pgrep -u "${uname}" -d ' ' | tr ' ' '\n' | head -n "${excess}")
      for pid in "${pids[@]}"; do
        kill -HUP "${pid}" 2>/dev/null || true
        ((killed++))
      done
    fi
  done

  [[ ${killed} -gt 0 ]] && log_info "Multi-login limiter: killed ${killed} excess sessions."
}

# Setup autokill cron
ssh_setup_autokill() {
  local max_login="${1:-2}"
  local interval="${2:-1}"
  local cron_file="/etc/cron.d/ssh-autokill"
  cat > "${cron_file}" <<EOF
# SSH multi-login limiter — managed by vps-autoscript
*/${interval} * * * * root /usr/local/lib/vps-autoscript/ssh_user.sh --enforce-limit ${max_login}
EOF
  chmod 644 "${cron_file}"
  success "Autokill cron set: max_login=${max_login}, interval=${interval}min"
}

# -----------------------------------------------------------------------------
# Auto-delete expired users (for cron)
# -----------------------------------------------------------------------------

ssh_purge_expired() {
  _ssh_db_init
  local today_epoch
  today_epoch=$(date +%s)
  local count=0

  while IFS=',' read -r username expiry _; do
    [[ "${username}" == "#"* ]] && continue
    local expiry_epoch
    expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null || echo 0)
    if [[ ${expiry_epoch} -lt ${today_epoch} ]]; then
      log_info "Purging expired SSH user: ${username} (expired: ${expiry})"
      ssh_del_user "${username}" 2>/dev/null || true
      ((count++))
    fi
  done < <(grep -v '^#' "${SSH_USERS_DB}" 2>/dev/null || true)

  [[ ${count} -gt 0 ]] && log_info "Purged ${count} expired SSH users."
}

# -----------------------------------------------------------------------------
# Connection info display
# -----------------------------------------------------------------------------

_ssh_show_info() {
  local username="$1" password="$2" expiry="$3" max_login="$4"
  local domain
  domain=$(get_domain)
  local ssh_ws_port
  ssh_ws_port=$(get_config PORT_SSHWS "2095")

  separator "═" 60
  echo -e "${BOLD}${CYAN}  SSH Account Info${RESET}"
  separator "═" 60
  echo -e "  ${BOLD}Username    :${RESET} ${username}"
  echo -e "  ${BOLD}Password    :${RESET} ${password}"
  echo -e "  ${BOLD}Host/IP     :${RESET} ${domain}"
  echo -e "  ${BOLD}Port SSH    :${RESET} 22"
  echo -e "  ${BOLD}Port WS     :${RESET} ${ssh_ws_port}"
  echo -e "  ${BOLD}Port SSL    :${RESET} 443"
  echo -e "  ${BOLD}Expiry      :${RESET} ${expiry}"
  echo -e "  ${BOLD}Max Logins  :${RESET} ${max_login}"
  separator "═" 60
}

# CLI entry point for cron invocation
if [[ "${1:-}" == "--enforce-limit" ]]; then
  require_root
  ssh_enforce_login_limit "${2:-2}"
elif [[ "${1:-}" == "--purge-expired" ]]; then
  require_root
  ssh_purge_expired
fi
