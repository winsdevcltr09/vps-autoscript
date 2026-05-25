#!/usr/bin/env bash
# CLI entry point for cron-invoked Xray user operations
BASE_LIB="/usr/local/lib/vps-autoscript"
source "${BASE_LIB}/library/common.sh"
source "${BASE_LIB}/service/xray_user.sh"

case "${1:-}" in
  --purge-expired) require_root; xray_purge_expired ;;
  *) echo "Usage: $0 --purge-expired"; exit 1 ;;
esac
