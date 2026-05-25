#!/usr/bin/env bash
# =============================================================================
# logger.sh — Centralized structured logging system
# =============================================================================

# Guard against double-source
[[ -n "${_LOGGER_SH:-}" ]] && return 0
readonly _LOGGER_SH=1

# Source common only if not already loaded
[[ -z "${RED:-}" ]] && source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# -----------------------------------------------------------------------------
# Log configuration
# -----------------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/var/log/vps-autoscript}"
LOG_FILE="${LOG_DIR}/autoscript.log"
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-10}"
LOG_ROTATE_COUNT="${LOG_ROTATE_COUNT:-5}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR

declare -A _LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)

_init_logger() {
  [[ -d "${LOG_DIR}" ]] || mkdir -p "${LOG_DIR}"
  [[ -f "${LOG_FILE}" ]] || touch "${LOG_FILE}"
  chmod 640 "${LOG_FILE}"
}

# -----------------------------------------------------------------------------
# Core logging function
# -----------------------------------------------------------------------------
_log() {
  local level="$1"; shift
  local message="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local caller_info="${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}"

  # Level filter
  local level_int="${_LOG_LEVELS[$level]:-1}"
  local threshold="${_LOG_LEVELS[$LOG_LEVEL]:-1}"
  [[ ${level_int} -ge ${threshold} ]] || return 0

  # Ensure log dir exists
  _init_logger

  # Write structured log line
  printf '[%s] [%s] [%s] %s\n' \
    "${timestamp}" "${level}" "${caller_info}" "${message}" \
    >> "${LOG_FILE}"

  # Rotate if needed
  _maybe_rotate_log
}

_maybe_rotate_log() {
  local max_bytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))
  local current_size
  current_size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)
  if [[ ${current_size} -ge ${max_bytes} ]]; then
    for i in $(seq $((LOG_ROTATE_COUNT - 1)) -1 1); do
      [[ -f "${LOG_FILE}.${i}" ]] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
    done
    mv "${LOG_FILE}" "${LOG_FILE}.1"
    touch "${LOG_FILE}"
    chmod 640 "${LOG_FILE}"
  fi
}

# -----------------------------------------------------------------------------
# Public logging API
# -----------------------------------------------------------------------------
log_debug() { _log DEBUG "$*"; }
log_info()  { _log INFO  "$*"; info "$*"; }
log_warn()  { _log WARN  "$*"; warn "$*"; }
log_error() { _log ERROR "$*"; error "$*"; }

# Log an action result with timing
log_action() {
  local action="$1"
  local start_ts=$SECONDS
  shift
  log_info "Starting: ${action}"
  if "$@"; then
    local elapsed=$(( SECONDS - start_ts ))
    log_info "Completed: ${action} (${elapsed}s)"
    return 0
  else
    local rc=$?
    log_error "Failed: ${action} (exit ${rc})"
    return ${rc}
  fi
}

# Log command output with prefix
log_cmd() {
  local label="$1"; shift
  local output
  if output=$("$@" 2>&1); then
    log_debug "${label}: ${output}"
    return 0
  else
    log_error "${label} failed: ${output}"
    return 1
  fi
}

# Emit audit trail entry (security-relevant events)
log_audit() {
  local event="$1"
  local detail="${2:-}"
  local user="${SUDO_USER:-${USER:-root}}"
  local ip
  ip=$(get_public_ip 2>/dev/null || echo "unknown")
  _log INFO "[AUDIT] event=${event} user=${user} ip=${ip} detail=${detail}"
}

# Show recent log entries
show_log() {
  local lines="${1:-50}"
  local level_filter="${2:-}"
  _init_logger
  if [[ -n "${level_filter}" ]]; then
    grep "\[${level_filter}\]" "${LOG_FILE}" | tail -n "${lines}"
  else
    tail -n "${lines}" "${LOG_FILE}"
  fi
}

# Export log to a temp file for sending
export_log() {
  local dest="${1:-/tmp/autoscript_$(date +%Y%m%d_%H%M%S).log}"
  cp "${LOG_FILE}" "${dest}"
  echo "${dest}"
}
