#!/usr/bin/env bash
# =============================================================================
# cert_manager.sh — Interactive SSL certificate management
# =============================================================================

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/validation.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../installer/ssl.sh"

cert_menu() {
  while true; do
    clear
    echo ""
    echo -e "${BOLD}  SSL Certificate Manager${RESET}"
    separator "─" 40
    show_cert_info
    echo ""
    echo "  [1] Renew certificate now"
    echo "  [2] Re-issue certificate (new domain)"
    echo "  [3] Verify cert/key match"
    echo "  [4] View certificate details"
    echo "  [0] Back"
    separator "─" 40
    read -rp "$(echo -e "${CYAN}  Choice: ${RESET}")" opt
    case "${opt}" in
      1) renew_cert "$(get_domain)" ;;
      2) local new_domain
         prompt_domain "New domain" new_domain
         issue_cert "${new_domain}"
         echo "${new_domain}" > "${DOMAIN_FILE}"
         # Update nginx config with new domain
         source "$(dirname "${BASH_SOURCE[0]}")/../installer/nginx.sh"
         write_xray_vhost "${new_domain}"
         validate_and_reload_nginx ;;
      3) if cert_is_valid; then
           success "Certificate and key match."
         else
           error "Certificate and key DO NOT match! Re-issue required."
         fi ;;
      4) openssl x509 -noout -text -in "${SSL_CERT}" 2>/dev/null | less ;;
      0) break ;;
    esac
    [[ "${opt}" != "0" ]] && read -rp "$(echo -e "${DIM}Press Enter...${RESET}")" || true
  done
}

cert_menu
