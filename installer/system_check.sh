#!/usr/bin/env bash
# =============================================================================
# system_check.sh — Pre-flight system requirement checks
# =============================================================================

[[ -n "${_SYSTEM_CHECK_SH:-}" ]] && return 0
readonly _SYSTEM_CHECK_SH=1

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/validation.sh"

# -----------------------------------------------------------------------------
# OS detection
# -----------------------------------------------------------------------------

detect_os() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="${ID}"
    OS_VERSION="${VERSION_ID}"
    OS_PRETTY="${PRETTY_NAME}"
  else
    fatal "Cannot detect OS: /etc/os-release not found."
  fi
}

check_supported_os() {
  detect_os
  local supported=0
  case "${OS_ID}" in
    ubuntu)
      case "${OS_VERSION}" in
        20.04|22.04|24.04) supported=1 ;;
      esac
      ;;
    debian)
      case "${OS_VERSION}" in
        10|11|12) supported=1 ;;
      esac
      ;;
  esac
  if [[ ${supported} -eq 0 ]]; then
    error "Unsupported OS: ${OS_PRETTY}"
    error "Supported: Ubuntu 20.04/22.04/24.04, Debian 10/11/12"
    return 1
  fi
  success "OS: ${OS_PRETTY} — supported."
}

# -----------------------------------------------------------------------------
# Virtualization check
# -----------------------------------------------------------------------------

check_virtualization() {
  if has_command systemd-detect-virt; then
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || echo "none")
    case "${virt}" in
      openvz|lxc)
        error "Unsupported virtualization: ${virt}"
        error "This script requires KVM, Xen, or bare metal."
        return 1
        ;;
      *)
        success "Virtualization: ${virt}"
        ;;
    esac
  fi
}

# -----------------------------------------------------------------------------
# Resource checks
# -----------------------------------------------------------------------------

check_disk_space() {
  local min_gb="${1:-5}"
  local available_gb
  available_gb=$(df / --output=avail -BG | tail -n1 | tr -d 'G ')
  if [[ ${available_gb} -lt ${min_gb} ]]; then
    error "Insufficient disk space: ${available_gb}GB available, ${min_gb}GB required."
    return 1
  fi
  success "Disk space: ${available_gb}GB available."
}

check_ram() {
  local min_mb="${1:-512}"
  local available_mb
  available_mb=$(free -m | awk '/^Mem:/{print $7}')
  if [[ ${available_mb} -lt ${min_mb} ]]; then
    warn "Low RAM: ${available_mb}MB available (recommended: ${min_mb}MB). Continuing..."
  else
    success "RAM: ${available_mb}MB available."
  fi
}

# -----------------------------------------------------------------------------
# Network checks
# -----------------------------------------------------------------------------

check_internet() {
  if ! retry 3 2 curl -fsSL --max-time 10 -o /dev/null "https://google.com"; then
    fatal "No internet connectivity. Cannot continue."
  fi
  success "Internet connectivity: OK"
}

check_dns_resolution() {
  local test_host="github.com"
  if ! getent hosts "${test_host}" &>/dev/null; then
    error "DNS resolution failed for ${test_host}."
    return 1
  fi
  success "DNS resolution: OK"
}

# Verify that a domain resolves to this server's IP
check_domain_points_here() {
  local domain="$1"
  local server_ip
  server_ip=$(get_public_ip)
  local domain_ip
  domain_ip=$(getent hosts "${domain}" | awk '{print $1}' | head -n1)
  if [[ "${domain_ip}" != "${server_ip}" ]]; then
    warn "Domain ${domain} resolves to ${domain_ip}, but server IP is ${server_ip}."
    warn "SSL certificate issuance may fail if DNS is not propagated."
    return 1
  fi
  success "Domain ${domain} correctly points to ${server_ip}."
}

# -----------------------------------------------------------------------------
# Port conflict checks
# -----------------------------------------------------------------------------

check_port_available() {
  local port="$1"
  if ss -tlnp 2>/dev/null | grep -q ":${port} " \
     || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
    local user
    user=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'users:\(\(".*?"\)' | head -n1)
    warn "Port ${port} is already in use: ${user}"
    return 1
  fi
}

check_critical_ports() {
  local ports=(22 80 443 1194)
  local conflicts=()
  for port in "${ports[@]}"; do
    check_port_available "${port}" 2>/dev/null || conflicts+=("${port}")
  done
  if [[ ${#conflicts[@]} -gt 0 ]]; then
    warn "Port conflicts detected: ${conflicts[*]}"
    warn "These may need to be freed before installation."
  else
    success "No critical port conflicts detected."
  fi
}

# -----------------------------------------------------------------------------
# Kernel checks
# -----------------------------------------------------------------------------

check_kernel_version() {
  local min_major=4 min_minor=9
  local kernel
  kernel=$(uname -r)
  local major minor
  IFS='.' read -r major minor _ <<< "${kernel}"
  if [[ ${major} -lt ${min_major} ]] || { [[ ${major} -eq ${min_major} ]] && [[ ${minor} -lt ${min_minor} ]]; }; then
    warn "Kernel ${kernel} is older than ${min_major}.${min_minor}. BBR may not be available."
    return 1
  fi
  success "Kernel: ${kernel}"
}

# -----------------------------------------------------------------------------
# Full pre-flight check
# -----------------------------------------------------------------------------

run_preflight() {
  step "Running pre-flight system checks..."
  separator
  local failed=0
  check_supported_os  || ((failed++))
  check_virtualization || ((failed++)) || true
  check_disk_space 5  || ((failed++))
  check_ram 512       || true
  check_internet      || ((failed++))
  check_dns_resolution || ((failed++))
  check_kernel_version || true
  separator
  if [[ ${failed} -gt 0 ]]; then
    error "${failed} pre-flight check(s) failed."
    return 1
  fi
  success "All pre-flight checks passed."
}

# Dry-run mode — report only, no install
run_dry_run() {
  banner "=== DRY-RUN MODE: No changes will be made ==="
  separator
  run_preflight || true
  show_dependency_versions 2>/dev/null || true
  info "Dry-run complete. Pass --install to proceed."
}
