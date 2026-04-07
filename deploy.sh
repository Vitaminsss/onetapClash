#!/usr/bin/env bash
# One-click deploy for Debian/Ubuntu: sub-api + nginx + certbot + systemd + vpn CLI

# Strip Windows CRLF from this file before anything else runs
# (safe to run multiple times; no-op if already LF)
if grep -qU $'\r' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_ROOT="/opt/sub-api"
ENV_FILE="$SUB_ROOT/sub-api.env"

die() { echo "[deploy] error: $*" >&2; exit 1; }
log() { echo "[deploy] $*" >&2; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 运行: sudo bash deploy.sh <域名>"
  fi
}

stop_existing_services() {
  if systemctl is-active --quiet sub-api 2>/dev/null; then
    log "停止已有 sub-api…"
    systemctl stop sub-api || true
  fi
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    log "启动 nginx（certbot 需要）…"
    systemctl start nginx || true
  fi
}

discover_paths() {
  local x s
  x=""
  for c in /usr/local/etc/xray/config.json /etc/xray/config.json /etc/v2ray-agent/xray/conf/config.json \
           /etc/v2ray-agent/xray/config.json; do
    [[ -f "$c" ]] && x="$c" && break
  done
  s=""
  for c in /usr/local/etc/sing-box/config.json /etc/sing-box/config.json \
           /etc/v2ray-agent/sing-box/conf/config.json /etc/v2ray-agent/sing-box/config.json; do
    [[ -f "$c" ]] && s="$c" && break
  done
  echo "$x|$s"
}

write_env() {
  local domain="$1"
  local xray_cfg="$2"
  local sing_cfg="$3"
  mkdir -p "$SUB_ROOT"
  cat >"$ENV_FILE" <<EOF
# Managed by deploy.sh — vpn CLI 会 source 此文件
SUB_PUBLIC_DOMAIN=${domain}
SUB_API_ENV=${ENV_FILE}
XRAY_CONFIG=${xray_cfg}
SINGBOX_CONFIG=${sing_cfg}
XRAY_API_PORT=10085
# 若 sing-box 启用了 Clash API，可填例如 http://127.0.0.1:9191（用于 H2 流量列）
SINGBOX_CLASH_API=
EOF
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip jq curl nginx certbot python3-certbot-nginx openssl uuid-runtime
}

copy_payload() {
  mkdir -p "$SUB_ROOT"
  install -m0644 "$SCRIPT_DIR/app.py" "$SUB_ROOT/app.py"
  install -m0644 "$SCRIPT_DIR/requirements.txt" "$SUB_ROOT/requirements.txt"
  install -m0644 "$SCRIPT_DIR/discover.py" "$SUB_ROOT/discover.py"
  install -m0644 "$SCRIPT_DIR/nginx_patch_v2ray.py" "$SUB_ROOT/nginx_patch_v2ray.py"
  install -m0755 "$SCRIPT_DIR/xray-hook.sh" "$SUB_ROOT/xray-hook.sh"
  install -m0755 "$SCRIPT_DIR/vpn" "/usr/local/bin/vpn"
  # Strip Windows CRLF from all copied scripts/sources
  sed -i 's/\r$//' \
    "$SUB_ROOT/app.py" \
    "$SUB_ROOT/discover.py" \
    "$SUB_ROOT/nginx_patch_v2ray.py" \
    "$SUB_ROOT/xray-hook.sh" \
    "/usr/local/bin/vpn"
  [[ -f "$SUB_ROOT/tokens.json" ]] || echo '[]' >"$SUB_ROOT/tokens.json"
  chmod 0640 "$SUB_ROOT/tokens.json" || true
}

venv_install() {
  python3 -m venv "$SUB_ROOT/venv"
  # shellcheck disable=SC1091
  source "$SUB_ROOT/venv/bin/activate"
  pip install --upgrade pip
  pip install -r "$SUB_ROOT/requirements.txt"
  deactivate
}

build_server_json() {
  local domain="$1"
  local xray_cfg="$2"
  local sing_cfg="$3"
  local args=("$domain")
  [[ -n "$xray_cfg" && -f "$xray_cfg" ]] && args+=("$xray_cfg") || args+=("-")
  [[ -n "$sing_cfg" && -f "$sing_cfg" ]] && args+=("$sing_cfg") || args+=("-")
  python3 "$SUB_ROOT/discover.py" "${args[@]}" >"$SUB_ROOT/server.json"
}

