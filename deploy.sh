#!/usr/bin/env bash
# =============================================================================
#  VPN 一键部署脚本  —  Xray VLESS+Reality+uTLS  &  Hysteria2
#  含订阅 API（Clash Meta YAML）、用户管理、卸载
#  用法: sudo bash vpn-setup.sh
# =============================================================================
# CRLF 自修复
if grep -qU $'\r' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"; exec bash "$0" "$@"
fi

set -euo pipefail

# ─── 常量 ────────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/vpn-stack"
XRAY_DIR="/usr/local/bin"
XRAY_CONF="/etc/xray"
HY2_CONF="/etc/hysteria"
SUB_DIR="$INSTALL_DIR/sub-api"
STATE_FILE="$INSTALL_DIR/state.json"
TOKENS_FILE="$INSTALL_DIR/tokens.json"
LOG_DIR="/var/log/vpn-stack"

# ─── 颜色 ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[*]${RESET} $*"; }
ok()   { echo -e "${GREEN}[✓]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行: sudo bash vpn-setup.sh"
}

# ─── 主菜单 ──────────────────────────────────────────────────────────────────
main_menu() {
  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║        VPN 一键管理面板                  ║"
    echo "  ║   Xray Reality + Hysteria2 + 订阅API     ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${RESET}"

    local installed=false
    [[ -f "$STATE_FILE" ]] && installed=true

    if $installed; then
      local domain; domain="$(jq -r '.domain' "$STATE_FILE" 2>/dev/null || echo '未知')"
      echo -e "  ${GREEN}● 已安装${RESET}  域名: ${BOLD}${domain}${RESET}"
    else
      echo -e "  ${YELLOW}● 未安装${RESET}"
    fi
    hr
    echo "  1) 安装 / 重新部署"
    echo "  2) 用户管理（新建 / 列表 / 吊销）"
    echo "  3) 查看服务状态"
    echo "  4) 查看节点信息 & 订阅链接"
    echo "  5) 重启所有服务"
    echo "  6) 卸载（删除所有）"
    echo "  0) 退出"
    hr
    read -rp "  请选择 [0-6]: " choice
    case "$choice" in
      1) do_install ;;
      2) user_menu ;;
      3) show_status ;;
      4) show_node_info ;;
      5) restart_all ;;
      6) do_uninstall ;;
      0) echo "再见！"; exit 0 ;;
      *) warn "无效选项，请重试" ; sleep 1 ;;
    esac
  done
}

# ─── 安装流程 ─────────────────────────────────────────────────────────────────
do_install() {
  clear
  echo -e "${BOLD}=== 安装向导 ===${RESET}"
  hr

  # ── 收集参数 ──────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}【1/4】基础信息${RESET}"

  # 自动获取公网 IP
  local server_ip
  server_ip="$(curl -s4 --max-time 5 ip.sb || curl -s4 --max-time 5 ifconfig.me || true)"
  echo -e "  检测到服务器 IP: ${GREEN}${server_ip}${RESET}"

  local domain=""
  while [[ -z "$domain" ]]; do
    read -rp "  请输入你的域名（已解析到本机）: " domain
    domain="${domain// /}"
    [[ -z "$domain" ]] && warn "域名不能为空"
  done

  echo ""
  echo -e "${BOLD}【2/4】端口配置${RESET}（直接回车使用默认值）"
  local xray_port hy2_port sub_port
  read -rp "  Xray Reality 端口 [默认随机 10000-60000]: " xray_port
  [[ -z "$xray_port" ]] && xray_port=$(( RANDOM % 50000 + 10000 ))
  read -rp "  Hysteria2 端口 [默认随机 10000-60000]: " hy2_port
  [[ -z "$hy2_port" ]] && hy2_port=$(( RANDOM % 50000 + 10000 ))
  # 确保两个端口不一样
  while [[ "$hy2_port" == "$xray_port" ]]; do
    hy2_port=$(( RANDOM % 50000 + 10000 ))
  done
  sub_port=8080  # 订阅 API 只监听 127.0.0.1

  echo ""
  echo -e "${BOLD}【3/4】Reality 伪装配置${RESET}"
  echo "  Reality 需要一个可被访问的 TLS 网站作为伪装目标"
  echo "  推荐: www.apple.com / dl.google.com / addons.mozilla.org"
  local reality_dest
  read -rp "  伪装域名 [默认 www.apple.com]: " reality_dest
  [[ -z "$reality_dest" ]] && reality_dest="www.apple.com"

  echo ""
  echo -e "${BOLD}【4/4】Hysteria2 密码 & 证书${RESET}"
  echo "  Hysteria2 需要 TLS 证书。选择方式："
  echo "  1) 自动申请 Let's Encrypt（需要 80 端口未被占用）"
  echo "  2) 自签名证书（客户端需开 skip-cert-verify）"
  local cert_mode
  read -rp "  选择 [1/2，默认1]: " cert_mode
  [[ -z "$cert_mode" ]] && cert_mode=1

  echo ""
  echo -e "  ${YELLOW}确认参数：${RESET}"
  echo "  域名        : $domain"
  echo "  服务器IP    : $server_ip"
  echo "  Xray 端口   : $xray_port"
  echo "  Hysteria2   : $hy2_port"
  echo "  Reality 伪装: $reality_dest"
  echo "  证书方式    : $([ "$cert_mode" = "1" ] && echo "Let's Encrypt" || echo "自签名")"
  echo ""
  read -rp "  确认开始安装？[Y/n]: " confirm
  [[ "${confirm,,}" == "n" ]] && return

  # ── 开始安装 ──────────────────────────────────────────────────────────────
  hr
  log "开始安装..."

  _install_packages
  _install_xray
  _install_hysteria2
  _setup_certs "$domain" "$cert_mode"
  _configure_xray "$domain" "$xray_port" "$reality_dest"
  _configure_hysteria2 "$domain" "$hy2_port"
  _setup_sub_api "$domain" "$xray_port" "$hy2_port"
  _setup_nginx "$domain"
  _save_state "$domain" "$server_ip" "$xray_port" "$hy2_port" "$reality_dest" "$cert_mode"
  _start_services

  ok "安装完成！"
  echo ""
  echo -e "  ${GREEN}创建第一个订阅用户：${RESET}"
  local first_note
  read -rp "  用户备注 [默认: my-device]: " first_note
  [[ -z "$first_note" ]] && first_note="my-device"
  _create_user "$first_note"

  echo ""
  read -rp "按回车返回主菜单..." _
}

