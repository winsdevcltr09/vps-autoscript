#!/usr/bin/env bash
# =============================================================================
# openvpn.sh — OpenVPN TCP + UDP installation and configuration
# =============================================================================

[[ -n "${_INSTALLER_OPENVPN_SH:-}" ]] && return 0
readonly _INSTALLER_OPENVPN_SH=1

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"
source "${LIB_DIR_LOCAL}/dependency_manager.sh"

readonly OVPN_DIR="/etc/openvpn"
readonly OVPN_EASYRSA_DIR="${OVPN_DIR}/easy-rsa"
readonly OVPN_PKI_DIR="${OVPN_EASYRSA_DIR}/pki"

# Default ports (overridable via config)
OVPN_TCP_PORT="${PORT_OPENVPN_TCP:-1194}"
OVPN_UDP_PORT="${PORT_OPENVPN_UDP:-2200}"

# -----------------------------------------------------------------------------
# PKI setup using easy-rsa 3
# -----------------------------------------------------------------------------

setup_pki() {
  step "Setting up OpenVPN PKI with easy-rsa..."
  apt_install easy-rsa openvpn

  ensure_dir "${OVPN_EASYRSA_DIR}"

  if [[ ! -f "${OVPN_EASYRSA_DIR}/easyrsa" ]]; then
    cp -r /usr/share/easy-rsa/. "${OVPN_EASYRSA_DIR}/"
  fi

  pushd "${OVPN_EASYRSA_DIR}" > /dev/null

  # Init PKI if not already done
  if [[ ! -d "${OVPN_PKI_DIR}" ]]; then
    ./easyrsa --batch init-pki
  fi

  # Build CA (no password for automated setup)
  if [[ ! -f "${OVPN_PKI_DIR}/ca.crt" ]]; then
    EASYRSA_BATCH=1 ./easyrsa --batch build-ca nopass
  fi

  # Generate server cert
  if [[ ! -f "${OVPN_PKI_DIR}/issued/server.crt" ]]; then
    EASYRSA_BATCH=1 ./easyrsa --batch gen-req server nopass
    EASYRSA_BATCH=1 ./easyrsa --batch sign-req server server
  fi

  # DH params (use pre-built for speed)
  if [[ ! -f "${OVPN_PKI_DIR}/dh.pem" ]]; then
    openssl dhparam -out "${OVPN_PKI_DIR}/dh.pem" 2048 2>/dev/null
  fi

  # TLS auth key
  if [[ ! -f "${OVPN_DIR}/ta.key" ]]; then
    openvpn --genkey secret "${OVPN_DIR}/ta.key"
  fi

  popd > /dev/null
  success "OpenVPN PKI ready."
}

# -----------------------------------------------------------------------------
# Server config — TCP
# -----------------------------------------------------------------------------

write_server_tcp_conf() {
  local port="${1:-${OVPN_TCP_PORT}}"
  local server_ip
  server_ip=$(get_public_ip)

  cat > "${OVPN_DIR}/server-tcp.conf" <<EOF
# OpenVPN TCP server config
port ${port}
proto tcp
dev tun
ca ${OVPN_PKI_DIR}/ca.crt
cert ${OVPN_PKI_DIR}/issued/server.crt
key ${OVPN_PKI_DIR}/private/server.key
dh ${OVPN_PKI_DIR}/dh.pem
tls-auth ${OVPN_DIR}/ta.key 0
cipher AES-256-GCM
auth SHA256
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
ifconfig-pool-persist /var/log/openvpn/ipp-tcp.txt
keepalive 10 120
persist-key
persist-tun
status /var/log/openvpn/status-tcp.log
log-append /var/log/openvpn/server-tcp.log
verb 3
mute 20
plugin /usr/lib/openvpn/openvpn-plugin-auth-pam.so login
username-as-common-name
# Certificate auth not required (PAM-only mode)
verify-client-cert optional
max-clients 200
EOF
  success "OpenVPN TCP config written (port ${port})."
}

# -----------------------------------------------------------------------------
# Server config — UDP
# -----------------------------------------------------------------------------

write_server_udp_conf() {
  local port="${1:-${OVPN_UDP_PORT}}"

  cat > "${OVPN_DIR}/server-udp.conf" <<EOF
# OpenVPN UDP server config
port ${port}
proto udp
dev tun1
ca ${OVPN_PKI_DIR}/ca.crt
cert ${OVPN_PKI_DIR}/issued/server.crt
key ${OVPN_PKI_DIR}/private/server.key
dh ${OVPN_PKI_DIR}/dh.pem
tls-auth ${OVPN_DIR}/ta.key 0
cipher AES-256-GCM
auth SHA256
server 10.9.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
ifconfig-pool-persist /var/log/openvpn/ipp-udp.txt
keepalive 10 60
persist-key
persist-tun
explicit-exit-notify 1
status /var/log/openvpn/status-udp.log
log-append /var/log/openvpn/server-udp.log
verb 3
plugin /usr/lib/openvpn/openvpn-plugin-auth-pam.so login
username-as-common-name
verify-client-cert optional
max-clients 200
EOF
  success "OpenVPN UDP config written (port ${port})."
}

# -----------------------------------------------------------------------------
# Client config generator
# -----------------------------------------------------------------------------

generate_client_config() {
  local username="$1"
  local protocol="${2:-tcp}"
  local domain
  domain=$(get_domain)
  local port
  [[ "${protocol}" == "tcp" ]] && port="${OVPN_TCP_PORT}" || port="${OVPN_UDP_PORT}"

  local ca_content
  ca_content=$(< "${OVPN_PKI_DIR}/ca.crt")
  local ta_content
  ta_content=$(< "${OVPN_DIR}/ta.key")

  cat <<EOF
client
dev tun
proto ${protocol}
remote ${domain} ${port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
auth-user-pass
verb 3

<ca>
${ca_content}
</ca>

<tls-auth>
${ta_content}
</tls-auth>
key-direction 1
EOF
}

# Save client config to a file
save_client_config() {
  local username="$1"
  local protocol="${2:-tcp}"
  local output_dir="${OVPN_DIR}/clients"
  ensure_dir "${output_dir}" 700
  generate_client_config "${username}" "${protocol}" \
    > "${output_dir}/${username}-${protocol}.ovpn"
  chmod 600 "${output_dir}/${username}-${protocol}.ovpn"
  success "Client config saved: ${output_dir}/${username}-${protocol}.ovpn"
}

# -----------------------------------------------------------------------------
# Full installation
# -----------------------------------------------------------------------------

install_openvpn() {
  step "Installing OpenVPN..."
  apt_install openvpn easy-rsa
  ensure_dir "/var/log/openvpn" 755

  setup_pki
  write_server_tcp_conf
  write_server_udp_conf

  # Enable IP forwarding
  echo 1 > /proc/sys/net/ipv4/ip_forward
  sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf

  # NAT rule for tun interfaces
  local iface
  iface=$(ip route | grep default | awk '{print $5}' | head -n1)
  iptables -t nat -A POSTROUTING -s 10.8.0.0/8 -o "${iface}" -j MASQUERADE 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s 10.9.0.0/8 -o "${iface}" -j MASQUERADE 2>/dev/null || true

  # Persist iptables (if iptables-persistent available)
  apt_install iptables-persistent 2>/dev/null || true
  netfilter-persistent save 2>/dev/null || true

  svc_enable openvpn@server-tcp
  svc_enable openvpn@server-udp
  success "OpenVPN installed and running."
}
