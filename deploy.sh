#!/usr/bin/env bash
# =============================================================================
#  VPN 一键部署  —  Hysteria2  &  Xray VLESS+Reality+uTLS
#  支持：有域名（HTTPS订阅）/ 纯IP（HTTP订阅，自签证书）
#  用法: sudo bash vpn-setup.sh
# =============================================================================
if grep -qU $'\r' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"; exec bash "$0" "$@"
fi
set -euo pipefail

# ── 路径常量 ──────────────────────────────────────────────────────────────────
IDIR="/opt/vpn-stack"
XBIN="/usr/local/bin/xray"
HBIN="/usr/local/bin/hysteria"
XCFG="/etc/xray/config.json"
HCFG="/etc/hysteria/config.yaml"
SCFG="$IDIR/sub-api"
SFILE="$IDIR/state.json"
TFILE="$IDIR/tokens.json"
PFILE="$IDIR/params.json"
LDIR="/var/log/vpn-stack"

# ── 颜色 ──────────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'
log()  { echo -e "${C}[*]${N} $*"; }
ok()   { echo -e "${G}[OK]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { echo -e "${R}[ERR]${N} $*" >&2; exit 1; }
hr()   { printf "${C}"; printf '%0.s-' {1..62}; printf "${N}\n"; }
pause(){ read -rp "  按回车继续..." _p; }

need_root(){
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行: sudo bash vpn-setup.sh"
}

get_public_ip(){
  curl -s4 --max-time 6 https://api.ipify.org 2>/dev/null \
  || curl -s4 --max-time 6 https://ip.sb      2>/dev/null \
  || curl -s4 --max-time 6 https://ifconfig.me 2>/dev/null \
  || echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  主菜单
# ═══════════════════════════════════════════════════════════════════════════════
main_menu(){
  while true; do
    clear
    echo -e "${B}${C}"
    echo "  +------------------------------------------+"
    echo "  |       VPN 一键管理面板                   |"
    echo "  |  Hysteria2  +  Xray Reality  +  订阅API  |"
    echo "  +------------------------------------------+"
    echo -e "${N}"

    if [[ -f "$SFILE" ]]; then
      local host mode
      host="$(jq -r '.host' "$SFILE" 2>/dev/null || echo '?')"
      mode="$(jq -r '.mode' "$SFILE" 2>/dev/null || echo '?')"
      echo -e "  ${G}[已安装]${N}  ${B}${host}${N}  (${mode}模式)"
    else
      echo -e "  ${Y}[未安装]${N}"
    fi
    hr
    echo "  1) 安装 / 重新部署"
    echo "  2) 用户管理（新建 / 列表 / 吊销）"
    echo "  3) 查看服务状态"
    echo "  4) 查看节点参数 & 订阅链接"
    echo "  5) 重启所有服务"
    echo "  6) 卸载（彻底删除）"
    echo "  0) 退出"
    hr
    read -rp "  请选择 [0-6]: " _c
    case "$_c" in
      1) do_install   ;;
      2) user_menu    ;;
      3) show_status  ;;
      4) show_info    ;;
      5) svc_restart  ;;
      6) do_uninstall ;;
      0) echo "再见！"; exit 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════════════════════
#  安装向导
# ═══════════════════════════════════════════════════════════════════════════════
do_install(){
  clear
  echo -e "${B}=== 安装向导 ===${N}"; hr

  log "检测公网 IP..."
  local pub_ip
  pub_ip="$(get_public_ip)"
  [[ -n "$pub_ip" ]] && ok "公网 IP: ${B}${pub_ip}${N}" || warn "无法自动检测 IP"

  echo ""
  echo -e "  ${B}选择部署模式:${N}"
  echo "  1) 有域名模式  - HTTPS订阅 + Xray Reality + Hysteria2"
  echo "  2) 纯IP模式    - HTTP订阅  + 仅 Hysteria2（无需域名）"
  echo ""
  read -rp "  选择 [1/2]: " mode_choice

  if [[ "$mode_choice" == "2" ]]; then
    _install_ip_mode "$pub_ip"
  else
    _install_domain_mode "$pub_ip"
  fi
}