# ─── 安装依赖 ─────────────────────────────────────────────────────────────────
_install_packages() {
  log "安装系统依赖..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    curl wget unzip jq openssl uuid-runtime \
    nginx certbot python3-certbot-nginx \
    python3 python3-venv python3-pip \
    net-tools iproute2 \
    2>&1 | grep -E "^(Err|W:)" || true
  ok "系统依赖安装完成"
}

# ─── 安装 Xray ────────────────────────────────────────────────────────────────
_install_xray() {
  log "下载安装 Xray..."
  mkdir -p "$XRAY_CONF" "$LOG_DIR"

  # 获取最新版本号
  local xray_ver
  xray_ver="$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | jq -r '.tag_name' 2>/dev/null || echo "v25.3.6")"

  local arch
  case "$(uname -m)" in
    x86_64)  arch="64" ;;
    aarch64) arch="arm64-v8a" ;;
    armv7l)  arch="arm32-v7a" ;;
    *)       arch="64" ;;
  esac

  local url="https://github.com/XTLS/Xray-core/releases/download/${xray_ver}/Xray-linux-${arch}.zip"
  local tmp_dir; tmp_dir="$(mktemp -d)"

  curl -sL "$url" -o "$tmp_dir/xray.zip" || die "Xray 下载失败，请检查网络"
  unzip -q "$tmp_dir/xray.zip" -d "$tmp_dir/xray"
  install -m0755 "$tmp_dir/xray/xray" "$XRAY_DIR/xray"
  rm -rf "$tmp_dir"

  # 下载 geoip / geosite
  curl -sL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" \
    -o "$XRAY_CONF/geoip.dat" || warn "geoip.dat 下载失败（可选）"
  curl -sL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
    -o "$XRAY_CONF/geosite.dat" || warn "geosite.dat 下载失败（可选）"

  ok "Xray ${xray_ver} 安装完成"
}

# ─── 安装 Hysteria2 ──────────────────────────────────────────────────────────
_install_hysteria2() {
  log "下载安装 Hysteria2..."
  mkdir -p "$HY2_CONF" "$LOG_DIR"

  local hy2_ver
  hy2_ver="$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest \
    | jq -r '.tag_name' 2>/dev/null || echo "app/v2.6.1")"
  # 版本号去掉前缀 "app/"
  local ver_num="${hy2_ver#app/}"

  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    armv7l)  arch="armv7" ;;
    *)       arch="amd64" ;;
  esac

  local url="https://github.com/apernet/hysteria/releases/download/${hy2_ver}/hysteria-linux-${arch}"
  curl -sL "$url" -o /usr/local/bin/hysteria || die "Hysteria2 下载失败"
  chmod +x /usr/local/bin/hysteria

  ok "Hysteria2 ${ver_num} 安装完成"
}

