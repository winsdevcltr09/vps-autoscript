#!/usr/bin/env bash
# =============================================================================
# nginx.sh — Nginx reverse proxy configuration for all VPN protocols
# =============================================================================

[[ -n "${_INSTALLER_NGINX_SH:-}" ]] && return 0
readonly _INSTALLER_NGINX_SH=1

LIB_DIR_LOCAL="$(dirname "${BASH_SOURCE[0]}")/../library"
source "${LIB_DIR_LOCAL}/common.sh"
source "${LIB_DIR_LOCAL}/logger.sh"
source "${LIB_DIR_LOCAL}/service_manager.sh"

readonly NGINX_CONF_DIR="/etc/nginx"
readonly XRAY_VHOST_CONF="${NGINX_CONF_DIR}/conf.d/xray.conf"
readonly NGINX_MAIN_CONF="${NGINX_CONF_DIR}/nginx.conf"

# Cloudflare IPv4 ranges — updated 2024
readonly -a CLOUDFLARE_IPV4=(
  "103.21.244.0/22"
  "103.22.200.0/22"
  "103.31.4.0/22"
  "104.16.0.0/13"
  "104.24.0.0/14"
  "108.162.192.0/18"
  "131.0.72.0/22"
  "141.101.64.0/18"
  "162.158.0.0/15"
  "172.64.0.0/13"
  "173.245.48.0/20"
  "188.114.96.0/20"
  "190.93.240.0/20"
  "197.234.240.0/22"
  "198.41.128.0/17"
)

# Cloudflare IPv6 ranges
readonly -a CLOUDFLARE_IPV6=(
  "2400:cb00::/32"
  "2606:4700::/32"
  "2803:f800::/32"
  "2405:b500::/32"
  "2405:8100::/32"
  "2a06:98c0::/29"
  "2c0f:f248::/32"
)

# -----------------------------------------------------------------------------
# nginx.conf — global tuning
# -----------------------------------------------------------------------------

write_nginx_main_conf() {
  cat > "${NGINX_MAIN_CONF}" <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    access_log /var/log/nginx/access.log combined;
    error_log  /var/log/nginx/error.log warn;

    gzip off;

    include /etc/nginx/conf.d/*.conf;
}

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
  mkdir -p "${NGINX_CONF_DIR}/stream.d"
  success "Nginx main config written."
}

# -----------------------------------------------------------------------------
# Virtual host for Xray + Trojan-Go
# -----------------------------------------------------------------------------

write_xray_vhost() {
  local domain="$1"
  local cert="${XRAY_CONF_DIR:-/etc/xray}/xray.crt"
  local key="${XRAY_CONF_DIR:-/etc/xray}/xray.key"

  # Load port config
  source "$(dirname "${BASH_SOURCE[0]}")/../config/defaults.conf"
  source "${CONFIG_DIR}/autoscript.conf" 2>/dev/null || true

  # Build Cloudflare real_ip lines
  local cf_realip=""
  for cidr in "${CLOUDFLARE_IPV4[@]}"; do
    cf_realip+="    set_real_ip_from ${cidr};\n"
  done
  for cidr in "${CLOUDFLARE_IPV6[@]}"; do
    cf_realip+="    set_real_ip_from ${cidr};\n"
  done

  cat > "${XRAY_VHOST_CONF}" <<EOF
# VPS Autoscript — Xray reverse proxy
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;

    # Cloudflare real IP
$(echo -e "${cf_realip}")
    real_ip_header CF-Connecting-IP;

    # Default — block unknown paths
    location / {
        return 403;
    }

    # VMess WebSocket
    location ${XRAY_WS_PATH_VMESS} {
        proxy_pass       http://127.0.0.1:${PORT_XRAY_VMESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
    }

    # VLESS WebSocket
    location ${XRAY_WS_PATH_VLESS} {
        proxy_pass       http://127.0.0.1:${PORT_XRAY_VLESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
    }

    # Trojan WebSocket (Xray)
    location ${XRAY_WS_PATH_TROJAN} {
        proxy_pass       http://127.0.0.1:${PORT_XRAY_TROJAN_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
    }

    # Trojan-Go WebSocket
    location /trojango {
        proxy_pass       http://127.0.0.1:${PORT_TROJAN_GO};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
    }

    # VMess gRPC
    location /${XRAY_GRPC_SERVICE_VMESS} {
        grpc_pass        grpc://127.0.0.1:${PORT_XRAY_VMESS_GRPC};
        grpc_set_header Host \$host;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
    }

    # VLESS gRPC
    location /${XRAY_GRPC_SERVICE_VLESS} {
        grpc_pass        grpc://127.0.0.1:${PORT_XRAY_VLESS_GRPC};
        grpc_set_header Host \$host;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
    }

    # Trojan gRPC
    location /${XRAY_GRPC_SERVICE_TROJAN} {
        grpc_pass        grpc://127.0.0.1:${PORT_XRAY_TROJAN_GRPC};
        grpc_set_header Host \$host;
        grpc_read_timeout 86400s;
        grpc_send_timeout 86400s;
    }
}
EOF
  success "Nginx Xray vhost written to ${XRAY_VHOST_CONF}"
}

# -----------------------------------------------------------------------------
# Validate and reload Nginx
# -----------------------------------------------------------------------------

validate_and_reload_nginx() {
  nginx -t 2>&1 | while IFS= read -r line; do log_debug "nginx-t: ${line}"; done
  nginx -t &>/dev/null || { error "Nginx configuration test failed."; return 1; }
  systemctl reload nginx || systemctl restart nginx
  success "Nginx configuration applied."
}

# Full setup
setup_nginx() {
  local domain="$1"
  step "Configuring Nginx for ${domain}..."
  apt_install nginx
  write_nginx_main_conf
  write_xray_vhost "${domain}"
  validate_and_reload_nginx
  svc_enable nginx
}