# ───────────────────────────────────────────────────────────────────────────────
#  纯 IP 模式
# ───────────────────────────────────────────────────────────────────────────────
_install_ip_mode(){
  local pub_ip="$1"
  clear
  echo -e "${B}=== 纯 IP 模式 ===${N}"; hr
  echo -e "  ${Y}仅部署 Hysteria2，订阅通过 HTTP+IP 访问${N}"; echo ""

  local server_ip hy2_port sub_port
  read -rp "  服务器IP [检测到 ${pub_ip}，回车确认]: " server_ip
  [[ -z "$server_ip" ]] && server_ip="$pub_ip"
  [[ -z "$server_ip" ]] && read -rp "  请手动输入服务器IP: " server_ip
  [[ -z "$server_ip" ]] && die "IP不能为空"

  read -rp "  Hysteria2端口 [回车随机]: " hy2_port
  [[ -z "$hy2_port" ]] && hy2_port=$(( RANDOM % 40000 + 10000 ))

  read -rp "  订阅API端口 [默认8088，需对外开放]: " sub_port
  [[ -z "$sub_port" ]] && sub_port=8088

  echo ""
  echo -e "  ${Y}参数确认:${N}"
  echo "  服务器IP     : $server_ip"
  echo "  Hysteria2端口: $hy2_port"
  echo "  订阅API端口  : $sub_port"
  echo "  订阅URL格式  : http://${server_ip}:${sub_port}/sub?token=<TOKEN>"
  echo ""
  read -rp "  开始安装? [Y/n]: " _yn
  [[ "${_yn,,}" == "n" ]] && return

  hr
  _stop_old_services
  _pkg_install
  _install_hy2_bin
  _gen_self_signed_cert_ip "$server_ip"
  _write_hy2_systemd
  _setup_sub_api_ipmode "$server_ip" "$hy2_port" "$sub_port"
  _setup_nginx ip "$sub_port"
  _save_state_ip "$server_ip" "$hy2_port" "$sub_port"

  # 先重建（空用户）HY2 配置再启动
  _rebuild_hy2_config

  log "启动服务..."
  systemctl enable hysteria2; systemctl restart hysteria2 || true
  systemctl enable sub-api;   systemctl restart sub-api   || true
  systemctl enable nginx;     systemctl restart nginx     || true
  sleep 2

  systemctl is-active --quiet hysteria2 \
    && ok "Hysteria2 运行中" \
    || warn "Hysteria2 异常: journalctl -u hysteria2 -n 30"
  systemctl is-active --quiet sub-api \
    && ok "订阅API 运行中" \
    || warn "订阅API 异常: journalctl -u sub-api -n 30"
  systemctl is-active --quiet nginx \
    && ok "Nginx 运行中" \
    || warn "Nginx 异常: journalctl -u nginx -n 30"

  _check_api_health || true
  _wait_port "$sub_port" "Nginx(订阅)"

  ok "安装完成！"
  echo ""
  read -rp "  用户备注 [默认 my-device]: " _note
  [[ -z "$_note" ]] && _note="my-device"
  create_user "$_note"
  echo ""
  pause
}

# ───────────────────────────────────────────────────────────────────────────────
#  域名模式
# ───────────────────────────────────────────────────────────────────────────────
_install_domain_mode(){
  local pub_ip="$1"
  clear
  echo -e "${B}=== 域名模式 ===${N}"; hr

  local domain xray_port hy2_port dest cert_mode
  read -rp "  域名（已解析到本机）: " domain
  [[ -z "$domain" ]] && die "域名不能为空"

  read -rp "  Xray Reality端口 [回车随机]: " xray_port
  [[ -z "$xray_port" ]] && xray_port=$(( RANDOM % 40000 + 10000 ))

  read -rp "  Hysteria2端口 [回车随机]: " hy2_port
  [[ -z "$hy2_port" ]] && hy2_port=$(( RANDOM % 40000 + 10000 ))
  while [[ "$hy2_port" == "$xray_port" ]]; do
    hy2_port=$(( RANDOM % 40000 + 10000 ))
  done

  read -rp "  Reality伪装域名 [默认 www.apple.com]: " dest
  [[ -z "$dest" ]] && dest="www.apple.com"

  echo "  证书: 1) Let's Encrypt  2) 自签名"
  read -rp "  选择 [1/2，默认1]: " cert_mode
  [[ -z "$cert_mode" ]] && cert_mode=1

  echo ""
  echo -e "  ${Y}参数确认:${N}"
  echo "  域名         : $domain"
  echo "  Xray端口     : $xray_port"
  echo "  HY2端口      : $hy2_port"
  echo "  伪装域名     : $dest"
  echo "  证书         : $([ "$cert_mode" = "1" ] && echo "Let's Encrypt" || echo "自签名")"
  echo ""
  read -rp "  开始安装? [Y/n]: " _yn
  [[ "${_yn,,}" == "n" ]] && return

  hr
  _stop_old_services
  _pkg_install
  _install_xray_bin
  _install_hy2_bin
  _setup_certs "$domain" "$cert_mode"
  _write_xray_config "$domain" "$xray_port" "$dest"
  _write_hy2_systemd
  _setup_sub_api_domain "$domain" "$xray_port" "$hy2_port" "$cert_mode"
  _setup_nginx domain "$domain"
  _save_state_domain "$domain" "$pub_ip" "$xray_port" "$hy2_port" "$dest" "$cert_mode"

  _rebuild_hy2_config

  log "启动服务..."
  for svc in xray hysteria2 sub-api nginx; do
    systemctl enable "$svc"
    systemctl restart "$svc" || true
  done
  sleep 2

  for svc in xray hysteria2 sub-api nginx; do
    systemctl is-active --quiet "$svc" \
      && ok "$svc 运行中" \
      || warn "$svc 异常: journalctl -u $svc -n 20"
  done

  _check_api_health || true

  ok "安装完成！"
  echo ""
  read -rp "  用户备注 [默认 my-device]: " _note
  [[ -z "$_note" ]] && _note="my-device"
  create_user "$_note"
  echo ""
  pause
}

# ═══════════════════════════════════════════════════════════════════════════════
#  通用安装函数
# ═══════════════════════════════════════════════════════════════════════════════

