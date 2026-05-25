#!/usr/bin/env bash
# =============================================================================
# xray_user.sh — Xray user management (VMess / VLESS / Trojan)
# Uses jq for JSON manipulation — no more sed/grep hacks on config.json
# =============================================================================

[[ -n "${_XRAY_USER_SH:-}" ]] && return 0
readonly _XRAY_USER_SH=1

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/validation.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"

readonly XRAY_CONF="${XRAY_CONF:-/etc/xray/config.json}"
readonly XRAY_USERS_DB="${XRAY_USERS_DB:-/etc/vps-autoscript/config/xray_users.db}"

# Protocol → inbound tag mapping
declare -A PROTO_TAG=(
  [vmess]="vmess-ws"
  [vmess-grpc]="vmess-grpc"
  [vless]="vless-ws"
  [vless-grpc]="vless-grpc"
  [trojan]="trojan-ws"
  [trojan-grpc]="trojan-grpc"
)

# Supported protocols for user management (ws variants only for simplicity;
# grpc variants share the same client list and are managed together)
readonly -a USER_PROTOCOLS=(vmess vless trojan)

# -----------------------------------------------------------------------------
# Users DB (CSV: protocol,username,uuid,expiry,max_quota_gb)
# -----------------------------------------------------------------------------

_init_users_db() {
  [[ -f "${XRAY_USERS_DB}" ]] && return 0
  ensure_dir "$(dirname "${XRAY_USERS_DB}")" 700
  echo "# protocol,username,uuid,expiry,max_quota_gb" > "${XRAY_USERS_DB}"
  chmod 600 "${XRAY_USERS_DB}"
}

_db_add() {
  local proto="$1" username="$2" uuid="$3" expiry="$4" quota="${5:-0}"
  _init_users_db
  echo "${proto},${username},${uuid},${expiry},${quota}" >> "${XRAY_USERS_DB}"
}

_db_remove() {
  local proto="$1" username="$2"
  sed -i "/^${proto},${username},/d" "${XRAY_USERS_DB}"
}

_db_get() {
  local proto="$1" username="$2"
  grep "^${proto},${username}," "${XRAY_USERS_DB}" 2>/dev/null
}

_db_exists() {
  local proto="$1" username="$2"
  grep -q "^${proto},${username}," "${XRAY_USERS_DB}" 2>/dev/null
}

_db_list_protocol() {
  local proto="$1"
  grep "^${proto}," "${XRAY_USERS_DB}" 2>/dev/null | grep -v '^#'
}

# -----------------------------------------------------------------------------
# Xray config.json manipulation using jq (atomic write)
# -----------------------------------------------------------------------------

_xray_jq_edit() {
  local jq_expr="$1"
  local tmpfile
  tmpfile=$(mktemp /tmp/xray_conf.XXXXXXXX.json)
  register_cleanup "rm -f ${tmpfile}"

  jq "${jq_expr}" "${XRAY_CONF}" > "${tmpfile}" \
    || { error "jq expression failed."; return 1; }

  # Validate JSON
  python3 -m json.tool "${tmpfile}" > /dev/null 2>&1 \
    || { error "jq produced invalid JSON."; return 1; }

  # Atomic move
  cp "${XRAY_CONF}" "${XRAY_CONF}.bak"
  mv "${tmpfile}" "${XRAY_CONF}"
  chown www-data:www-data "${XRAY_CONF}"
  chmod 640 "${XRAY_CONF}"
}

# Get client list length for a given inbound tag
_xray_client_count() {
  local tag="$1"
  jq "[.inbounds[] | select(.tag == \"${tag}\") | .settings.clients // [] | length] | add // 0" \
    "${XRAY_CONF}" 2>/dev/null || echo 0
}

# Check if a username already exists in an inbound
_xray_user_exists_in_conf() {
  local tag="$1" username="$2"
  local count
  count=$(jq "[.inbounds[] | select(.tag == \"${tag}\") \
    | .settings.clients[]? | select(.email == \"${username}\")] | length" \
    "${XRAY_CONF}" 2>/dev/null || echo 0)
  [[ ${count} -gt 0 ]]
}

# -----------------------------------------------------------------------------
# Add user
# -----------------------------------------------------------------------------

