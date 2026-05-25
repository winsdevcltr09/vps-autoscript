#!/usr/bin/env bash
# =============================================================================
# backup.sh — Secure backup to configurable storage backends
# Supports: local, rclone (Google Drive/S3/etc), SFTP
# Critically: does NOT include /etc/shadow in backup archives
# =============================================================================

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"

readonly BACKUP_TMP_DIR="/tmp/vps-autoscript-backup"
readonly BACKUP_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
readonly BACKUP_HOSTNAME=$(hostname -s)
readonly BACKUP_ARCHIVE="${BACKUP_TMP_DIR}/${BACKUP_HOSTNAME}_${BACKUP_TIMESTAMP}.tar.gz"

# Files/dirs to include in backup
readonly -a BACKUP_INCLUDE=(
  "/etc/xray/config.json"
  "/etc/xray/xray.crt"
  "/etc/xray/xray.key"
  "/etc/vps-autoscript/config"
  "/etc/openvpn/easy-rsa/pki/ca.crt"
  "/etc/openvpn/easy-rsa/pki/issued"
  "/etc/openvpn/easy-rsa/pki/private"
  "/etc/nginx/conf.d/xray.conf"
  "/etc/trojan-go/config.json"
  "/root/.acme.sh"
  "/root/nsdomain"
)

# Files explicitly excluded (security-sensitive, should never be backed up to cloud)
readonly -a BACKUP_EXCLUDE=(
  "/etc/shadow"
  "/etc/shadow-"
  "/etc/gshadow"
  "/etc/security"
)

# -----------------------------------------------------------------------------
# Create backup archive
# -----------------------------------------------------------------------------