_stop_old_services(){
  log "清理旧服务..."
  for svc in xray hysteria2 sub-api nginx; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done
  for p in 8080 8088; do
    local pids
    pids="$(ss -tlnp 2>/dev/null | awk -v port=":${p} " '
      $0 ~ port { match($0, /pid=([0-9]+)/, a); if (a[1]) print a[1] }')" || true
    [[ -n "$pids" ]] && echo "$pids" | xargs -r kill -9 2>/dev/null || true
  done
  [[ -d "$SCFG/venv" ]] && rm -rf "$SCFG/venv" || true
  ok "旧服务已清理"
}

_pkg_install(){
  log "安装依赖包..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq 2>&1 | tail -1
  apt-get install -y -qq \
    curl wget unzip jq openssl uuid-runtime \
    python3 python3-venv python3-pip \
    iproute2 2>&1 | tail -1
  command -v nginx   >/dev/null 2>&1 || apt-get install -y -qq nginx 2>&1 | tail -1
  command -v certbot >/dev/null 2>&1 || apt-get install -y -qq certbot python3-certbot-nginx 2>&1 | tail -1
  ok "依赖安装完成"
}

_install_xray_bin(){
  log "下载 Xray..."
  local ver arch url tmpd
  ver="$(curl -sL --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
         | jq -r '.tag_name' 2>/dev/null || echo "v25.3.6")"
  case "$(uname -m)" in
    x86_64)  arch="64"        ;;
    aarch64) arch="arm64-v8a" ;;
    *)       arch="64"        ;;
  esac
  url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${arch}.zip"
  tmpd="$(mktemp -d)"
  curl -sL --max-time 60 "$url" -o "$tmpd/xray.zip" || die "Xray 下载失败"
  unzip -q "$tmpd/xray.zip" -d "$tmpd/x"
  install -m0755 "$tmpd/x/xray" "$XBIN"
  rm -rf "$tmpd"
  mkdir -p /etc/xray
  curl -sL --max-time 30 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" \
    -o /etc/xray/geoip.dat   2>/dev/null || true
  curl -sL --max-time 30 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
    -o /etc/xray/geosite.dat 2>/dev/null || true
  ok "Xray ${ver} 安装完成"
}

_install_hy2_bin(){
  log "下载 Hysteria2..."
  local ver arch url
  ver="$(curl -sL --max-time 10 https://api.github.com/repos/apernet/hysteria/releases/latest \
         | jq -r '.tag_name' 2>/dev/null || echo "app/v2.6.1")"
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)       arch="amd64" ;;
  esac
  url="https://github.com/apernet/hysteria/releases/download/${ver}/hysteria-linux-${arch}"
  curl -sL --max-time 60 "$url" -o "$HBIN" || die "Hysteria2 下载失败"
  chmod +x "$HBIN"
  ok "Hysteria2 ${ver#app/} 安装完成"
}

# ── 证书 ──────────────────────────────────────────────────────────────────────
_gen_self_signed_cert_ip(){
  local ip="$1"
  mkdir -p /etc/ssl/vpn
  log "生成自签名证书 (IP=${ip})..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout /etc/ssl/vpn/key.pem \
    -out    /etc/ssl/vpn/cert.pem \
    -days 3650 -nodes \
    -subj "/CN=${ip}" \
    -addext "subjectAltName=IP:${ip}" \
    2>/dev/null
  chmod 644 /etc/ssl/vpn/cert.pem
  chmod 600 /etc/ssl/vpn/key.pem
  ok "自签名证书生成完成"
}

_gen_self_signed_cert_domain(){
  local domain="$1"
  mkdir -p /etc/ssl/vpn
  log "生成自签名证书 (domain=${domain})..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout /etc/ssl/vpn/key.pem \
    -out    /etc/ssl/vpn/cert.pem \
    -days 3650 -nodes \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain}" \
    2>/dev/null
  chmod 644 /etc/ssl/vpn/cert.pem
  chmod 600 /etc/ssl/vpn/key.pem
  ok "自签名证书生成完成"
}

_setup_certs(){
  local domain="$1" mode="$2"
  if [[ "$mode" == "1" ]]; then
    systemctl start nginx 2>/dev/null || true
    log "申请 Let's Encrypt 证书..."
    certbot certonly --nginx -d "$domain" \
      --non-interactive --agree-tos \
      --register-unsafely-without-email -q && {
        mkdir -p /etc/ssl/vpn
        ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" /etc/ssl/vpn/cert.pem
        ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem"   /etc/ssl/vpn/key.pem
        ok "Let's Encrypt 证书就绪"
        return
      } || warn "LE 证书失败，改用自签名"
  fi
  _gen_self_signed_cert_domain "$domain"
}

# ── Hysteria2 systemd（配置文件由 _rebuild_hy2_config 写入）─────────────────
_write_hy2_systemd(){
  mkdir -p /etc/hysteria
  cat > /etc/systemd/system/hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=${HBIN} server -c ${HCFG}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# ── Xray 配置 ─────────────────────────────────────────────────────────────────
_write_xray_config(){
  local domain="$1" port="$2" dest="$3"
  mkdir -p /etc/xray "$LDIR" "$IDIR"
  log "生成 Reality 密钥对..."
  local kp privkey pubkey short_id
  kp="$($XBIN x25519 2>/dev/null)"
  privkey="$(echo "$kp" | awk '/Private/{print $3}')"
  pubkey="$(echo  "$kp" | awk '/Public/{print $3}')"
  short_id="$(openssl rand -hex 4)"
  ok "pubkey = ${pubkey:0:24}..."

  jq -n \
    --arg priv "$privkey" --arg pub "$pubkey" \
    --arg sid "$short_id" --arg dest "$dest" \
    --argjson port "$port" \
    '{xray_privkey:$priv, xray_pubkey:$pub, xray_short_id:$sid,
      xray_dest:$dest, xray_port:$port}' > "$IDIR/xray-keys.json"

  cat > "$XCFG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LDIR}/xray.log",
    "error":  "${LDIR}/xray-err.log"
  },
  "inbounds": [{
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
  }],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block",  "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]
  }
}
EOF
  cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Server
