#!/usr/bin/env bash
# =============================================================================
# dependency_manager.sh — Package and binary dependency management
# =============================================================================

[[ -n "${_DEPENDENCY_MANAGER_SH:-}" ]] && return 0
readonly _DEPENDENCY_MANAGER_SH=1

[[ -z "${RED:-}" ]] && source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# -----------------------------------------------------------------------------
# APT package management
# -----------------------------------------------------------------------------

APT_UPDATED=0

apt_update_once() {
  [[ ${APT_UPDATED} -eq 1 ]] && return 0
  log_info "Updating APT package lists..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  APT_UPDATED=1
}

apt_install() {
  local packages=("$@")
  local to_install=()
  for pkg in "${packages[@]}"; do
    dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii' || to_install+=("${pkg}")
  done
  [[ ${#to_install[@]} -eq 0 ]] && return 0
  apt_update_once
  info "Installing: ${to_install[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}" \
    || fatal "Failed to install packages: ${to_install[*]}"
  success "Installed: ${to_install[*]}"
}

apt_remove() {
  local pkg="$1"
  if dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii'; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${pkg}"
    apt-get autoremove -y -qq
  fi
}

# -----------------------------------------------------------------------------
# Core system dependencies
# -----------------------------------------------------------------------------
readonly -a CORE_DEPENDENCIES=(
  curl wget ca-certificates gnupg lsb-release
  openssl bzip2 zip unzip jq net-tools
  iptables iproute2 cron socat
  fail2ban vnstat screen tmux htop
)

readonly -a VPN_DEPENDENCIES=(
  stunnel4 dropbear openvpn easy-rsa
  nginx python3 python3-pip
)

install_core_deps() {
  step "Installing core dependencies..."
  apt_install "${CORE_DEPENDENCIES[@]}"
}

install_vpn_deps() {
  step "Installing VPN dependencies..."
  apt_install "${VPN_DEPENDENCIES[@]}"
}

# -----------------------------------------------------------------------------
# Python package management
# -----------------------------------------------------------------------------

pip_install() {
  local package="$1"
  python3 -m pip install --quiet "${package}" \
    || warn "pip install failed for: ${package}"
}

# -----------------------------------------------------------------------------
# Node.js — use current LTS via NodeSource
# -----------------------------------------------------------------------------

install_nodejs() {
  if has_command node; then
    local version
    version=$(node --version | sed 's/v//' | cut -d. -f1)
    if [[ ${version} -ge 20 ]]; then
      info "Node.js ${version} already installed. Skipping."
      return 0
    fi
  fi
  step "Installing Node.js LTS (v20)..."
  local keyring_dir="/etc/apt/keyrings"
  ensure_dir "${keyring_dir}"
  safe_download "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" "/tmp/nodesource.gpg.key"
  gpg --dearmor -o "${keyring_dir}/nodesource.gpg" < /tmp/nodesource.gpg.key
  echo "deb [signed-by=${keyring_dir}/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  APT_UPDATED=0
  apt_install nodejs
}

# -----------------------------------------------------------------------------
# BBR TCP Congestion Control
# -----------------------------------------------------------------------------

enable_bbr() {
  local current
  current=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
  if [[ "${current}" == "bbr" ]]; then
    info "BBR already active."
    return 0
  fi
  step "Enabling BBR TCP congestion control..."
  if ! sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
    warn "BBR not available in current kernel. Skipping."
    return 1
  fi
  modprobe tcp_bbr 2>/dev/null || true
  {
    echo "net.core.default_qdisc=fq"
    echo "net.ipv4.tcp_congestion_control=bbr"
  } > /etc/sysctl.d/99-bbr.conf
  sysctl -p /etc/sysctl.d/99-bbr.conf
  success "BBR enabled."
}

# -----------------------------------------------------------------------------
# System tuning
# -----------------------------------------------------------------------------

apply_sysctl_tuning() {
  step "Applying network and kernel tuning..."
  cat > /etc/sysctl.d/99-vps-autoscript.conf <<'EOF'
# VPS Autoscript — network tuning
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 8192
fs.file-max = 1000000
net.core.somaxconn = 65535
EOF
  sysctl -p /etc/sysctl.d/99-vps-autoscript.conf &>/dev/null
  success "Sysctl tuning applied."
}

configure_limits() {
  cat > /etc/security/limits.d/99-vps-autoscript.conf <<'EOF'
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF
  success "File limits configured."
}

# -----------------------------------------------------------------------------
# Dependency audit — check that required commands exist
# -----------------------------------------------------------------------------

audit_dependencies() {
  local missing=()
  local commands=(curl wget openssl nginx python3 jq systemctl)
  for cmd in "${commands[@]}"; do
    has_command "${cmd}" || missing+=("${cmd}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required commands: ${missing[*]}"
    return 1
  fi
  success "All required dependencies present."
}

# Print dependency versions
show_dependency_versions() {
  separator
  printf "%-20s %s\n" "DEPENDENCY" "VERSION"
  separator
  local cmds=(curl wget openssl nginx python3 node jq)
  for cmd in "${cmds[@]}"; do
    if has_command "${cmd}"; then
      local ver
      ver=$("${cmd}" --version 2>&1 | head -n1 | grep -oP '[\d]+\.[\d]+\.?[\d]*' | head -n1)
      printf "%-20s %s\n" "${cmd}" "${ver:-unknown}"
    else
      printf "%-20s ${RED}%s${RESET}\n" "${cmd}" "NOT INSTALLED"
    fi
  done
  separator
}