# ─── 证书处理 ─────────────────────────────────────────────────────────────────
_setup_certs() {
  local domain="$1" mode="$2"
  log "配置 TLS 证书..."
  mkdir -p "/etc/ssl/vpn"

  if [[ "$mode" == "1" ]]; then
    # Let's Encrypt — 先确保 nginx 在跑
    systemctl start nginx 2>/dev/null || true
    certbot certonly --nginx -d "$domain" \
      --non-interactive --agree-tos \
      --register-unsafely-without-email \
      --quiet || {
        warn "Let's Encrypt 失败，改用自签名证书"
        _gen_self_signed "$domain"
        return
      }
    # 软链到统一路径
    ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" "/etc/ssl/vpn/cert.pem"
    ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem"   "/etc/ssl/vpn/key.pem"
    ok "Let's Encrypt 证书获取成功"
  else
    _gen_self_signed "$domain"
  fi
}

_gen_self_signed() {
  local domain="$1"
  log "生成自签名证书..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout /etc/ssl/vpn/key.pem \
    -out    /etc/ssl/vpn/cert.pem \
    -days 3650 -nodes \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain}" \
    2>/dev/null
  ok "自签名证书生成完成（有效期 10 年）"
}

# ─── 配置 Xray ────────────────────────────────────────────────────────────────
_configure_xray() {
  local domain="$1" port="$2" dest="$3"
  log "生成 Xray Reality 配置..."

  # 生成 Reality 密钥对
  local keypair; keypair="$($XRAY_DIR/xray x25519 2>/dev/null)"
  local privkey; privkey="$(echo "$keypair" | awk '/Private key:/{print $3}')"
  local pubkey;  pubkey="$(echo  "$keypair" | awk '/Public key:/{print $3}')"
  local short_id; short_id="$(openssl rand -hex 4)"

  # 保存密钥供后续使用
  mkdir -p "$INSTALL_DIR"
  jq -n \
    --arg privkey "$privkey" --arg pubkey "$pubkey" \
    --arg short_id "$short_id" --arg port "$port" \
    --arg dest "$dest" --arg domain "$domain" \
    '{xray_reality_privkey: $privkey, xray_reality_pubkey: $pubkey,
      xray_reality_short_id: $short_id, xray_port: ($port|tonumber),
      xray_dest: $dest, domain: $domain}' > "$INSTALL_DIR/xray-params.json"

  cat > "$XRAY_CONF/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOG_DIR}/xray-access.log",
    "error":  "${LOG_DIR}/xray-error.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["HandlerService", "StatsService"]
  },
  "policy": {
    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
    "system": {"statsInboundUplink": true, "statsInboundDownlink": true}
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}:443",
          "xver": 0,
          "serverNames": ["${dest}"],
          "privateKey": "${privkey}",
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "tag": "api",
      "port": 10085,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {"address": "127.0.0.1"}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block",  "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}
    ]
  }
}
EOF

  # systemd 服务
  cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
After=network.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray
  ok "Xray 配置完成  pubkey=${pubkey}  short_id=${short_id}"
}

# ─── 配置 Hysteria2 ──────────────────────────────────────────────────────────
_configure_hysteria2() {
  local domain="$1" port="$2"
  log "生成 Hysteria2 配置..."

  # 保存 hy2 参数
  local params; params="$(cat "$INSTALL_DIR/xray-params.json")"
  echo "$params" | jq --arg hy2_port "$port" '. + {hy2_port: ($hy2_port|tonumber)}' \
    > "$INSTALL_DIR/xray-params.json.tmp"
  mv "$INSTALL_DIR/xray-params.json.tmp" "$INSTALL_DIR/xray-params.json"

  cat > "$HY2_CONF/config.yaml" <<EOF
listen: :${port}

tls:
  cert: /etc/ssl/vpn/cert.pem
  key:  /etc/ssl/vpn/key.pem

auth:
  type: password
  password: PLACEHOLDER_WILL_BE_REPLACED

masquerade:
  type: proxy
  proxy:
    url: https://${domain}
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF

  # systemd 服务
  cat > /etc/systemd/system/hysteria2.service <<'EOF'
[Unit]
Description=Hysteria2 Service
After=network.target

[Service]
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable hysteria2
  ok "Hysteria2 配置完成"
}