After=network.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "Xray Reality 配置完成"
}

# ── 重建 Hysteria2 配置（每次用户变动后调用）────────────────────────────────
_rebuild_hy2_config(){
  [[ -f "$SFILE" ]] || return 0
  local mode hy2_port host
  mode="$(jq -r '.mode' "$SFILE")"
  hy2_port="$(jq -r '.hy2_port' "$SFILE")"
  host="$(jq -r '.host' "$SFILE")"

  # 构建 userpass 块（每个用户 uuid: uuid）
  local userpass_block=""
  while IFS= read -r uuid; do
    [[ -z "$uuid" || "$uuid" == "null" ]] && continue
    userpass_block+="    ${uuid}: ${uuid}"$'\n'
  done < <(jq -r '.[].uuid' "$TFILE" 2>/dev/null || true)

  local masquerade_block
  if [[ "$mode" == "ip" ]]; then
    masquerade_block='masquerade:
  type: string
  string:
    content: "OK"'
  else
    masquerade_block="masquerade:
  type: proxy
  proxy:
    url: https://${host}
    rewriteHost: true"
  fi

  mkdir -p /etc/hysteria
  cat > "$HCFG" <<EOF
listen: :${hy2_port}

tls:
  cert: /etc/ssl/vpn/cert.pem
  key:  /etc/ssl/vpn/key.pem

auth:
  type: userpass
  userpass:
${userpass_block}
${masquerade_block}

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

# ── 订阅 API（IP 模式）────────────────────────────────────────────────────────
_setup_sub_api_ipmode(){
  local ip="$1" hy2_port="$2" sub_port="$3"
  log "部署订阅 API (端口 ${sub_port})..."
  mkdir -p "$SCFG" "$IDIR"
  [[ -f "$TFILE" ]] || echo '[]' > "$TFILE"

  jq -n \
    --arg host "$ip" --arg mode "ip" \
    --argjson hy2_port "$hy2_port" \
    --argjson sub_port "$sub_port" \
    '{host:$host, mode:$mode, hy2_port:$hy2_port,
      sub_port:$sub_port, skip_tls:true, xray_enabled:false}' > "$PFILE"

  _write_app_py
  python3 -m venv "$SCFG/venv"
  "$SCFG/venv/bin/pip" install flask gunicorn --quiet

  cat > /etc/systemd/system/sub-api.service <<EOF
[Unit]
Description=VPN Subscription API
After=network.target

[Service]
WorkingDirectory=${SCFG}
Environment=PFILE=${PFILE}
Environment=TFILE=${TFILE}
ExecStart=${SCFG}/venv/bin/gunicorn --bind 127.0.0.1:8080 --workers 2 --timeout 30 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "订阅 API 配置完成"
}

# ── 订阅 API（域名模式）──────────────────────────────────────────────────────
_setup_sub_api_domain(){
  local domain="$1" xray_port="$2" hy2_port="$3" cert_mode="$4"
  log "部署订阅 API (域名模式)..."
  mkdir -p "$SCFG" "$IDIR"
  [[ -f "$TFILE" ]] || echo '[]' > "$TFILE"

  local xkeys="{}"
  [[ -f "$IDIR/xray-keys.json" ]] && xkeys="$(cat "$IDIR/xray-keys.json")"

  # cert_mode 是字符串，skip_tls 当 cert_mode != "1" 时为 true
  local skip_tls
  [[ "$cert_mode" == "1" ]] && skip_tls="false" || skip_tls="true"

  jq -n \
    --arg host "$domain" --arg mode "domain" \
    --argjson xray_port "$xray_port" \
    --argjson hy2_port "$hy2_port" \
    --argjson skip_tls "$skip_tls" \
    --argjson xkeys "$xkeys" \
    '{host:$host, mode:$mode, xray_port:$xray_port,
      hy2_port:$hy2_port, skip_tls:$skip_tls,
      xray_enabled:true} + $xkeys' > "$PFILE"

  _write_app_py
  python3 -m venv "$SCFG/venv"
  "$SCFG/venv/bin/pip" install flask gunicorn --quiet

  cat > /etc/systemd/system/sub-api.service <<EOF
[Unit]
Description=VPN Subscription API
After=network.target

[Service]
WorkingDirectory=${SCFG}
Environment=PFILE=${PFILE}
Environment=TFILE=${TFILE}
ExecStart=${SCFG}/venv/bin/gunicorn --bind 127.0.0.1:8080 --workers 2 --timeout 30 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "订阅 API 配置完成"
}

