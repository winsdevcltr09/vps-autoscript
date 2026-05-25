#!/usr/bin/env bash
# =============================================================================
# restore.sh — Restore from a backup archive
# =============================================================================

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"

readonly RESTORE_TMP_DIR="/tmp/vps-autoscript-restore"

# -----------------------------------------------------------------------------
# Download backup from URL or rclone
# -----------------------------------------------------------------------------

fetch_backup_from_url() {
  local url="$1"
  local dest="${RESTORE_TMP_DIR}/backup_download"
  ensure_dir "${RESTORE_TMP_DIR}" 700
  register_cleanup "rm -rf ${RESTORE_TMP_DIR}"

  step "Downloading backup from URL..."
  safe_download "${url}" "${dest}"
  echo "${dest}"
}

fetch_backup_from_rclone() {
  local filename="$1"
  local remote="${BACKUP_RCLONE_REMOTE:-gdrive}"
  local path="${BACKUP_RCLONE_PATH:-VPSBackup}"
  local rclone_conf="${CONFIG_DIR}/rclone.conf"
  local dest="${RESTORE_TMP_DIR}/${filename}"

  has_command rclone || fatal "rclone not installed."
  [[ -f "${rclone_conf}" ]] || fatal "rclone.conf not found."

  ensure_dir "${RESTORE_TMP_DIR}" 700
  register_cleanup "rm -rf ${RESTORE_TMP_DIR}"

  step "Downloading ${filename} from ${remote}:${path}/..."
  rclone copy "${remote}:${path}/${filename}" "${RESTORE_TMP_DIR}/" \
    --config "${rclone_conf}" || fatal "rclone download failed."
  echo "${dest}"
}

list_rclone_backups() {
  local remote="${BACKUP_RCLONE_REMOTE:-gdrive}"
  local path="${BACKUP_RCLONE_PATH:-VPSBackup}"
  local rclone_conf="${CONFIG_DIR}/rclone.conf"
  [[ -f "${rclone_conf}" ]] || { warn "rclone.conf not found."; return 1; }
  rclone ls "${remote}:${path}/" --config "${rclone_conf}" 2>/dev/null \
    | awk '{print $2}' | grep -E '\.(tar\.gz|tar\.gz\.gpg)$' | sort -r
}

# -----------------------------------------------------------------------------
# Decrypt if GPG-encrypted
# -----------------------------------------------------------------------------

maybe_decrypt() {
  local archive="$1"
  local passphrase="${2:-}"

  if [[ "${archive}" == *.gpg ]]; then
    [[ -n "${passphrase}" ]] || { read -rsp "Enter backup passphrase: " passphrase; echo; }
    local decrypted="${archive%.gpg}"
    echo "${passphrase}" | gpg --batch --passphrase-fd 0 \
      -o "${decrypted}" -d "${archive}" \
      || fatal "Decryption failed. Wrong passphrase?"
    echo "${decrypted}"
  else
    echo "${archive}"
  fi
}

# -----------------------------------------------------------------------------
# Validate archive contents
# -----------------------------------------------------------------------------

validate_archive() {
  local archive="$1"
  step "Validating backup archive..."
  tar -tzf "${archive}" > /dev/null 2>&1 || fatal "Archive is corrupted or not a valid tar.gz."
  # Check for any shadow file — refuse to restore if present
  if tar -tzf "${archive}" 2>/dev/null | grep -q 'etc/shadow'; then
    fatal "SECURITY: Backup archive contains /etc/shadow. Refusing to restore for safety."
  fi
  success "Archive validated."
}

# -----------------------------------------------------------------------------
# Stop services before restore, restart after
# -----------------------------------------------------------------------------

_pre_restore() {
  step "Stopping services before restore..."
  for svc in xray trojan-go nginx openvpn@server-tcp openvpn@server-udp; do
    systemctl stop "${svc}" 2>/dev/null || true
  done
}

_post_restore() {
  step "Restarting services after restore..."
  systemctl daemon-reload
  for svc in nginx xray trojan-go openvpn@server-tcp openvpn@server-udp; do
    systemctl is-enabled --quiet "${svc}" 2>/dev/null && systemctl start "${svc}" || true
  done
  success "Services restarted."
}

# -----------------------------------------------------------------------------
# Perform restore
# -----------------------------------------------------------------------------

do_restore() {
  local archive="$1"
  local passphrase="${2:-}"

  validate_archive "${archive}"

  # Pre-restore: backup current config as rollback point
  local rollback_archive="/tmp/pre_restore_rollback_$(date +%Y%m%d_%H%M%S).tar.gz"
  step "Creating rollback snapshot before restore..."
  tar -czf "${rollback_archive}" \
    /etc/xray/config.json \
    /etc/nginx/conf.d/xray.conf \
    /etc/vps-autoscript/config \
    2>/dev/null || warn "Could not create rollback snapshot."
  success "Rollback snapshot: ${rollback_archive}"

  _pre_restore

  step "Extracting backup archive to /..."
  tar -xzf "${archive}" -C / --no-overwrite-dir \
    || {
      error "Extraction failed. Attempting rollback..."
      tar -xzf "${rollback_archive}" -C / 2>/dev/null || true
      _post_restore
      fatal "Restore failed. Rolled back to pre-restore state."
    }

  # Restore permissions
  [[ -f /etc/xray/config.json ]] && chown www-data:www-data /etc/xray/config.json && chmod 640 /etc/xray/config.json
  [[ -f /etc/xray/xray.key ]] && chmod 600 /etc/xray/xray.key

  _post_restore

  log_audit "restore" "archive=$(basename "${archive}")"
  success "Restore completed successfully."
  warn "Rollback snapshot kept at: ${rollback_archive}"
}

# -----------------------------------------------------------------------------
# Interactive restore menu
# -----------------------------------------------------------------------------

run_restore_interactive() {
  require_root
  echo ""
  echo -e "${BOLD}Select restore source:${RESET}"
  echo "  1) From URL"
  echo "  2) From rclone remote"
  echo "  3) From local file"
  read -rp "$(echo -e "${CYAN}Choice [1-3]: ${RESET}")" choice

  local archive passphrase
  case "${choice}" in
    1)
      local url
      read -rp "$(echo -e "${CYAN}Enter URL: ${RESET}")" url
      archive=$(fetch_backup_from_url "${url}")
      ;;
    2)
      echo ""
      echo "Available backups:"
      list_rclone_backups
      local fname
      read -rp "$(echo -e "${CYAN}Enter filename: ${RESET}")" fname
      archive=$(fetch_backup_from_rclone "${fname}")
      ;;
    3)
      read -rp "$(echo -e "${CYAN}Enter file path: ${RESET}")" archive
      [[ -f "${archive}" ]] || fatal "File not found: ${archive}"
      ;;
    *)
      error "Invalid choice."
      return 1
      ;;
  esac

  [[ "${archive}" == *.gpg ]] && read -rsp "$(echo -e "${CYAN}Backup passphrase: ${RESET}")" passphrase && echo

  archive=$(maybe_decrypt "${archive}" "${passphrase}")

  confirm "Restore will OVERWRITE current config. Proceed?" || { info "Restore cancelled."; return 0; }
  do_restore "${archive}"
}

# CLI entry point
run_restore_interactive