# ─── 订阅 API ─────────────────────────────────────────────────────────────────
_setup_sub_api() {
  local domain="$1" xray_port="$2" hy2_port="$3"
  log "部署订阅 API..."
  mkdir -p "$SUB_DIR"
  [[ -f "$TOKENS_FILE" ]] || echo '[]' > "$TOKENS_FILE"
  chmod 640 "$TOKENS_FILE"

  # ── app.py ──────────────────────────────────────────────────────────────
  cat > "$SUB_DIR/app.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, time
from pathlib import Path
from flask import Flask, request, Response, abort

INSTALL_DIR = Path(os.environ.get("INSTALL_DIR", "/opt/vpn-stack"))
PARAMS_FILE = INSTALL_DIR / "xray-params.json"
TOKENS_FILE = INSTALL_DIR / "tokens.json"
app = Flask(__name__)

def load_params():
    return json.loads(PARAMS_FILE.read_text())

def load_tokens():
    try: return json.loads(TOKENS_FILE.read_text())
    except: return []

def find_token(token):
    for t in load_tokens():
        if t.get("token") == token: return t
    return None

def build_yaml(params, entry):
    domain   = params["domain"]
    uuid     = entry["uuid"]
    note     = entry.get("note", uuid[:8])
    xp       = params.get("xray_port", 443)
    hy2p     = params.get("hy2_port", 8443)
    pubkey   = params.get("xray_reality_pubkey", "")
    short_id = params.get("xray_reality_short_id", "")
    dest     = params.get("xray_dest", "www.apple.com")
    skip_tls = params.get("cert_mode", "1") != "1"

    n_hy2     = f"\U0001f680 {note} \u00b7 HY2"
    n_reality = f"\U0001f512 {note} \u00b7 Reality"

    proxies = (
        f"  - name: \"{n_hy2}\"\n"
        f"    type: hysteria2\n"
        f"    server: {domain}\n"
        f"    port: {hy2p}\n"
        f"    password: {uuid}\n"
        f"    sni: {domain}\n"
        f"    skip-cert-verify: {'true' if skip_tls else 'false'}\n"
        f"    udp: true\n"
        f"    alpn:\n"
        f"      - h3\n"
        f"\n"
        f"  - name: \"{n_reality}\"\n"
        f"    type: vless\n"
        f"    server: {domain}\n"
        f"    port: {xp}\n"
        f"    uuid: {uuid}\n"
        f"    network: tcp\n"
        f"    tls: true\n"
        f"    udp: true\n"
        f"    flow: xtls-rprx-vision\n"
        f"    servername: {dest}\n"
        f"    client-fingerprint: chrome\n"
        f"    reality-opts:\n"
        f"      public-key: {pubkey}\n"
        f"      short-id: {short_id}"
    )

    names_lines = f"      - \"{n_hy2}\"\n      - \"{n_reality}\""

    return (
        "proxies:\n"
        f"{proxies}\n\n"
        "proxy-groups:\n"
        f"  - name: \"\U0001f527 {note} \u00b7 Manual\"\n"
        f"    type: select\n"
        f"    proxies:\n"
        f"{names_lines}\n"
        f"      - DIRECT\n\n"
        f"  - name: \"\u26a1 {note} \u00b7 Auto\"\n"
        f"    type: url-test\n"
        f"    url: http://www.gstatic.com/generate_204\n"
        f"    interval: 300\n"
        f"    tolerance: 50\n"
        f"    proxies:\n"
        f"{names_lines}\n\n"
        "dns:\n"
        "  enable: true\n"
        "  listen: 0.0.0.0:1053\n"
        "  enhanced-mode: fake-ip\n"
        "  fake-ip-range: 198.18.0.1/16\n"
        "  nameserver:\n"
        "    - https://doh.pub/dns-query\n"
        "    - https://dns.alidns.com/dns-query\n"
        "  fallback:\n"
        "    - https://1.1.1.1/dns-query\n"
        "    - https://dns.google/dns-query\n"
        "  fallback-filter:\n"
        "    geoip: true\n"
        "    geoip-code: CN\n"
        "    ipcidr:\n"
        "      - 240.0.0.0/4\n"
        "  default-nameserver:\n"
        "    - 223.5.5.5\n"
        "    - 119.29.29.29\n\n"
        "rules:\n"
        "  - DOMAIN-SUFFIX,localhost,DIRECT\n"
        "  - IP-CIDR,127.0.0.0/8,DIRECT\n"
        "  - IP-CIDR,192.168.0.0/16,DIRECT\n"
        "  - IP-CIDR,10.0.0.0/8,DIRECT\n"
        "  - DOMAIN-SUFFIX,baidu.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,qq.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,wechat.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,weixin.qq.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,bilibili.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,taobao.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,jd.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,alicdn.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,alipay.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,163.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,126.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,zhihu.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,csdn.net,DIRECT\n"
        "  - DOMAIN-SUFFIX,douyin.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,weibo.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,youku.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,iqiyi.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,mi.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,huawei.com,DIRECT\n"
        "  - DOMAIN-SUFFIX,bytedance.com,DIRECT\n"
        "  - GEOIP,CN,DIRECT\n"
        f"  - MATCH,\"\U0001f527 {note} \u00b7 Manual\"\n"
    )

@app.get("/sub")
def sub():
    token = request.args.get("token", "")
    if not token: abort(403)
    entry = find_token(token)
    if not entry: abort(403)
    params = load_params()
    content = build_yaml(params, entry)
    fname = "clash-" + entry.get("note","sub") + ".yaml"
    return Response(content, mimetype="text/plain; charset=utf-8",
                    headers={"Content-Disposition": f'attachment; filename="{fname}"'})

@app.get("/health")
def health():
    return {"status": "ok", "ts": int(time.time())}

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080, debug=False)
PYEOF

  # ── venv ───────────────────────────────────────────────────────────────
  python3 -m venv "$SUB_DIR/venv"
  "$SUB_DIR/venv/bin/pip" install flask gunicorn --quiet

  # ── systemd ─────────────────────────────────────────────────────────────
  cat > /etc/systemd/system/sub-api.service <<EOF
