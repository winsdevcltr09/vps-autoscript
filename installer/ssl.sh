#!/usr/bin/env bash
# =============================================================================
# ssl.sh — SSL certificate management via acme.sh (Let's Encrypt)
# =============================================================================

[[ -n "${_SSL_SH:-}" ]] && return 0
readonly _SSL_SH=1

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"

readonly ACME_SH="${HOME}/.acme.sh/acme.sh"
readonly ACME_INSTALL_URL="https://get.acme.sh"
readonly CERT_DIR="/etc/xray"
readonly CERT_FILE="${CERT_DIR}/xray.crt"
readonly KEY_FILE="${CERT_DIR}/xray.key"
readonly SSL_LOG="${LOG_DIR}/ssl.log"

# -----------------------------------------------------------------------------
# Install acme.sh from official source
# -----------------------------------------------------------------------------

install_acme() {
  if [[ -f "${ACME_SH}" ]]; then
    info "acme.sh already installed at ${ACME_SH}"
    return 0
  fi
  step "Installing acme.sh from official source..."
  local tmpscript
  tmpscript=$(mktemp /tmp/acme_install.XXXXXXXX.sh)
  register_cleanup "rm -f ${tmpscript}"
  safe_download "${ACME_INSTALL_URL}" "${tmpscript}"
  bash "${tmpscript}" --install-online -m "$(get_config ADMIN_EMAIL "admin@$(get_domain)")"
  success "acme.sh installed."
}

# Set default CA to Let's Encrypt
set_default_ca() {
  "${ACME_SH}" --set-default-ca --server letsencrypt 2>>"${SSL_LOG}"
}

# -----------------------------------------------------------------------------
# Issue a certificate for a domain
# -----------------------------------------------------------------------------

issue_cert() {
  local domain="$1"
  local key_length="${2:-ec-256}"

  step "Issuing SSL certificate for: ${domain} (${key_length})..."

  ensure_dir "${CERT_DIR}" 755 "root:root"

  # Stop nginx temporarily for standalone challenge
  systemctl stop nginx 2>/dev/null || true
  trap 'systemctl start nginx 2>/dev/null || true' RETURN

  "${ACME_SH}" --issue -d "${domain}" --standalone \
    --keylength "${key_length}" \
    --log "${SSL_LOG}" \
    2>>"${SSL_LOG}"

  local rc=$?
  if [[ ${rc} -ne 0 ]] && [[ ${rc} -ne 2 ]]; then
    error "Certificate issuance failed. Check: ${SSL_LOG}"
    return 1
  fi

  install_cert "${domain}" "${key_length}"
}

# Install cert to xray dir
install_cert() {
  local domain="$1"
  local key_length="${2:-ec-256}"
  local ecc_flag=""
  [[ "${key_length}" == ec-* ]] && ecc_flag="--ecc"

  "${ACME_SH}" --installcert -d "${domain}" ${ecc_flag} \
    --certpath "${CERT_FILE}" \
    --keypath "${KEY_FILE}" \
    --capath "${CERT_DIR}/ca.crt" \
    --fullchainpath "${CERT_DIR}/fullchain.crt" \
    --reloadcmd "systemctl restart xray nginx" \
    2>>"${SSL_LOG}"

  chmod 644 "${CERT_FILE}"
  chmod 600 "${KEY_FILE}"
  success "Certificate installed to ${CERT_DIR}/"
}

# -----------------------------------------------------------------------------
# Renew certificate
# -----------------------------------------------------------------------------

renew_cert() {
  local domain="${1:-$(get_domain)}"
  step "Renewing certificate for: ${domain}..."
  systemctl stop nginx 2>/dev/null || true
  "${ACME_SH}" --renew -d "${domain}" --force 2>>"${SSL_LOG}"
  local rc=$?
  systemctl start nginx 2>/dev/null || true
  if [[ ${rc} -ne 0 ]]; then
    error "Certificate renewal failed. Check: ${SSL_LOG}"
    return 1
  fi
  install_cert "${domain}"
  systemctl restart xray nginx
  success "Certificate renewed."
}

# Setup auto-renew cron (every 60 days check, acme.sh handles idempotency)
setup_autorenew_cron() {
  local cron_file="/etc/cron.d/ssl-autorenew"
  cat > "${cron_file}" <<EOF
# VPS Autoscript — SSL auto-renewal
15 3 */2 * * root ${ACME_SH} --cron --home /root/.acme.sh >> ${SSL_LOG} 2>&1
EOF
  chmod 644 "${cron_file}"
  success "SSL auto-renewal cron configured."
}

# -----------------------------------------------------------------------------
# Certificate info & validation
# -----------------------------------------------------------------------------

cert_expiry_days() {
  local cert="${1:-${CERT_FILE}}"
  [[ -f "${cert}" ]] || { echo 0; return; }
  local expiry_date
  expiry_date=$(openssl x509 -noout -enddate -in "${cert}" 2>/dev/null \
    | sed 's/notAfter=//')
  local expiry_epoch today_epoch
  expiry_epoch=$(date -d "${expiry_date}" +%s 2>/dev/null || echo 0)
  today_epoch=$(date +%s)
  echo $(( (expiry_epoch - today_epoch) / 86400 ))
}

show_cert_info() {
  local cert="${1:-${CERT_FILE}}"
  [[ -f "${cert}" ]] || { warn "Certificate not found: ${cert}"; return 1; }
  separator
  openssl x509 -noout -subject -issuer -dates -in "${cert}" 2>/dev/null
  local days_left
  days_left=$(cert_expiry_days "${cert}")
  if [[ ${days_left} -lt 7 ]]; then
    error "Certificate expires in ${days_left} days! Renew immediately."
  elif [[ ${days_left} -lt 30 ]]; then
    warn "Certificate expires in ${days_left} days."
  else
    success "Certificate valid for ${days_left} more days."
  fi
  separator
}

cert_is_valid() {
  local cert="${1:-${CERT_FILE}}"
  local key="${2:-${KEY_FILE}}"
  [[ -f "${cert}" ]] && [[ -f "${key}" ]] || return 1
  local cert_mod key_mod
  cert_mod=$(openssl x509 -noout -modulus -in "${cert}" 2>/dev/null | sha256sum)
  key_mod=$(openssl pkey -noout -modulus -in "${key}" 2>/dev/null | sha256sum)
  [[ "${cert_mod}" == "${key_mod}" ]]
}
