#!/usr/bin/env bash
# =============================================================================
# validation.sh — Input validation and sanitization functions
# =============================================================================

[[ -n "${_VALIDATION_SH:-}" ]] && return 0
readonly _VALIDATION_SH=1

[[ -z "${RED:-}" ]] && source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# -----------------------------------------------------------------------------
# String validators
# -----------------------------------------------------------------------------

# Valid username: 3-32 chars, alphanumeric + underscore + hyphen, no leading digit
is_valid_username() {
  local username="$1"
  [[ "${username}" =~ ^[a-zA-Z][a-zA-Z0-9_-]{2,31}$ ]]
}

# Valid domain (simple check)
is_valid_domain() {
  local domain="$1"
  [[ "${domain}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# Valid IPv4 address
is_valid_ipv4() {
  local ip="$1"
  local IFS='.'
  read -ra parts <<< "${ip}"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "${part}" =~ ^[0-9]+$ ]] && [[ ${part} -ge 0 ]] && [[ ${part} -le 255 ]] || return 1
  done
}

# Valid port number (1–65535)
is_valid_port() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] && [[ ${port} -ge 1 ]] && [[ ${port} -le 65535 ]]
}

# Valid date in YYYY-MM-DD format
is_valid_date() {
  local date_str="$1"
  [[ "${date_str}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  date -d "${date_str}" '+%Y-%m-%d' &>/dev/null
}

# Date is in the future
is_future_date() {
  local date_str="$1"
  is_valid_date "${date_str}" || return 1
  local target_epoch today_epoch
  target_epoch=$(date -d "${date_str}" +%s)
  today_epoch=$(date +%s)
  [[ ${target_epoch} -gt ${today_epoch} ]]
}

# Valid UUID v4
is_valid_uuid() {
  local uuid="$1"
  [[ "${uuid}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

# Valid email address (basic)
is_valid_email() {
  local email="$1"
  [[ "${email}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# Positive integer
is_positive_int() {
  local val="$1"
  [[ "${val}" =~ ^[1-9][0-9]*$ ]]
}

# Integer in range [min, max]
is_int_in_range() {
  local val="$1" min="$2" max="$3"
  [[ "${val}" =~ ^[0-9]+$ ]] && [[ ${val} -ge ${min} ]] && [[ ${val} -le ${max} ]]
}

# -----------------------------------------------------------------------------
# Sanitizers
# -----------------------------------------------------------------------------

# Strip dangerous characters from a username
sanitize_username() {
  local input="$1"
  echo "${input}" | tr -dc 'a-zA-Z0-9_-' | head -c 32
}

# Escape string for safe use in sed patterns
escape_sed() {
  local input="$1"
  printf '%s' "${input}" | sed 's/[[\.*^$()+?{|]/\\&/g'
}

# Escape string for safe use in regex
escape_regex() {
  local input="$1"
  printf '%s' "${input}" | sed 's/[.[\*^$]/\\&/g'
}

# Strip ANSI color codes
strip_colors() {
  sed 's/\x1B\[[0-9;]*[mK]//g'
}

# -----------------------------------------------------------------------------
# Interactive prompt validators
# -----------------------------------------------------------------------------

# Prompt for username with validation
prompt_username() {
  local prompt="${1:-Enter username}"
  local var_name="$2"
  local input
  while true; do
    read -rp "$(echo -e "${CYAN}${prompt}: ${RESET}")" input
    input=$(sanitize_username "${input}")
    if ! is_valid_username "${input}"; then
      warn "Username must be 3–32 chars, start with a letter, and contain only a-z, 0-9, _ or -."
      continue
    fi
    if id "${input}" &>/dev/null; then
      warn "User '${input}' already exists on this system."
      continue
    fi
    printf -v "${var_name}" '%s' "${input}"
    break
  done
}

# Prompt for valid expiry date (YYYY-MM-DD, must be in the future)
prompt_expiry() {
  local prompt="${1:-Expiry date (YYYY-MM-DD)}"
  local var_name="$2"
  local input
  while true; do
    read -rp "$(echo -e "${CYAN}${prompt}: ${RESET}")" input
    if ! is_valid_date "${input}"; then
      warn "Invalid date format. Use YYYY-MM-DD."
      continue
    fi
    if ! is_future_date "${input}"; then
      warn "Expiry date must be in the future."
      continue
    fi
    printf -v "${var_name}" '%s' "${input}"
    break
  done
}

# Prompt for a port number
prompt_port() {
  local prompt="${1:-Enter port}"
  local var_name="$2"
  local current="${3:-}"
  local input
  while true; do
    [[ -n "${current}" ]] && echo -e "${DIM}Current: ${current}${RESET}"
    read -rp "$(echo -e "${CYAN}${prompt}: ${RESET}")" input
    if ! is_valid_port "${input}"; then
      warn "Port must be a number between 1 and 65535."
      continue
    fi
    printf -v "${var_name}" '%s' "${input}"
    break
  done
}

# Prompt for a max login count
prompt_max_login() {
  local prompt="${1:-Max concurrent logins}"
  local var_name="$2"
  local input
  while true; do
    read -rp "$(echo -e "${CYAN}${prompt}: ${RESET}")" input
    if ! is_int_in_range "${input}" 1 50; then
      warn "Value must be between 1 and 50."
      continue
    fi
    printf -v "${var_name}" '%s' "${input}"
    break
  done
}

# Prompt for domain
prompt_domain() {
  local prompt="${1:-Enter your domain}"
  local var_name="$2"
  local input
  while true; do
    read -rp "$(echo -e "${CYAN}${prompt}: ${RESET}")" input
    input="${input,,}"  # lowercase
    if ! is_valid_domain "${input}"; then
      warn "Invalid domain format. Example: vpn.example.com"
      continue
    fi
    printf -v "${var_name}" '%s' "${input}"
    break
  done
}

# Prompt for a positive integer
prompt_days() {
  local prompt="${1:-Number of days}"
  local var_name="$2"
  local default="${3:-30}"
  local input
  while true; do
    read -rp "$(echo -e "${CYAN}${prompt} [default: ${default}]: ${RESET}")" input
    input="${input:-${default}}"
    if ! is_int_in_range "${input}" 1 3650; then
      warn "Days must be between 1 and 3650."
      continue
    fi
    printf -v "${var_name}" '%s' "${input}"
    break
  done
}