[Unit]
Description=Clash Subscription API
After=network.target

[Service]
Type=simple
WorkingDirectory=${SUB_DIR}
Environment=INSTALL_DIR=${INSTALL_DIR}
ExecStart=${SUB_DIR}/venv/bin/gunicorn --bind 127.0.0.1:8080 --workers 2 --timeout 30 app:app
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sub-api
  ok "订阅 API 部署完成"
}

# ─── Nginx 配置 ───────────────────────────────────────────────────────────────
_setup_nginx() {
  local domain="$1"
  log "配置 Nginx..."
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html

  # 确保 sites-enabled 被加载
  if ! grep -q 'sites-enabled' /etc/nginx/nginx.conf 2>/dev/null; then
    sed -i '/http {/a\\tinclude /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
  fi

  # 写 HTTP 配置（certbot 会自动改成 HTTPS）
  cat > /etc/nginx/sites-available/vpn-sub <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    root /var/www/html;

    location /.well-known/acme-challenge/ { }

    location /sub {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
    }

    location /health {
        proxy_pass       http://127.0.0.1:8080;
        proxy_set_header Host \$host;
    }

    location / {
        return 404;
    }
}
EOF
  # 移除 default site 防止冲突
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/vpn-sub /etc/nginx/sites-enabled/vpn-sub
  nginx -t && systemctl reload nginx
  ok "Nginx 配置完成"
}

# ─── 保存状态 ─────────────────────────────────────────────────────────────────
_save_state() {
  local domain="$1" ip="$2" xray_port="$3" hy2_port="$4" dest="$5" cert_mode="$6"
  local params; params="$(cat "$INSTALL_DIR/xray-params.json")"
  echo "$params" | jq \
    --arg domain "$domain" --arg ip "$ip" \
    --arg cert_mode "$cert_mode" \
    --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {domain: $domain, server_ip: $ip,
          cert_mode: $cert_mode, installed_at: $installed_at}' \
    > "$STATE_FILE"

  # 同步 cert_mode 到 params
  cp "$STATE_FILE" "$INSTALL_DIR/xray-params.json"
}