# ── app.py ────────────────────────────────────────────────────────────────────
_write_app_py(){
cat > "$SCFG/app.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, time
from pathlib import Path
from flask import Flask, request, Response, abort

PFILE = Path(os.environ.get("PFILE", "/opt/vpn-stack/params.json"))
TFILE = Path(os.environ.get("TFILE", "/opt/vpn-stack/tokens.json"))
app   = Flask(__name__)

def load_params():
    return json.loads(PFILE.read_text())

def load_tokens():
    try:    return json.loads(TFILE.read_text())
    except: return []

def find_token(tok):
    for t in load_tokens():
        if t.get("token") == tok:
            return t
    return None

def build_yaml(p, entry):
    host       = p["host"]
    uuid       = entry["uuid"]
    hy2_port   = p.get("hy2_port", 8443)
    skip_tls   = p.get("skip_tls", False)
    xray_en    = p.get("xray_enabled", False)

    # 固定展示名（与 Clash Verge 参考配置一致，不随用户备注变化）
    NAME_H2 = "🚀 Hysteria2 极速"
    NAME_VLESS = "🌐 VLESS Reality"
    GROUP_MANUAL = "🔧 手动选择"
    GROUP_MEDIA = "📺 流媒体"

    hy2_block = (
        f"  - name: {NAME_H2}\n"
        f"    type: hysteria2\n"
        f"    server: {host}\n"
        f"    port: {hy2_port}\n"
        f"    password: {uuid}\n"
        f"    sni: {host}\n"
        f"    skip-cert-verify: {'true' if skip_tls else 'false'}\n"
        f"    udp: true\n"
        f"    alpn:\n"
        f"      - h3"
    )

    proxy_blocks = [hy2_block]
    proxy_names  = [NAME_H2]

    if xray_en:
        xray_port = p.get("xray_port", 443)
        pubkey    = p.get("xray_pubkey",   "")
        short_id  = p.get("xray_short_id", "")
        dest      = p.get("xray_dest", "www.apple.com")
        vless_block = (
            f"  - name: {NAME_VLESS}\n"
            f"    type: vless\n"
            f"    server: {host}\n"
            f"    port: {xray_port}\n"
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
        proxy_blocks.append(vless_block)
        proxy_names.append(NAME_VLESS)

    proxies_yaml = "\n\n".join(proxy_blocks)
    names_yaml = "\n".join(f"      - {n}" for n in proxy_names)

    return (
        f"proxies:\n{proxies_yaml}\n\n"
        f"proxy-groups:\n"
        f"  - name: {GROUP_MANUAL}\n"
        f"    type: select\n"
        f"    proxies:\n{names_yaml}\n"
        f"      - DIRECT\n\n"
        f"  - name: {GROUP_MEDIA}\n"
        f"    type: select\n"
        f"    proxies:\n{names_yaml}\n"
        f"      - DIRECT\n\n"
        f"dns:\n"
        f"  enable: true\n"
        f"  listen: 0.0.0.0:1053\n"
        f"  enhanced-mode: fake-ip\n"
        f"  fake-ip-range: 198.18.0.1/16\n"
        f"  nameserver:\n"
        f"    - https://doh.pub/dns-query\n"
        f"    - https://dns.alidns.com/dns-query\n"
        f"  fallback:\n"
        f"    - https://1.1.1.1/dns-query\n"
        f"    - https://dns.google/dns-query\n"
        f"  fallback-filter:\n"
        f"    geoip: true\n"
        f"    geoip-code: CN\n"
        f"    ipcidr:\n"
        f"      - 240.0.0.0/4\n"
        f"  default-nameserver:\n"
        f"    - 223.5.5.5\n"
        f"    - 119.29.29.29\n\n"
        f"rules:\n"
        f"  - DOMAIN-SUFFIX,localhost,DIRECT\n"
        f"  - IP-CIDR,127.0.0.0/8,DIRECT\n"
        f"  - IP-CIDR,192.168.0.0/16,DIRECT\n"
        f"  - IP-CIDR,10.0.0.0/8,DIRECT\n"
        f"  - DOMAIN-SUFFIX,netflix.com,{GROUP_MEDIA}\n"
        f"  - DOMAIN-SUFFIX,nflxvideo.net,{GROUP_MEDIA}\n"
        f"  - DOMAIN-SUFFIX,youtube.com,{GROUP_MEDIA}\n"
        f"  - DOMAIN-SUFFIX,googlevideo.com,{GROUP_MEDIA}\n"
        f"  - DOMAIN-SUFFIX,spotify.com,{GROUP_MEDIA}\n"
        f"  - DOMAIN-SUFFIX,twitch.tv,{GROUP_MEDIA}\n"
        f"  - DOMAIN-SUFFIX,tiktok.com,{GROUP_MEDIA}\n"
        f"  - DOMAIN-SUFFIX,instagram.com,{GROUP_MEDIA}\n"
        f"  - DOMAIN-SUFFIX,baidu.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,qq.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,wechat.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,weixin.qq.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,bilibili.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,taobao.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,jd.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,alicdn.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,alipay.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,163.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,126.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,zhihu.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,csdn.net,DIRECT\n"
        f"  - DOMAIN-SUFFIX,douyin.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,weibo.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,youku.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,iqiyi.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,mi.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,huawei.com,DIRECT\n"
        f"  - DOMAIN-SUFFIX,bytedance.com,DIRECT\n"
        f"  - GEOIP,CN,DIRECT\n"
        f"  - MATCH,{NAME_H2}\n"
    )

@app.get("/sub")
def sub():
    tok = request.args.get("token", "")
    if not tok:
        abort(403)
    entry = find_token(tok)
    if not entry:
        abort(403)
    p    = load_params()
    yaml = build_yaml(p, entry)
    fn   = "clash-" + entry.get("note", "sub").replace(" ", "-") + ".yaml"
    return Response(
        yaml,
        mimetype="text/plain; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{fn}"'}
    )

@app.get("/health")
def health():
    return {"ok": True, "ts": int(time.time())}

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
PYEOF
}

# ── Nginx：domain = 监听 80 反代 8080；ip = 监听 sub_port 反代 8080 ────────────
_setup_nginx(){
  local mode="${1:?}"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html
  if ! grep -q 'sites-enabled' /etc/nginx/nginx.conf 2>/dev/null; then
    sed -i '/http {/a\\tinclude /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
  fi
  rm -f /etc/nginx/sites-enabled/default

  if [[ "$mode" == "domain" ]]; then
    local domain="$2"
    [[ -n "$domain" ]] || die "Nginx domain 模式需要域名参数"
    log "配置 Nginx (域名 ${domain} → 127.0.0.1:8080)..."
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
    location /health { proxy_pass http://127.0.0.1:8080; }
    location / { return 444; }
}
EOF
  elif [[ "$mode" == "ip" ]]; then
    local sub_port="$2"
    [[ -n "$sub_port" ]] || die "Nginx ip 模式需要订阅端口参数"
    log "配置 Nginx (监听 ${sub_port} → 127.0.0.1:8080)..."
    cat > /etc/nginx/sites-available/vpn-sub <<EOF
server {
    listen ${sub_port};
    listen [::]:${sub_port};
    server_name _;
    root /var/www/html;
    location /sub {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
    }
    location /health { proxy_pass http://127.0.0.1:8080; }
    location / { return 444; }
}
EOF
  else
    die "未知 Nginx 模式: ${mode}（使用 domain 或 ip）"
  fi

  ln -sf /etc/nginx/sites-available/vpn-sub /etc/nginx/sites-enabled/vpn-sub
  nginx -t && systemctl enable nginx && systemctl restart nginx
  ok "Nginx 配置完成"
}

# ── 订阅 API 健康检查（gunicorn 监听 127.0.0.1:8080）────────────────────────
_check_api_health(){
  local i
  log "检查订阅 API (GET http://127.0.0.1:8080/health)..."
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf --max-time 3 http://127.0.0.1:8080/health >/dev/null 2>&1; then
      ok "订阅 API 健康检查通过"
      return 0
    fi
    sleep 1
  done
  warn "订阅 API 健康检查失败: curl http://127.0.0.1:8080/health"
  warn "sub-api 最近日志:"
  journalctl -u sub-api -n 30 --no-pager 2>/dev/null || true
  return 1
}

# ── 保存状态 ──────────────────────────────────────────────────────────────────
_save_state_ip(){
  local ip="$1" hy2_port="$2" sub_port="$3"
  mkdir -p "$IDIR"
  jq -n \
    --arg host "$ip" --arg mode "ip" \
    --argjson hy2_port "$hy2_port" \
    --argjson sub_port "$sub_port" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{host:$host, mode:$mode, hy2_port:$hy2_port, sub_port:$sub_port, installed_at:$ts}' \
    > "$SFILE"
  cp "$PFILE" "$SFILE.pfile.bak" 2>/dev/null || true
}

_save_state_domain(){
  local domain="$1" ip="$2" xray_port="$3" hy2_port="$4" dest="$5" cert_mode="$6"
  mkdir -p "$IDIR"
  jq -n \
    --arg host "$domain" --arg mode "domain" --arg ip "$ip" \
    --argjson xray_port "$xray_port" \
    --argjson hy2_port "$hy2_port" \
    --arg dest "$dest" --arg cert_mode "$cert_mode" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{host:$host, mode:$mode, server_ip:$ip, xray_port:$xray_port,
      hy2_port:$hy2_port, xray_dest:$dest, cert_mode:$cert_mode, installed_at:$ts}' \
    > "$SFILE"
}

_wait_port(){
  local port="$1" label="${2:-port}"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ss -tlnp 2>/dev/null | grep -q ":${port} " && { ok "${label} 端口 ${port} 就绪"; return 0; }
    ss -ulnp 2>/dev/null | grep -q ":${port} " && { ok "${label} 端口 ${port} 就绪(UDP)"; return 0; }
    sleep 1
  done
  warn "${label} 端口 ${port} 未检测到，请查看日志"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  用户管理
# ═══════════════════════════════════════════════════════════════════════════════
create_user(){
  local note="${1:-device}"
  [[ -f "$SFILE" ]] || { warn "未安装，请先安装"; return 1; }

  local uuid; uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  local token; token="$(openssl rand -hex 24)"
  local now;   now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 追加到 tokens.json
  local tokens; tokens="$(cat "$TFILE")"
  tokens="$(echo "$tokens" | jq \
    --arg tok "$token" --arg uuid "$uuid" \
    --arg note "$note" --arg ts "$now" \
    '. + [{token:$tok, uuid:$uuid, note:$note, created:$ts}]')"
  echo "$tokens" > "$TFILE"
  chmod 640 "$TFILE"

  # Xray（域名模式）
  local mode; mode="$(jq -r '.mode' "$SFILE")"
  if [[ "$mode" == "domain" && -f "$XCFG" ]]; then
    local tmp; tmp="$(mktemp)"
    jq --arg uuid "$uuid" \
      '.inbounds[0].settings.clients += [{"id":$uuid,"email":$uuid,"flow":"xtls-rprx-vision"}]' \
      "$XCFG" > "$tmp" && mv "$tmp" "$XCFG"
    systemctl reload xray 2>/dev/null || systemctl restart xray 2>/dev/null || true
  fi

  # Hysteria2 — 重建配置并重启
  _rebuild_hy2_config
  systemctl restart hysteria2 || true
  sleep 1
  systemctl is-active --quiet hysteria2 || warn "Hysteria2 重启后异常，查看: journalctl -u hysteria2 -n 20"

  # 构造订阅 URL
  local host sub_url
  host="$(jq -r '.host' "$SFILE")"
  if [[ "$mode" == "ip" ]]; then
    local sub_port; sub_port="$(jq -r '.sub_port' "$SFILE")"
    sub_url="http://${host}:${sub_port}/sub?token=${token}"
  else
    sub_url="https://${host}/sub?token=${token}"
  fi

  echo ""
  echo -e "  ${G}+------------------------------------------------------+${N}"
  echo -e "  ${G}|  新用户创建成功                                      |${N}"
  echo -e "  ${G}+------------------------------------------------------+${N}"
  printf   "  ${G}|${N}  备注  : %-46s${G}|${N}\n" "$note"
  printf   "  ${G}|${N}  UUID  : %-46s${G}|${N}\n" "$uuid"
  echo -e "  ${G}+------------------------------------------------------+${N}"
  echo -e "  ${G}|${N}  订阅 URL (填入 Clash Verge / Meta):"
  echo -e "  ${G}|${N}  ${B}${sub_url}${N}"
  echo -e "  ${G}+------------------------------------------------------+${N}"
}

user_menu(){
  while true; do
    clear
    echo -e "${B}=== 用户管理 ===${N}"; hr
    echo "  1) 新建用户"
    echo "  2) 查看所有用户 & 订阅 URL"
    echo "  3) 吊销用户"
    echo "  0) 返回"
    hr
    read -rp "  请选择 [0-3]: " _c
    case "$_c" in
      1) read -rp "  用户备注: " _n
         [[ -z "$_n" ]] && _n="device-$(date +%s)"
         create_user "$_n"; pause ;;
      2) list_users; pause ;;
      3) revoke_user; pause ;;
      0) return ;;
      *) warn "无效"; sleep 1 ;;
    esac
  done
}