inject_xray() {
  # shellcheck disable=SC1090
  source "$SUB_ROOT/xray-hook.sh"
  export SUB_API_ENV="$ENV_FILE"
  inject_stats_only || log "inject xray stats skipped (no xray config)"
}

write_systemd() {
  cat >/etc/systemd/system/sub-api.service <<'EOF'
[Unit]
Description=Clash subscription API (sub-api)
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/sub-api
EnvironmentFile=-/opt/sub-api/sub-api.env
Environment=SUB_API_HOST=127.0.0.1
Environment=SUB_API_PORT=8080
ExecStart=/opt/sub-api/venv/bin/python /opt/sub-api/app.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sub-api
  systemctl restart sub-api
}

write_nginx_site() {
  local domain="$1"
  mkdir -p /var/www/html /etc/nginx/sites-available /etc/nginx/sites-enabled
  # Ensure nginx.conf includes sites-enabled if it doesn't already
  if [[ -f /etc/nginx/nginx.conf ]] && ! grep -q 'sites-enabled' /etc/nginx/nginx.conf; then
    sed -i '/http {/a\\tinclude /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
  fi
  cat >/etc/nginx/sites-available/sub-api <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    root /var/www/html;

    location /.well-known/acme-challenge/ { }

    location /sub {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /health {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/sub-api /etc/nginx/sites-enabled/sub-api
  nginx -t
  systemctl reload nginx
}

# v2ray-agent：443 经 Xray fallback 到 alone.conf（proxy_protocol）；35172 在 subscribe.conf。
# 两处均需 /sub 反代，见 nginx_patch_v2ray.py。
patch_v2ray_nginx() {
  if [[ -f "$SUB_ROOT/nginx_patch_v2ray.py" ]]; then
    python3 "$SUB_ROOT/nginx_patch_v2ray.py" || log "nginx v2ray 补丁跳过或已存在"
  fi
}

run_certbot() {
  local domain="$1"
  local email="${CERTBOT_EMAIL:-}"

  if certbot certificates 2>/dev/null | grep -q "$domain"; then
    log "证书已存在，跳过申请"
    return 0
  fi

  local certbot_args=("--nginx" "-d" "$domain" "--non-interactive" "--agree-tos" "--redirect")
  if [[ -n "$email" ]]; then
    certbot_args+=("--email" "$email")
  else
    certbot_args+=("--register-unsafely-without-email")
  fi

  certbot "${certbot_args[@]}" || {
    log "certbot 失败：请确认域名已解析到本机且 80 端口可达"
    log "可手动补跑: certbot --nginx -d ${domain} --agree-tos --register-unsafely-without-email --redirect"
    return 0
  }
  nginx -t
  systemctl reload nginx
}

main() {
  need_root
  stop_existing_services
  local domain="${1:-}"
  # 可选：环境变量传邮箱给 certbot，例如 CERTBOT_EMAIL=you@example.com bash deploy.sh domain
  [[ -n "$domain" ]] || die "用法: sudo bash deploy.sh <your.domain.com>
  可选: CERTBOT_EMAIL=you@example.com sudo bash deploy.sh <your.domain.com>"

  install_packages
  copy_payload
  venv_install

  local paths xray_cfg sing_cfg
  paths="$(discover_paths)"
  xray_cfg="${paths%%|*}"
  sing_cfg="${paths##*|}"
  [[ -n "$xray_cfg" ]] || xray_cfg=""
  [[ -n "$sing_cfg" ]] || sing_cfg=""

  write_env "$domain" "$xray_cfg" "$sing_cfg"
  build_server_json "$domain" "$xray_cfg" "$sing_cfg"

  inject_xray
  if [[ -n "$xray_cfg" && -f "$xray_cfg" ]]; then
    # shellcheck disable=SC1090
    source "$SUB_ROOT/xray-hook.sh"
    reload_cores || true
  fi

  write_systemd
  write_nginx_site "$domain"
  run_certbot "$domain"
  patch_v2ray_nginx
  nginx -t && systemctl reload nginx

  export SUB_API_ENV="$ENV_FILE"
  # shellcheck disable=SC1090
  source "$SUB_ROOT/xray-hook.sh"
  log "创建首个订阅用户…"
  SUB_PUBLIC_DOMAIN="$domain" /usr/local/bin/vpn create "first-device" || true

  log "完成。常用命令: vpn create / vpn list / vpn revoke <token>"
}

main "$@"
