#!/usr/bin/env bash
# One-click deploy for Debian/Ubuntu: sub-api + nginx + certbot + systemd + vpn CLI

if grep -qU $'\r' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_ROOT="/opt/sub-api"
ENV_FILE="$SUB_ROOT/sub-api.env"
XRAY_API_PORT_DEPLOY="${XRAY_API_PORT:-10085}"

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
  install -m0755 "$SCRIPT_DIR/vpn" "/usr/local/bin/vpn"
  install -m0755 "$SCRIPT_DIR/stop.sh" "/usr/local/bin/sub-api-stop"
  sed -i 's/\r$//' \
    "$SUB_ROOT/app.py" \
    "/usr/local/bin/vpn" \
    "/usr/local/bin/sub-api-stop"
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

# 与 discover.py 等价的 server.json（jq）
build_server_json() {
  local domain="$1"
  local xray_cfg="$2"
  local sing_cfg="$3"
  local xj sj
  if [[ -n "$xray_cfg" && -f "$xray_cfg" ]]; then
    xj="$(jq -c . "$xray_cfg" 2>/dev/null || echo '{}')"
  else
    xj="{}"
  fi
  if [[ -n "$sing_cfg" && -f "$sing_cfg" ]]; then
    sj="$(jq -c . "$sing_cfg" 2>/dev/null || echo '{}')"
  else
    sj="{}"
  fi

  jq -n \
    --arg domain "$domain" \
    --argjson xray "$xj" \
    --argjson sing "$sj" \
    '
    def vless_defaults($d):
      {
        vless_tls: {port: 443, sni: $d, flow: "xtls-rprx-vision"},
        vless_reality: {port: 8888, sni: $d, public_key: "", short_id: "", flow: "xtls-rprx-vision"}
      };

    ($xray | if type == "object" then . else {} end) as $X
    | ($sing | if type == "object" then . else {} end) as $S
    | (
        if ($X | keys | length) == 0 then
          vless_defaults($domain)
        else
          reduce ($X.inbounds // [])[] as $ib (
            vless_defaults($domain);
            if ($ib | type) != "object" or ($ib.protocol != "vless") then .
            else
              ($ib.streamSettings // {}) as $st
              | (($st.security // "") | ascii_downcase) as $sec
              | ($st.realitySettings // {}) as $re
              | (if ($st.tlsSettings | type) == "object" then
                   ($st.tlsSettings.serverName) as $sn
                   | if ($sn | type) == "array" and ($sn | length) > 0 then $sn[0]
                     elif ($sn | type) == "string" then $sn
                     else null end
                 else null end) as $sni
              | if ($sec == "reality") or (($re | keys | length) > 0) then
                  .vless_reality |= (
                    (if $ib.port then .port = ($ib.port | tonumber) else . end)
                    | (if ($re.serverNames | type) == "array" and ($re.serverNames | length) > 0
                       then .sni = $re.serverNames[0] else . end)
                    | (if $re.publicKey then .public_key = $re.publicKey
                       elif $re.public_key then .public_key = $re.public_key else . end)
                    | (if ($re.shortIds | type) == "array" and ($re.shortIds | length) > 0
                       then .short_id = ($re.shortIds[0] | tostring)
                       elif ($re.short_ids | type) == "array" and ($re.short_ids | length) > 0
                       then .short_id = ($re.short_ids[0] | tostring)
                       elif ($re.short_id | type) == "string"
                       then .short_id = $re.short_id
                       else . end)
                  )
                else
                  .vless_tls |= (
                    (if $ib.port then .port = ($ib.port | tonumber) else . end)
                    | (if $sni != null and ($sni | tostring | length) > 0 then .sni = $sni else . end)
                  )
                end
            end
          )
        end
      ) as $vx
    | (
        if ($S | keys | length) == 0 then
          {port: 9999, sni: $domain, alpn: ["h3"]}
        else
          ([$S | .. | objects | select(.type == "hysteria2")] | .[0]) as $h
          | if $h == null then
              {port: 8443, sni: $domain, alpn: ["h3"]}
            else
              {
                port: (($h.listen_port // $h.port // 8443) | tonumber),
                sni: (($h.tls // {}) | .server_name // $domain),
                alpn: ($h.alpn // ["h3"])
              }
            end
        end
      ) as $hy
    | {
        domain: $domain,
        vless_tls: $vx.vless_tls,
        vless_reality: $vx.vless_reality,
        hysteria2: $hy
      }
    ' >"$SUB_ROOT/server.json"
}

merge_xray_stats_deploy() {
  local f="$1"
  local port="$2"
  [[ -f "$f" ]] || { log "Xray config not found: $f"; return 1; }
  local tmp
  tmp="$(mktemp)"
  jq --argjson port "$port" '
    .stats = (.stats // {})
    | .api = (
        if (.api | type) == "object" then
          .api
          | .listen = (.listen // "127.0.0.1")
          | .port = ($port | tonumber)
          | .services = (
              (.services // []) as $s
              | if ($s | index("StatsService")) then $s else $s + ["StatsService"] end
              | if index("HandlerService") then . else . + ["HandlerService"] end
            )
        else
          {
            "tag": "api",
            "listen": "127.0.0.1",
            "port": ($port | tonumber),
            "services": ["HandlerService", "StatsService"]
          }
        end
      )
    | .policy = (
        (.policy // {}) as $p
        | $p
        | .levels = (
            ($p.levels // {}) as $lv
            | $lv
            | .["0"] = (
                ($lv["0"] // {}) as $z
                | $z
                | .statsUserUplink = true
                | .statsUserDownlink = true
              )
          )
      )
  ' "$f" >"$tmp"
  mv "$tmp" "$f"
}

inject_xray() {
  local xray_cfg="${1:-}"
  export SUB_API_ENV="$ENV_FILE"
  [[ -n "$xray_cfg" && -f "$xray_cfg" ]] || { log "inject xray stats skipped (no xray config)"; return 0; }
  merge_xray_stats_deploy "$xray_cfg" "$XRAY_API_PORT_DEPLOY" || log "inject xray stats failed"
}

reload_cores_deploy() {
  for s in xray sing-box v2ray-agent; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
      log "restarting $s"
      systemctl restart "$s" || true
    fi
  done
}

# 与旧版 nginx_patch_v2ray.py 行为一致（内联，不单独文件）
patch_v2ray_nginx() {
  python3 - <<'PY'
import re
import sys
from pathlib import Path


def _make_snippet(indent: str) -> str:
    i = indent + "    "
    return (
        f"{indent}location /sub {{\n"
        f"{i}proxy_pass http://127.0.0.1:8080;\n"
        f"{i}proxy_set_header Host $host;\n"
        f"{i}proxy_set_header X-Real-IP $remote_addr;\n"
        f"{i}proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
        f"{i}proxy_set_header X-Forwarded-Proto $scheme;\n"
        f"{indent}}}\n"
        f"{indent}location /health {{\n"
        f"{i}proxy_pass http://127.0.0.1:8080;\n"
        f"{i}proxy_set_header Host $host;\n"
        f"{indent}}}\n"
    )


def patch_alone_conf(text: str) -> tuple[str, bool]:
    marker = "real_ip_header proxy_protocol"
    if marker not in text:
        return text, False

    out = text
    changed = False
    search_from = 0
    while True:
        i = out.find(marker, search_from)
        if i == -1:
            break
        sub = out[i:]
        m = re.search(r"^(\s*)location /\s*\{\s*$", sub, re.MULTILINE)
        if not m:
            search_from = i + len(marker)
            continue
        rel_start = m.start()
        j = i + rel_start
        segment = out[i:j]
        if "location /sub" in segment:
            search_from = i + len(marker)
            continue
        indent = m.group(1)
        snippet = _make_snippet(indent)
        out = out[:j] + snippet + out[j:]
        changed = True
        search_from = j + len(snippet)

    return out, changed


def patch_subscribe_conf(text: str) -> tuple[str, bool]:
    if "location /sub" in text:
        return text, False

    snippet = _make_snippet("    ")
    mark = "location ~ ^/s/"
    if mark in text:
        idx = text.index(mark)
        return text[:idx] + snippet + text[idx:], True
    idx = text.find("    location / {")
    if idx != -1:
        return text[:idx] + snippet + text[idx:], True
    return text, False


def main() -> int:
    alone = Path("/etc/nginx/conf.d/alone.conf")
    sub = Path("/etc/nginx/conf.d/subscribe.conf")
    any_change = False

    if alone.is_file():
        t = alone.read_text(encoding="utf-8")
        new_t, ch = patch_alone_conf(t)
        if ch:
            alone.write_text(new_t, encoding="utf-8")
            print(f"patched {alone}", file=sys.stderr)
            any_change = True

    if sub.is_file():
        t = sub.read_text(encoding="utf-8")
        new_t, ch = patch_subscribe_conf(t)
        if ch:
            sub.write_text(new_t, encoding="utf-8")
            print(f"patched {sub}", file=sys.stderr)
            any_change = True

    if not alone.is_file() and not sub.is_file():
        print("no alone.conf or subscribe.conf found", file=sys.stderr)
        return 1

    if not any_change:
        print("already patched or nothing to do", file=sys.stderr)
    return 0


raise SystemExit(main())
PY
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

  export SUB_API_ENV="$ENV_FILE"
  inject_xray "$xray_cfg"
  if [[ -n "$xray_cfg" && -f "$xray_cfg" ]]; then
    reload_cores_deploy
  fi

  write_systemd
  write_nginx_site "$domain"
  run_certbot "$domain"
  patch_v2ray_nginx || log "nginx v2ray 补丁跳过或已存在"
  nginx -t && systemctl reload nginx

  export SUB_API_ENV="$ENV_FILE"
  log "创建首个订阅用户…"
  SUB_PUBLIC_DOMAIN="$domain" /usr/local/bin/vpn create "first-device" || true

  log "完成。常用命令: vpn create / vpn list / vpn revoke <token>；停止订阅服务: sudo sub-api-stop"
}

main "$@"