list_users(){
  [[ -f "$TFILE" && -f "$SFILE" ]] || { warn "未安装或无用户"; return; }
  local mode host sub_port
  mode="$(jq -r '.mode' "$SFILE")"
  host="$(jq -r '.host' "$SFILE")"
  [[ "$mode" == "ip" ]] && sub_port="$(jq -r '.sub_port' "$SFILE")" || sub_port=""

  local count; count="$(jq 'length' "$TFILE")"
  echo ""; echo -e "  共 ${B}${count}${N} 个用户"; hr

  local i=0
  while [[ $i -lt $count ]]; do
    local e note token uuid created url
    e="$(jq  -r ".[$i]" "$TFILE")"
    note="$(echo    "$e" | jq -r '.note')"
    token="$(echo   "$e" | jq -r '.token')"
    uuid="$(echo    "$e" | jq -r '.uuid')"
    created="$(echo "$e" | jq -r '.created' | cut -c1-10)"
    if [[ "$mode" == "ip" ]]; then
      url="http://${host}:${sub_port}/sub?token=${token}"
    else
      url="https://${host}/sub?token=${token}"
    fi
    echo -e "  ${B}[$((i+1))] ${note}${N}  ${created}"
    echo    "       UUID  : $uuid"
    echo    "       Token : ${token:0:16}..."
    echo -e "       ${G}URL   : ${url}${N}"
    echo ""
    i=$(( i + 1 ))
  done
}