# ─── 启动服务 ─────────────────────────────────────────────────────────────────
_start_services() {
  log "启动服务..."
  local failed=()

  for svc in xray hysteria2 sub-api nginx; do
    systemctl restart "$svc" 2>/dev/null || { failed+=("$svc"); continue; }
    sleep 1
    if systemctl is-active --quiet "$svc"; then
      ok "$svc 已启动"
    else
      warn "$svc 启动异常，查看日志: journalctl -u $svc -n 20"
      failed+=("$svc")
    fi
  done

  # 检查 sub-api 8080 端口
  local i
  for i in 1 2 3 4 5 6 7 8; do
    ss -tlnp 2>/dev/null | grep -q ':8080 ' && break
    sleep 1
  done
  ss -tlnp 2>/dev/null | grep -q ':8080 ' \
    && ok "sub-api 8080 端口监听正常" \
    || warn "sub-api 8080 端口未检测到，请查看: journalctl -u sub-api -n 30"

  [[ ${#failed[@]} -eq 0 ]] || warn "以下服务启动有问题: ${failed[*]}"
}

# ─── 创建用户 ─────────────────────────────────────────────────────────────────
_create_user() {
  local note="$1"
  [[ -f "$STATE_FILE" ]] || { err "未安装，请先执行安装"; return 1; }

  local uuid; uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  local token; token="$(openssl rand -hex 20)"
  local domain; domain="$(jq -r '.domain' "$STATE_FILE")"
  local hy2_port; hy2_port="$(jq -r '.hy2_port' "$STATE_FILE")"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 写入 Xray 配置
  local tmp; tmp="$(mktemp)"
  jq --arg uuid "$uuid" \
    '.inbounds[0].settings.clients += [{
       "id": $uuid, "email": $uuid, "flow": "xtls-rprx-vision"
     }]' "$XRAY_CONF/config.json" > "$tmp" && mv "$tmp" "$XRAY_CONF/config.json"

  # 写入 Hysteria2 配置（多密码用 userpass 方式）
  _hy2_add_user "$uuid"

  # 写入 tokens.json
  local tokens; tokens="$(cat "$TOKENS_FILE")"
  tokens="$(echo "$tokens" | jq \
    --arg token "$token" --arg uuid "$uuid" \
    --arg note "$note" --arg created "$now" \
    '. + [{token: $token, uuid: $uuid, note: $note, created: $created}]')"
  echo "$tokens" > "$TOKENS_FILE"
  chmod 640 "$TOKENS_FILE"

  # 重启服务使配置生效
  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null || true
  systemctl restart hysteria2 2>/dev/null || true

  local sub_url="https://${domain}/sub?token=${token}"
  echo ""
  echo -e "  ${GREEN}┌─────────────────────────────────────────────────────┐${RESET}"
  echo -e "  ${GREEN}│  新用户创建成功                                     │${RESET}"
  echo -e "  ${GREEN}├─────────────────────────────────────────────────────┤${RESET}"
  printf   "  ${GREEN}│${RESET}  备注  : %-43s${GREEN}│${RESET}\n" "$note"
  printf   "  ${GREEN}│${RESET}  UUID  : %-43s${GREEN}│${RESET}\n" "$uuid"
  printf   "  ${GREEN}│${RESET}  Token : %-43s${GREEN}│${RESET}\n" "${token:0:20}..."
  echo -e "  ${GREEN}├─────────────────────────────────────────────────────┤${RESET}"
  echo -e "  ${GREEN}│${RESET}  订阅 URL:"
  echo -e "  ${GREEN}│${RESET}  ${BOLD}${sub_url}${RESET}"
  echo -e "  ${GREEN}└─────────────────────────────────────────────────────┘${RESET}"
}

# Hysteria2 多用户：改为 userpass 认证
_hy2_add_user() {
  local uuid="$1"
  # 读取当前所有用户 UUID
  local all_uuids=()
  # 已有的
  while IFS= read -r u; do
    [[ -n "$u" ]] && all_uuids+=("$u")
  done < <(jq -r '.[].uuid' "$TOKENS_FILE" 2>/dev/null || true)
  all_uuids+=("$uuid")

  # 重建 Hysteria2 userpass 配置
  local domain; domain="$(jq -r '.domain' "$STATE_FILE")"
  local hy2_port; hy2_port="$(jq -r '.hy2_port' "$STATE_FILE")"
  local cert_mode; cert_mode="$(jq -r '.cert_mode' "$STATE_FILE")"

  # 构建 userpass 块
  local userpass_block=""
  for u in "${all_uuids[@]}"; do
    userpass_block+="  ${u}: ${u}"$'\n'
  done

  cat > "$HY2_CONF/config.yaml" <<EOF
listen: :${hy2_port}

tls:
  cert: /etc/ssl/vpn/cert.pem
  key:  /etc/ssl/vpn/key.pem

auth:
  type: userpass
  userpass:
${userpass_block}
masquerade:
  type: proxy
  proxy:
    url: https://${domain}
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF
}

# ─── 用户管理菜单 ──────────────────────────────────────────────────────────────
user_menu() {
  while true; do
    clear
    echo -e "${BOLD}=== 用户管理 ===${RESET}"
    hr
    echo "  1) 新建用户"
    echo "  2) 查看所有用户"
    echo "  3) 吊销用户"
    echo "  0) 返回主菜单"
    hr
    read -rp "  请选择 [0-3]: " choice
    case "$choice" in
      1)
        read -rp "  用户备注: " note
        [[ -z "$note" ]] && note="device-$(date +%s)"
        _create_user "$note"
        read -rp "  按回车继续..." _
        ;;
      2) _list_users; read -rp "  按回车继续..." _ ;;
      3) _revoke_user_prompt; read -rp "  按回车继续..." _ ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

