#!/usr/bin/env bash
# =============================================================================
# updater.sh — Safe, integrity-verified update system
# =============================================================================

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"

readonly UPDATE_SOURCE="${UPDATE_SOURCE:-https://raw.githubusercontent.com/your-org/vps-autoscript/main}"
readonly UPDATE_TMP_DIR="/tmp/vps-autoscript-update"
readonly VERSION_FILE="${SCRIPT_BASE_DIR}/version"

# -----------------------------------------------------------------------------
# Version comparison
# -----------------------------------------------------------------------------

get_local_version() {
  [[ -f "${VERSION_FILE}" ]] && cat "${VERSION_FILE}" || echo "0.0.0"
}

get_remote_version() {
  curl -fsSL --max-time 10 "${UPDATE_SOURCE}/version" 2>/dev/null || echo "0.0.0"
}

# Returns 0 if remote > local
has_update_available() {
  local local_ver remote_ver
  local_ver=$(get_local_version)
  remote_ver=$(get_remote_version)
  [[ "${local_ver}" != "${remote_ver}" ]] && \
  [[ "$(printf '%s\n' "${local_ver}" "${remote_ver}" | sort -V | tail -n1)" == "${remote_ver}" ]]
}

# -----------------------------------------------------------------------------
# Update manifest (JSON list of files to update)
# Format: [{"path": "library/common.sh", "sha256": "abc..."}, ...]
# -----------------------------------------------------------------------------

fetch_update_manifest() {
  local dest="${UPDATE_TMP_DIR}/manifest.json"
  ensure_dir "${UPDATE_TMP_DIR}" 700
  register_cleanup "rm -rf ${UPDATE_TMP_DIR}"

  curl -fsSL --max-time 30 -o "${dest}" "${UPDATE_SOURCE}/update_manifest.json" \
    || { error "Failed to fetch update manifest."; return 1; }

  # Validate JSON
  python3 -m json.tool "${dest}" > /dev/null 2>&1 \
    || { error "Update manifest is not valid JSON."; return 1; }
  echo "${dest}"
}

# -----------------------------------------------------------------------------
# Download and verify individual script files
# -----------------------------------------------------------------------------

download_update_file() {
  local rel_path="$1"
  local expected_sha256="${2:-}"
  local url="${UPDATE_SOURCE}/${rel_path}"
  local dest="${UPDATE_TMP_DIR}/${rel_path}"

  ensure_dir "$(dirname "${dest}")"
  safe_download "${url}" "${dest}" "${expected_sha256}"
}

# -----------------------------------------------------------------------------
# Atomic update: download all → verify all → install all
# -----------------------------------------------------------------------------

run_update() {
  require_root
  acquire_lock "updater"

  step "Checking for updates..."
  local local_ver remote_ver
  local_ver=$(get_local_version)
  remote_ver=$(get_remote_version)

  if [[ "${local_ver}" == "${remote_ver}" ]]; then
    success "Already up to date (v${local_ver})."
    return 0
  fi

  info "Update available: v${local_ver} → v${remote_ver}"
  confirm "Proceed with update?" || { info "Update cancelled."; return 0; }

  # Pre-update backup
  step "Creating pre-update backup..."
  local snapshot_dir="/tmp/pre_update_snapshot_$(date +%Y%m%d_%H%M%S)"
  ensure_dir "${snapshot_dir}" 700
  cp -r "${LIB_DIR}" "${snapshot_dir}/" 2>/dev/null || true
  cp -r "${BIN_DIR}/autoscript"* "${snapshot_dir}/" 2>/dev/null || true
  register_cleanup "rm -rf ${snapshot_dir}" || true
  success "Pre-update snapshot: ${snapshot_dir}"

  # Fetch manifest
  local manifest_file
  manifest_file=$(fetch_update_manifest) || {
    error "Cannot fetch update manifest. Aborting."
    return 1
  }

  # Parse manifest and download files
  local files_json
  files_json=$(python3 -c "
import json, sys
manifest = json.load(open('${manifest_file}'))
for f in manifest.get('files', []):
    print(f['path'] + '|' + f.get('sha256', ''))
")

  ensure_dir "${UPDATE_TMP_DIR}" 700
  local failed_files=()
  while IFS='|' read -r rel_path sha256; do
    [[ -z "${rel_path}" ]] && continue
    download_update_file "${rel_path}" "${sha256}" \
      || failed_files+=("${rel_path}")
  done <<< "${files_json}"

  if [[ ${#failed_files[@]} -gt 0 ]]; then
    error "Failed to download: ${failed_files[*]}"
    error "Update aborted. No changes made."
    return 1
  fi

  # Install downloaded files
  step "Installing update files..."
  while IFS='|' read -r rel_path _; do
    [[ -z "${rel_path}" ]] && continue
    local src="${UPDATE_TMP_DIR}/${rel_path}"
    local dst="${LIB_DIR}/${rel_path}"
    ensure_dir "$(dirname "${dst}")"
    cp "${src}" "${dst}"
    chmod +x "${dst}"
  done <<< "${files_json}"

  # Update version
  echo "${remote_ver}" > "${VERSION_FILE}"
  success "Updated to v${remote_ver}."

  # Reload services if needed
  systemctl daemon-reload
  safe_restart_xray 2>/dev/null || true
  safe_restart_nginx 2>/dev/null || true

  log_audit "update" "from=${local_ver} to=${remote_ver}"
  success "Update complete: v${local_ver} → v${remote_ver}"
  release_lock
}

# Check only (for cron / menu header display)
check_update_silent() {
  local local_ver remote_ver
  local_ver=$(get_local_version)
  remote_ver=$(get_remote_version 2>/dev/null || echo "${local_ver}")
  if [[ "${local_ver}" != "${remote_ver}" ]]; then
    echo -e "${YELLOW}[UPDATE AVAILABLE: v${remote_ver}]${RESET}"
  fi
}

# CLI
case "${1:-check}" in
  run|install) run_update ;;
  check)       check_update_silent ;;
  version)     echo "Local: $(get_local_version)" && echo "Remote: $(get_remote_version)" ;;
  *)           error "Usage: $0 [run|check|version]"; exit 1 ;;
esac