revoke_user(){
  list_users
  read -rp "  输入序号或 Token 前12位: " _in
  [[ -z "$_in" ]] && return

  local found_token=""
  if [[ "$_in" =~ ^[0-9]+$ ]]; then
    local idx=$(( _in - 1 ))
    found_token="$(jq -r ".[$idx].token // empty" "$TFILE")"
  else
    found_token="$(jq -r --arg t "$_in" \
      '[.[] | select(.token | startswith($t))] | .[0].token // empty' "$TFILE")"
  fi
  [[ -z "$found_token" ]] && { warn "未找到用户"; return; }

  local found_uuid
  found_uuid="$(jq -r --arg t "$found_token" '.[] | select(.token==$t) | .uuid' "$TFILE")"

  local tmp; tmp="$(mktemp)"
  jq --arg t "$found_token" '[.[] | select(.token != $t)]' "$TFILE" > "$tmp"
  mv "$tmp" "$TFILE"; chmod 640 "$TFILE"

  if [[ -f "$XCFG" ]]; then
    tmp="$(mktemp)"
    jq --arg uuid "$found_uuid" \
      '.inbounds[0].settings.clients = [.inbounds[0].settings.clients[] | select(.id != $uuid)]' \
      "$XCFG" > "$tmp" && mv "$tmp" "$XCFG"
    systemctl reload xray 2>/dev/null || true
  fi

  _rebuild_hy2_config
  systemctl restart hysteria2 || true
  ok "已吊销: ${found_uuid:0:8}..."
}