_list_users() {
  [[ -f "$TOKENS_FILE" ]] || { warn "tokens.json 不存在"; return; }
  local count; count="$(jq 'length' "$TOKENS_FILE")"
  echo ""
  echo -e "  共 ${BOLD}${count}${RESET} 个用户"
  hr
  printf "  %-20s  %-36s  %-12s  %s\n" "备注" "UUID" "Token(前8)" "创建时间"
  hr
  local i=0
  while [[ $i -lt $count ]]; do
    local entry; entry="$(jq -r ".[$i]" "$TOKENS_FILE")"
    local note;  note="$(echo  "$entry" | jq -r '.note')"
    local uuid;  uuid="$(echo  "$entry" | jq -r '.uuid')"
    local token; token="$(echo "$entry" | jq -r '.token')"
    local ts;    ts="$(echo    "$entry" | jq -r '.created' | cut -c1-10)"
    printf "  %-20s  %-36s  %-12s  %s\n" "$note" "$uuid" "${token:0:8}…" "$ts"
    i=$(( i + 1 ))
  done
}

_revoke_user_prompt() {
  _list_users
  echo ""
  read -rp "  输入要吊销的 Token 前8位（或完整 Token）: " tok_input
  [[ -z "$tok_input" ]] && return

  local found_token found_uuid
  found_token="$(jq -r --arg t "$tok_input" \
    '[.[] | select(.token | startswith($t))] | .[0].token // ""' "$TOKENS_FILE")"
  [[ -z "$found_token" ]] && { warn "未找到匹配的 Token"; return; }

  found_uuid="$(jq -r --arg t "$found_token" \
    '.[] | select(.token == $t) | .uuid' "$TOKENS_FILE")"

  # 从 Xray 删除
  local tmp; tmp="$(mktemp)"
  jq --arg uuid "$found_uuid" \
    '.inbounds[0].settings.clients = [.inbounds[0].settings.clients[] | select(.id != $uuid)]' \
    "$XRAY_CONF/config.json" > "$tmp" && mv "$tmp" "$XRAY_CONF/config.json"

  # 从 tokens.json 删除
  tmp="$(mktemp)"
  jq --arg t "$found_token" '[.[] | select(.token != $t)]' "$TOKENS_FILE" > "$tmp"
  mv "$tmp" "$TOKENS_FILE"
  chmod 640 "$TOKENS_FILE"

  # 重建 Hysteria2 配置（不含该用户）
  local domain; domain="$(jq -r '.domain' "$STATE_FILE")"
  local hy2_port; hy2_port="$(jq -r '.hy2_port' "$STATE_FILE")"
  local userpass_block=""
  while IFS= read -r u; do
    [[ -n "$u" ]] && userpass_block+="  ${u}: ${u}"$'\n'
  done < <(jq -r '.[].uuid' "$TOKENS_FILE" 2>/dev/null || true)

  local cert_mode; cert_mode="$(jq -r '.cert_mode' "$STATE_FILE")"
  cat > "$HY2_CONF/config.yaml" <<EOF
listen: :${hy2_port}

tls:
  cert: /etc/ssl/vpn/cert.pem
  key:  /etc/ssl/vpn/key.pem

auth:
  type: userpass
  userpass:
${userpass_block}
masquerade:
  type: proxy
  proxy:
    url: https://${domain}
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF

  systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null || true
  systemctl restart hysteria2 2>/dev/null || true
  ok "用户已吊销: $found_uuid"
}

# ─── 状态显示 ─────────────────────────────────────────────────────────────────
show_status() {
  clear
  echo -e "${BOLD}=== 服务状态 ===${RESET}"
  hr
  for svc in xray hysteria2 sub-api nginx; do
    local status
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      status="${GREEN}● 运行中${RESET}"
    else
      status="${RED}● 已停止${RESET}"
    fi
    printf "  %-12s %b\n" "$svc" "$status"
  done
  hr
  echo -e "  ${BOLD}端口监听:${RESET}"
  ss -tlnp 2>/dev/null | awk 'NR>1 {printf "  %s\n", $4}' | sort -u
  hr
  read -rp "  按回车返回..." _
}