create_backup_archive() {
  local passphrase="${1:-}"
  ensure_dir "${BACKUP_TMP_DIR}" 700
  register_cleanup "rm -rf ${BACKUP_TMP_DIR}"

  step "Creating backup archive..."

  local tar_args=(-czf "${BACKUP_ARCHIVE}")
  # Add existing files only
  local include_existing=()
  for path in "${BACKUP_INCLUDE[@]}"; do
    [[ -e "${path}" ]] && include_existing+=("${path}")
  done

  [[ ${#include_existing[@]} -eq 0 ]] && { warn "Nothing to backup."; return 1; }

  tar "${tar_args[@]}" "${include_existing[@]}" 2>/dev/null \
    || { error "tar failed."; return 1; }

  local archive_size
  archive_size=$(du -sh "${BACKUP_ARCHIVE}" | cut -f1)
  success "Archive created: ${BACKUP_ARCHIVE} (${archive_size})"

  # Optionally encrypt archive with GPG symmetric
  if [[ -n "${passphrase}" ]]; then
    local encrypted="${BACKUP_ARCHIVE}.gpg"
    echo "${passphrase}" | gpg --batch --passphrase-fd 0 \
      --symmetric --cipher-algo AES256 \
      -o "${encrypted}" "${BACKUP_ARCHIVE}" \
      && rm -f "${BACKUP_ARCHIVE}" \
      && BACKUP_ARCHIVE_FINAL="${encrypted}" \
      || { warn "GPG encryption failed. Using unencrypted archive."; BACKUP_ARCHIVE_FINAL="${BACKUP_ARCHIVE}"; }
    success "Backup archive encrypted."
  else
    BACKUP_ARCHIVE_FINAL="${BACKUP_ARCHIVE}"
  fi
}

# -----------------------------------------------------------------------------
# Upload to rclone remote
# -----------------------------------------------------------------------------

backup_upload_rclone() {
  local archive="$1"
  local remote="${BACKUP_RCLONE_REMOTE:-gdrive}"
  local path="${BACKUP_RCLONE_PATH:-VPSBackup}"

  has_command rclone || { error "rclone not installed. Run: apt install rclone"; return 1; }

  local rclone_conf="${CONFIG_DIR}/rclone.conf"
  [[ -f "${rclone_conf}" ]] || { error "rclone.conf not found at ${rclone_conf}. Configure via setup menu."; return 1; }

  step "Uploading backup to ${remote}:${path}/..."
  rclone copy "${archive}" "${remote}:${path}/" --config "${rclone_conf}" \
    2>&1 | while IFS= read -r line; do log_debug "rclone: ${line}"; done
  success "Backup uploaded to ${remote}:${path}/"
}

# -----------------------------------------------------------------------------
# Upload to SFTP
# -----------------------------------------------------------------------------

backup_upload_sftp() {
  local archive="$1"
  local sftp_host
  sftp_host=$(get_config BACKUP_SFTP_HOST)
  local sftp_user
  sftp_user=$(get_config BACKUP_SFTP_USER)
  local sftp_path
  sftp_path=$(get_config BACKUP_SFTP_PATH "/backup")
  local sftp_key
  sftp_key=$(get_config BACKUP_SFTP_KEY "${HOME}/.ssh/id_rsa")

  [[ -n "${sftp_host}" ]] || { error "BACKUP_SFTP_HOST not configured."; return 1; }

  step "Uploading backup via SFTP to ${sftp_user}@${sftp_host}:${sftp_path}/..."
  scp -i "${sftp_key}" -o StrictHostKeyChecking=no \
    "${archive}" "${sftp_user}@${sftp_host}:${sftp_path}/" \
    || { error "SFTP upload failed."; return 1; }
  success "Backup uploaded via SFTP."
}

# -----------------------------------------------------------------------------
# Telegram notification (no email with hardcoded credentials)
# -----------------------------------------------------------------------------

notify_telegram() {
  local message="$1"
  local bot_token
  bot_token=$(get_config NOTIFY_TELEGRAM_BOT_TOKEN)
  local chat_id
  chat_id=$(get_config NOTIFY_TELEGRAM_CHAT_ID)

  [[ -z "${bot_token}" || -z "${chat_id}" ]] && return 0

  curl -fsSL --max-time 10 \
    "https://api.telegram.org/bot${bot_token}/sendMessage" \
    -d "chat_id=${chat_id}" \
    -d "text=${message}" \
    -d "parse_mode=HTML" \
    &>/dev/null || true
}

# -----------------------------------------------------------------------------
# Retention: delete old backups from rclone remote
# -----------------------------------------------------------------------------

cleanup_old_backups() {
  local remote="${BACKUP_RCLONE_REMOTE:-gdrive}"
  local path="${BACKUP_RCLONE_PATH:-VPSBackup}"
  local keep="${BACKUP_RETENTION_DAYS:-7}"
  local rclone_conf="${CONFIG_DIR}/rclone.conf"

  has_command rclone && [[ -f "${rclone_conf}" ]] || return 0

  step "Removing backups older than ${keep} days from ${remote}:${path}/..."
  rclone delete "${remote}:${path}/" \
    --config "${rclone_conf}" \
    --min-age "${keep}d" \
    2>/dev/null || true
  success "Old backup cleanup complete."
}

# -----------------------------------------------------------------------------
# Main backup entry point
# -----------------------------------------------------------------------------

run_backup() {
  require_root
  acquire_lock "backup"

  local passphrase
  passphrase=$(get_config BACKUP_PASSPHRASE "")
  local backend
  backend=$(get_config BACKUP_BACKEND "rclone")

  log_info "Starting backup (backend: ${backend})..."

  create_backup_archive "${passphrase}"

  case "${backend}" in
    rclone)  backup_upload_rclone "${BACKUP_ARCHIVE_FINAL}" ;;
    sftp)    backup_upload_sftp   "${BACKUP_ARCHIVE_FINAL}" ;;
    local)   ensure_dir "${BACKUP_DIR}"; cp "${BACKUP_ARCHIVE_FINAL}" "${BACKUP_DIR}/"; success "Backup saved locally." ;;
    *)       error "Unknown backup backend: ${backend}" ;;
  esac

  cleanup_old_backups

  notify_telegram "✅ <b>Backup completed</b>
Host: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S')
Size: $(du -sh "${BACKUP_ARCHIVE_FINAL}" | cut -f1)"

  log_info "Backup complete."
  release_lock
}

# Setup automatic backup cron
setup_autobackup_cron() {
  local hour="${1:-0}"
  local minute="${2:-5}"
  local cron_file="/etc/cron.d/vps-autobackup"
  cat > "${cron_file}" <<EOF
# VPS Autoscript — auto backup
${minute} ${hour} * * * root /usr/local/bin/autoscript-backup
EOF
  chmod 644 "${cron_file}"
  set_config BACKUP_ENABLED true
  success "Auto-backup cron set: daily at ${hour}:$(printf '%02d' ${minute})"
}

remove_autobackup_cron() {
  rm -f "/etc/cron.d/vps-autobackup"
  set_config BACKUP_ENABLED false
  success "Auto-backup cron removed."
}

# CLI entry point
case "${1:-run}" in
  run)   run_backup ;;
  setup) setup_autobackup_cron "${2:-0}" "${3:-5}" ;;
  off)   remove_autobackup_cron ;;
  *)     error "Usage: $0 [run|setup|off]"; exit 1 ;;
esac
