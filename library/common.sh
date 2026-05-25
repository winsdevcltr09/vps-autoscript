#!/usr/bin/env bash
# =============================================================================
# common.sh — Shared functions, colors, and global constants
# Part of vps-autoscript clean architecture
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# ANSI Color Codes
# -----------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RESET='\033[0m'

# -----------------------------------------------------------------------------
# Global Paths
# -----------------------------------------------------------------------------
readonly SCRIPT_BASE_DIR="/etc/vps-autoscript"
readonly CONFIG_DIR="${SCRIPT_BASE_DIR}/config"
readonly LOG_DIR="/var/log/vps-autoscript"
readonly LOCK_DIR="/var/run/vps-autoscript"
readonly BACKUP_DIR="/var/backups/vps-autoscript"
readonly LIB_DIR="/usr/local/lib/vps-autoscript"
readonly BIN_DIR="/usr/local/bin"

# Xray paths
readonly XRAY_CONF="/etc/xray/config.json"
readonly XRAY_USERS_DB="${CONFIG_DIR}/xray_users.db"
readonly XRAY_BIN="/usr/local/bin/xray"

# Certificate paths
readonly SSL_CERT="/etc/xray/xray.crt"
readonly SSL_KEY="/etc/xray/xray.key"
readonly ACME_DIR="/root/.acme.sh"

# SSH paths
readonly SSH_USERS_DB="${CONFIG_DIR}/ssh_users.db"

# Domain config
readonly DOMAIN_FILE="${CONFIG_DIR}/domain"
readonly VERSION_FILE="${SCRIPT_BASE_DIR}/version"

# Current version
readonly AUTOSCRIPT_VERSION="3.0.0"

# -----------------------------------------------------------------------------
# Print Helpers
# -----------------------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
fatal()   { echo -e "${RED}[FATAL]${RESET} $*" >&2; exit 1; }
step()    { echo -e "${BOLD}${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
banner()  { echo -e "${MAGENTA}${BOLD}$*${RESET}"; }

# Print horizontal separator
separator() {
  local char="${1:--}"
  local width="${2:-70}"
  printf '%*s\n' "${width}" '' | tr ' ' "${char}"
}

# Confirm prompt — returns 0 for yes, 1 for no
confirm() {
  local msg="${1:-Are you sure?}"
  local answer
  read -rp "$(echo -e "${YELLOW}${msg} [y/N]:${RESET} ")" answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

# Check if a command exists
has_command() { command -v "$1" &>/dev/null; }

# Check if running as root
require_root() {
  [[ $EUID -eq 0 ]] || fatal "This script must be run as root."
}

# Check if a service is active
service_active() { systemctl is-active --quiet "$1"; }

# Safely read a config value: get_config KEY [default]
get_config() {
  local key="$1"
  local default="${2:-}"
  local val
  val=$(grep -Po "(?<=^${key}=).*" "${CONFIG_DIR}/autoscript.conf" 2>/dev/null || true)
  echo "${val:-${default}}"
}

# Write a config value (upsert)
set_config() {
  local key="$1"
  local value="$2"
  local file="${CONFIG_DIR}/autoscript.conf"
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

# Get public IPv4 address
get_public_ip() {
  local ip
  ip=$(curl -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null \
    || curl -s --max-time 5 https://api4.ipify.org 2>/dev/null \
    || echo "")
  echo "${ip}"
}

# Get domain from config
get_domain() {
  [[ -f "${DOMAIN_FILE}" ]] && cat "${DOMAIN_FILE}" || get_public_ip
}

# Generate a UUID v4
gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

# Generate random alphanumeric password of given length
gen_password() {
  local length="${1:-12}"
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${length}"
}

# Wait for a port to be open (max $3 seconds)
wait_for_port() {
  local host="$1" port="$2" timeout="${3:-30}"
  local elapsed=0
  while ! nc -z "${host}" "${port}" 2>/dev/null; do
    ((elapsed++))
    [[ ${elapsed} -ge ${timeout} ]] && return 1
    sleep 1
  done
}

# Ensure a directory exists with correct permissions
ensure_dir() {
  local dir="$1"
  local mode="${2:-755}"
  local owner="${3:-root:root}"
  [[ -d "${dir}" ]] || mkdir -p "${dir}"
  chmod "${mode}" "${dir}"
  chown "${owner}" "${dir}"
}

# Lock mechanism — prevents concurrent runs
acquire_lock() {
  local name="$1"
  local lockfile="${LOCK_DIR}/${name}.lock"
  ensure_dir "${LOCK_DIR}"
  exec 9>"${lockfile}"
  flock -n 9 || fatal "Another instance of '${name}' is already running."
}

release_lock() {
  exec 9>&-
}

# Trap-based cleanup registration
_CLEANUP_CMDS=()
register_cleanup() { _CLEANUP_CMDS+=("$1"); }
_run_cleanup() {
  for cmd in "${_CLEANUP_CMDS[@]}"; do eval "${cmd}"; done
}
trap '_run_cleanup' EXIT

# Retry a command up to N times with delay
retry() {
  local max="${1}"; shift
  local delay="${1}"; shift
  local attempt=0
  until "$@"; do
    ((attempt++))
    [[ ${attempt} -ge ${max} ]] && return 1
    warn "Command failed. Retry ${attempt}/${max} in ${delay}s..."
    sleep "${delay}"
  done
}

# Download a file with integrity check (optional sha256)
safe_download() {
  local url="$1"
  local dest="$2"
  local expected_sha256="${3:-}"
  retry 3 5 curl -fsSL --max-time 60 -o "${dest}" "${url}" \
    || fatal "Failed to download: ${url}"
  if [[ -n "${expected_sha256}" ]]; then
    local actual
    actual=$(sha256sum "${dest}" | awk '{print $1}')
    [[ "${actual}" == "${expected_sha256}" ]] \
      || fatal "SHA256 mismatch for ${dest}. Expected: ${expected_sha256}, Got: ${actual}"
  fi
}