# ═══════════════════════════════════════════════════════════════════════════════
#  状态 / 信息 / 重启
# ═══════════════════════════════════════════════════════════════════════════════
show_status(){
  clear; echo -e "${B}=== 服务状态 ===${N}"; hr
  for svc in xray hysteria2 sub-api nginx; do
    local st
    systemctl is-active --quiet "$svc" 2>/dev/null \
      && st="${G}[运行中]${N}" || st="${R}[已停止]${N}"
    printf "  %-12s %b\n" "$svc" "$st"
  done
  hr
  echo -e "  ${B}TCP 端口:${N}"
  ss -tlnp 2>/dev/null | awk 'NR>1 && $4!=""{printf "    %s\n",$4}' | sort | uniq
  echo -e "  ${B}UDP 端口:${N}"
  ss -ulnp 2>/dev/null | awk 'NR>1 && $4!=""{printf "    %s\n",$4}' | sort | uniq
  hr; pause
}

show_info(){
  clear; echo -e "${B}=== 节点参数 ===${N}"; hr
  [[ -f "$SFILE" ]] || { warn "未安装"; pause; return; }

  local mode host
  mode="$(jq -r '.mode' "$SFILE")"
  host="$(jq -r '.host' "$SFILE")"

  if [[ "$mode" == "ip" ]]; then
    local hy2_port sub_port
    hy2_port="$(jq -r '.hy2_port' "$SFILE")"
    sub_port="$(jq  -r '.sub_port' "$SFILE")"
    echo -e "  ${B}Hysteria2 (纯IP模式)${N}"
    echo "  服务器          : $host"
    echo "  端口            : $hy2_port (UDP/QUIC)"
    echo "  密码            : <用户UUID>"
    echo "  SNI             : $host"
    echo "  skip-cert-verify: true"
    hr
    echo -e "  ${B}订阅URL格式:${N}"
    echo "  http://${host}:${sub_port}/sub?token=<TOKEN>"
  else
    local xray_port hy2_port
    xray_port="$(jq -r '.xray_port' "$SFILE")"
    hy2_port="$(jq  -r '.hy2_port'  "$SFILE")"
    local pubkey short_id dest
    pubkey="$(jq   -r '.xray_pubkey'   "$PFILE" 2>/dev/null || echo N/A)"
    short_id="$(jq -r '.xray_short_id' "$PFILE" 2>/dev/null || echo N/A)"
    dest="$(jq     -r '.xray_dest'     "$PFILE" 2>/dev/null || echo N/A)"

    echo -e "  ${B}Xray VLESS + Reality + uTLS (chrome)${N}"
    echo "  地址      : $host"
    echo "  端口      : $xray_port (TCP)"
    echo "  流控      : xtls-rprx-vision"
    echo "  伪装域名  : $dest"
    echo "  PublicKey : $pubkey"
    echo "  ShortID   : $short_id"
    hr
    echo -e "  ${B}Hysteria2${N}"
    echo "  地址      : $host"
    echo "  端口      : $hy2_port (UDP/QUIC)"
    echo "  密码      : <用户UUID>"
    hr
    echo -e "  ${B}订阅URL格式:${N}"
    echo "  https://${host}/sub?token=<TOKEN>"
  fi

  hr
  echo -e "  ${B}所有用户:${N}"
  list_users
  pause
}

svc_restart(){
  log "重启所有服务..."
  for svc in xray hysteria2 sub-api nginx; do
    systemctl restart "$svc" 2>/dev/null \
      && ok "$svc 已重启" || warn "$svc 重启失败"
  done
  pause
}

# ═══════════════════════════════════════════════════════════════════════════════
#  卸载
# ═══════════════════════════════════════════════════════════════════════════════
do_uninstall(){
  clear; echo -e "${R}${B}=== 卸载 ===${N}"; hr
  echo -e "  ${R}警告：将删除所有服务、配置、证书、用户数据！${N}"; echo ""
  read -rp "  确认卸载？输入大写 YES: " _yn
  [[ "$_yn" == "YES" ]] || { log "取消"; pause; return; }

  for svc in xray hysteria2 sub-api; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
  done
  systemctl daemon-reload

  rm -f  "$XBIN" "$HBIN"
  rm -rf /etc/xray /etc/hysteria /etc/ssl/vpn
  rm -rf "$IDIR" "$LDIR"

  rm -f /etc/nginx/sites-enabled/vpn-sub
  rm -f /etc/nginx/sites-available/vpn-sub
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

  ok "卸载完成，所有数据已清除"
  pause; exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
#  入口
# ═══════════════════════════════════════════════════════════════════════════════
need_root

# 修复 sudo hostname 警告
_hn="$(hostname 2>/dev/null || true)"
if [[ -n "$_hn" ]] && ! grep -qw "$_hn" /etc/hosts 2>/dev/null; then
  echo "127.0.0.1 $_hn" >> /etc/hosts
fi

main_menu