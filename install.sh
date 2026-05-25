#!/usr/bin/env bash
# =============================================================================
# install.sh — VPS Autoscript entry point
# Usage:
#   curl -fsSL https://your-domain/install.sh | bash              (interactive)
#   bash install.sh --dry-run                                      (check only)
# =============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/your-org/vps-autoscript}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/vps-autoscript}"
BRANCH="${BRANCH:-main}"

# ------------------------------------------------------------------
# Minimal bootstrap check
# ------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] This script must be run as root." >&2
  exit 1
fi

if ! command -v bash &>/dev/null; then
  echo "[ERROR] bash not found." >&2
  exit 1
fi

# Minimum bash version 4.2
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || \
   { [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -lt 2 ]]; }; then
  echo "[ERROR] Bash 4.2+ required. Current: ${BASH_VERSION}" >&2
  exit 1
fi

# ------------------------------------------------------------------
# Install git if missing, then clone/pull the script
# ------------------------------------------------------------------

if ! command -v git &>/dev/null; then
  echo "[INFO] Installing git..."
  apt-get install -y -qq git
fi

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  echo "[INFO] Updating existing installation..."
  git -C "${INSTALL_DIR}" pull --ff-only origin "${BRANCH}"
else
  echo "[INFO] Cloning vps-autoscript to ${INSTALL_DIR}..."
  git clone --depth=1 --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
fi

# ------------------------------------------------------------------
# Hand off to main installer
# ------------------------------------------------------------------

chmod +x "${INSTALL_DIR}/installer/main.sh"
exec bash "${INSTALL_DIR}/installer/main.sh" "$@"