# ─── 节点信息 ─────────────────────────────────────────────────────────────────
show_node_info() {
  clear
  [[ -f "$STATE_FILE" ]] || { warn "未安装"; read -rp "按回车..." _; return; }

  local domain;    domain="$(jq -r '.domain' "$STATE_FILE")"
  local ip;        ip="$(jq -r '.server_ip' "$STATE_FILE")"
  local xray_port; xray_port="$(jq -r '.xray_port' "$STATE_FILE")"
  local hy2_port;  hy2_port="$(jq -r '.hy2_port' "$STATE_FILE")"
  local pubkey;    pubkey="$(jq -r '.xray_reality_pubkey' "$STATE_FILE")"
  local short_id;  short_id="$(jq -r '.xray_reality_short_id' "$STATE_FILE")"
  local dest;      dest="$(jq -r '.xray_dest' "$STATE_FILE")"

  echo -e "${BOLD}=== 节点参数 ===${RESET}"
  hr
  echo -e "  ${BOLD}Xray VLESS + Reality + uTLS${RESET}"
  echo "  地址        : $domain"
  echo "  端口        : $xray_port"
  echo "  协议        : vless"
  echo "  传输        : tcp"
  echo "  伪装域名    : $dest"
  echo "  PublicKey   : $pubkey"
  echo "  ShortID     : $short_id"
  echo "  Flow        : xtls-rprx-vision"
  echo "  指纹        : chrome"
  hr
  echo -e "  ${BOLD}Hysteria2${RESET}"
  echo "  地址        : $domain"
  echo "  端口        : $hy2_port"
  echo "  密码        : <每个用户的 UUID>"
  echo "  SNI         : $domain"
  hr
  echo -e "  ${BOLD}订阅链接格式${RESET}"
  echo "  https://${domain}/sub?token=<你的token>"
  echo ""
  echo -e "  ${BOLD}所有用户订阅 URL:${RESET}"
  local count; count="$(jq 'length' "$TOKENS_FILE" 2>/dev/null || echo 0)"
  local i=0
  while [[ $i -lt $count ]]; do
    local entry; entry="$(jq -r ".[$i]" "$TOKENS_FILE")"
    local note;  note="$(echo  "$entry" | jq -r '.note')"
    local token; token="$(echo "$entry" | jq -r '.token')"
    echo "  [$note]"
    echo "  https://${domain}/sub?token=${token}"
    echo ""
    i=$(( i + 1 ))
  done
  hr
  read -rp "  按回车返回..." _
}

# ─── 重启服务 ─────────────────────────────────────────────────────────────────
restart_all() {
  log "重启所有服务..."
  for svc in xray hysteria2 sub-api nginx; do
    systemctl restart "$svc" 2>/dev/null \
      && ok "$svc 已重启" \
      || warn "$svc 重启失败"
  done
  read -rp "  按回车返回..." _
}

# ─── 卸载 ─────────────────────────────────────────────────────────────────────
do_uninstall() {
  clear
  echo -e "${RED}${BOLD}=== 卸载 VPN 服务 ===${RESET}"
  hr
  echo -e "  ${RED}警告：此操作将删除所有 VPN 服务、配置和用户数据！${RESET}"
  echo ""
  read -rp "  确认卸载？输入 YES 继续: " confirm
  [[ "$confirm" == "YES" ]] || { log "已取消"; read -rp "按回车..." _; return; }

  log "停止并删除服务..."
  for svc in xray hysteria2 sub-api; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
  done
  systemctl daemon-reload

  log "删除配置和程序..."
  rm -rf "$INSTALL_DIR"
  rm -rf "$XRAY_CONF"
  rm -rf "$HY2_CONF"
  rm -rf "/etc/ssl/vpn"
  rm -f  "$XRAY_DIR/xray"
  rm -f  "/usr/local/bin/hysteria"
  rm -rf "$LOG_DIR"

  # 删除 nginx 站点
  rm -f /etc/nginx/sites-enabled/vpn-sub
  rm -f /etc/nginx/sites-available/vpn-sub
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

  ok "卸载完成"
  read -rp "  按回车退出..." _
  exit 0
}

# ─── 入口 ─────────────────────────────────────────────────────────────────────
need_root

# 修复 /etc/hosts 中可能缺失的 hostname 条目（解决 sudo warning）
local_hostname="$(hostname 2>/dev/null || true)"
if [[ -n "$local_hostname" ]] && ! grep -q "$local_hostname" /etc/hosts 2>/dev/null; then
  echo "127.0.0.1 $local_hostname" >> /etc/hosts
fi

main_menu