xray_add_user() {
  local protocol="$1"  # vmess | vless | trojan
  local username="$2"
  local expiry="$3"     # YYYY-MM-DD
  local uuid="${4:-$(gen_uuid)}"
  local quota="${5:-0}"

  # Validate inputs
  is_valid_username "${username}" || { error "Invalid username: ${username}"; return 1; }
  is_future_date "${expiry}"      || { error "Expiry must be in the future: ${expiry}"; return 1; }
  is_valid_uuid "${uuid}"         || { error "Invalid UUID: ${uuid}"; return 1; }

  local tag="${PROTO_TAG[${protocol}]:-}"
  [[ -n "${tag}" ]] || { error "Unknown protocol: ${protocol}"; return 1; }

  # Check duplicate in DB
  _db_exists "${protocol}" "${username}" \
    && { error "User '${username}' already exists for ${protocol}."; return 1; }

  # Add to config.json using jq
  local client_entry
  case "${protocol}" in
    vmess)
      client_entry="{\"id\":\"${uuid}\",\"email\":\"${username}\",\"alterId\":0}"
      ;;
    vless)
      client_entry="{\"id\":\"${uuid}\",\"email\":\"${username}\",\"flow\":\"\"}"
      ;;
    trojan)
      client_entry="{\"password\":\"${uuid}\",\"email\":\"${username}\"}"
      ;;
  esac

  # Also update grpc inbound
  local grpc_tag="${PROTO_TAG[${protocol}-grpc]:-}"

  _xray_jq_edit "
    (.inbounds[] | select(.tag == \"${tag}\") .settings.clients) += [${client_entry}]
    | (.inbounds[] | select(.tag == \"${grpc_tag}\") .settings.clients) += [${client_entry}]
  " || { error "Failed to add user to config.json"; return 1; }

  # Add to DB
  _db_add "${protocol}" "${username}" "${uuid}" "${expiry}" "${quota}"

  # Reload Xray
  safe_restart_xray

  log_audit "xray_add_user" "proto=${protocol} user=${username} expiry=${expiry}"
  success "User '${username}' added for ${protocol} (expires: ${expiry})."

  # Return connection info
  _show_connection_info "${protocol}" "${username}" "${uuid}" "${expiry}"
}

# -----------------------------------------------------------------------------
# Delete user
# -----------------------------------------------------------------------------

xray_del_user() {
  local protocol="$1"
  local username="$2"

  _db_exists "${protocol}" "${username}" \
    || { error "User '${username}' not found for ${protocol}."; return 1; }

  local tag="${PROTO_TAG[${protocol}]:-}"
  local grpc_tag="${PROTO_TAG[${protocol}-grpc]:-}"

  local del_field
  [[ "${protocol}" == "trojan" ]] && del_field="email" || del_field="email"

  _xray_jq_edit "
    (.inbounds[] | select(.tag == \"${tag}\") .settings.clients) \
      |= map(select(.email != \"${username}\"))
    | (.inbounds[] | select(.tag == \"${grpc_tag}\") .settings.clients) \
      |= map(select(.email != \"${username}\"))
  " || { error "Failed to remove user from config.json"; return 1; }

  _db_remove "${protocol}" "${username}"
  safe_restart_xray

  log_audit "xray_del_user" "proto=${protocol} user=${username}"
  success "User '${username}' deleted from ${protocol}."
}

# -----------------------------------------------------------------------------
# Renew user expiry
# -----------------------------------------------------------------------------

xray_renew_user() {
  local protocol="$1"
  local username="$2"
  local new_expiry="$3"

  _db_exists "${protocol}" "${username}" \
    || { error "User '${username}' not found for ${protocol}."; return 1; }
  is_future_date "${new_expiry}" \
    || { error "New expiry must be in the future: ${new_expiry}"; return 1; }

  # Update in DB (sed replace expiry field)
  sed -i "s/^${protocol},${username},\([^,]*\),\([^,]*\)/\
${protocol},${username},\1,${new_expiry}/" "${XRAY_USERS_DB}"

  log_audit "xray_renew_user" "proto=${protocol} user=${username} new_expiry=${new_expiry}"
  success "User '${username}' renewed until ${new_expiry}."
}

# -----------------------------------------------------------------------------
# Check active connections via Xray API
# -----------------------------------------------------------------------------

xray_check_traffic() {
  local username="${1:-}"
  if ! has_command xray; then
    warn "Xray binary not found."
    return 1
  fi
  local api_addr="127.0.0.1:${PORT_XRAY_API:-10085}"

  if [[ -n "${username}" ]]; then
    xray api statsquery --server="${api_addr}" \
      -pattern "${username}" 2>/dev/null \
      | jq -r '.stat[] | "\(.name): \(.value // 0 | . / 1048576 | floor) MB"' 2>/dev/null \
      || echo "No stats available."
  else
    xray api statsquery --server="${api_addr}" 2>/dev/null \
      | jq -r '.stat[] | "\(.name): \(.value // 0 | . / 1048576 | floor) MB"' 2>/dev/null \
      || echo "No stats available."
  fi
}

# Count currently connected users (from Xray stats API)
xray_count_active() {
  local protocol="${1:-vmess}"
  local tag="${PROTO_TAG[${protocol}]:-vmess-ws}"
  xray api statsquery --server="127.0.0.1:${PORT_XRAY_API:-10085}" \
    --pattern "inbound>>>${tag}>>>traffic>>>downlink" 2>/dev/null \
    | jq '[.stat[] | select(.value > 0)] | length' 2>/dev/null || echo 0
}

# -----------------------------------------------------------------------------
# List users
# -----------------------------------------------------------------------------

xray_list_users() {
  local protocol="${1:-vmess}"
  _init_users_db
  separator
  printf "%-20s %-36s %-12s\n" "USERNAME" "UUID" "EXPIRY"
  separator
  local today_epoch
  today_epoch=$(date +%s)
  while IFS=',' read -r _ username uuid expiry _; do
    [[ "${username}" == "#"* ]] && continue
    local expiry_epoch
    expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null || echo 0)
    if [[ ${expiry_epoch} -lt ${today_epoch} ]]; then
      printf "${RED}%-20s %-36s %-12s [EXPIRED]${RESET}\n" "${username}" "${uuid}" "${expiry}"
    else
      local days_left=$(( (expiry_epoch - today_epoch) / 86400 ))
      printf "${GREEN}%-20s${RESET} %-36s %-12s (${days_left}d left)\n" "${username}" "${uuid}" "${expiry}"
    fi
  done < <(_db_list_protocol "${protocol}")
  separator
}

# -----------------------------------------------------------------------------
# Auto-delete expired users (called by cron)
# -----------------------------------------------------------------------------

xray_purge_expired() {
  _init_users_db
  local today_epoch
  today_epoch=$(date +%s)
  local count=0

  while IFS=',' read -r proto username uuid expiry _; do
    [[ "${username}" == "#"* ]] && continue
    local expiry_epoch
    expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null || echo 0)
    if [[ ${expiry_epoch} -lt ${today_epoch} ]]; then
      log_info "Purging expired Xray user: ${proto}/${username} (expired: ${expiry})"
      xray_del_user "${proto}" "${username}" 2>/dev/null || true
      ((count++))
    fi
  done < <(grep -v '^#' "${XRAY_USERS_DB}" 2>/dev/null || true)

  [[ ${count} -gt 0 ]] && log_info "Purged ${count} expired Xray users." || log_debug "No expired Xray users."
}

# -----------------------------------------------------------------------------
# Connection info display
# -----------------------------------------------------------------------------

_show_connection_info() {
  local protocol="$1" username="$2" uuid="$3" expiry="$4"
  local domain
  domain=$(get_domain)
  local port=443

  separator "═" 60
  echo -e "${BOLD}${CYAN}  Connection Info — ${protocol^^}${RESET}"
  separator "═" 60
  echo -e "  ${BOLD}Username :${RESET} ${username}"
  echo -e "  ${BOLD}UUID/Pass:${RESET} ${uuid}"
  echo -e "  ${BOLD}Domain   :${RESET} ${domain}"
  echo -e "  ${BOLD}Port     :${RESET} ${port} (TLS)"
  echo -e "  ${BOLD}Expiry   :${RESET} ${expiry}"
  echo -e "  ${BOLD}Protocol :${RESET} ${protocol}"

  case "${protocol}" in
    vmess)
      local vmess_json
      vmess_json=$(python3 -c "
import json, base64
d = {
  'v':'2','ps':'${username}','add':'${domain}','port':'${port}',
  'id':'${uuid}','aid':'0','net':'ws','type':'none',
  'host':'${domain}','path':'${XRAY_WS_PATH_VMESS:-/vmess}','tls':'tls'
}
print('vmess://' + base64.b64encode(json.dumps(d).encode()).decode())
" 2>/dev/null)
      echo -e "\n  ${BOLD}Link (WS+TLS):${RESET}"
      echo -e "  ${DIM}${vmess_json}${RESET}"
      ;;
    vless)
      echo -e "\n  ${BOLD}Link (WS+TLS):${RESET}"
      echo -e "  ${DIM}vless://${uuid}@${domain}:${port}?encryption=none&security=tls&type=ws&host=${domain}&path=${XRAY_WS_PATH_VLESS:-/vless}#${username}${RESET}"
      ;;
    trojan)
      echo -e "\n  ${BOLD}Link (WS+TLS):${RESET}"
      echo -e "  ${DIM}trojan://${uuid}@${domain}:${port}?security=tls&type=ws&host=${domain}&path=${XRAY_WS_PATH_TROJAN:-/trojan-ws}#${username}${RESET}"
      ;;
  esac
  separator "═" 60
}
