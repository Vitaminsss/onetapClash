#!/usr/bin/env bash
# =============================================================================
# clash-sub-api  ·  一键部署脚本  ·  完全自包含版本
# 用法: sudo bash deploy.sh <your.domain.com>
#       CERTBOT_EMAIL=you@example.com sudo bash deploy.sh <your.domain.com>
# =============================================================================
# 功能:
#   1. 自动探测 Xray / sing-box 配置（单文件 & 分片目录）
#   2. 提取 VLESS+REALITY / VLESS+TLS / Hysteria2 参数生成 server.json
#   3. 注入 Xray stats + api + routing rule（幂等）
#   4. 部署 Flask 订阅 API（app.py 内联生成）
#   5. 配置 Nginx + Let's Encrypt HTTPS
#   6. 安装 vpn CLI（内联生成，无外部依赖）
#   7. 创建首个订阅用户
# =============================================================================

# CRLF 自修复
if grep -qU $'\r' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"; exec bash "$0" "$@"
fi

set -euo pipefail
IFS=$'\n\t'

# ─── 全局常量 ─────────────────────────────────────────────────────────────────
SUB_ROOT="/opt/sub-api"
ENV_FILE="$SUB_ROOT/sub-api.env"
SERVER_JSON="$SUB_ROOT/server.json"
TOKENS_JSON="$SUB_ROOT/tokens.json"
XRAY_API_PORT="${XRAY_API_PORT:-10085}"
XRAY_API_TAG="api"

# ─── 工具函数 ─────────────────────────────────────────────────────────────────
log()  { echo -e "\033[36m[deploy]\033[0m $*" >&2; }
ok()   { echo -e "\033[32m[  OK  ]\033[0m $*" >&2; }
warn() { echo -e "\033[33m[ WARN ]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[ ERR  ]\033[0m $*" >&2; exit 1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行: sudo bash deploy.sh <域名>"
}

require_domain() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || die "用法: sudo bash deploy.sh <your.domain.com>
可选: CERTBOT_EMAIL=you@example.com sudo bash deploy.sh <your.domain.com>"
  # 基本格式验证
  # 基本格式验证（含多级子域名）
  [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] \
    || warn "域名格式疑似不对，请确认: $domain"
  echo "$domain"
}

# ─── 1. 依赖安装 ──────────────────────────────────────────────────────────────
install_packages() {
  log "安装依赖包…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq
  apt-get install -y -qq \
    python3 python3-venv python3-pip \
    jq curl wget nginx \
    certbot python3-certbot-nginx \
    openssl uuid-runtime \
    2>&1 | tail -5
  ok "依赖安装完成"
}

# ─── 2. 探测 Xray / sing-box 配置路径 ────────────────────────────────────────
# 返回格式: "xray_path|singbox_path"  （路径可为空）
discover_configs() {
  local xray_path="" sing_path=""

  # Xray: 优先单文件，再找分片目录
  local xray_candidates=(
    /usr/local/etc/xray/config.json
    /etc/xray/config.json
    /etc/v2ray-agent/xray/conf/config.json
    /etc/v2ray-agent/xray/config.json
  )
  local xray_dir_candidates=(
    /etc/v2ray-agent/xray/conf
    /usr/local/etc/xray/conf
    /usr/local/etc/xray
  )

  for c in "${xray_candidates[@]}"; do
    if [[ -f "$c" ]] && jq -e '.inbounds // .outbounds' "$c" >/dev/null 2>&1; then
      xray_path="$c"; break
    fi
  done
  if [[ -z "$xray_path" ]]; then
    for d in "${xray_dir_candidates[@]}"; do
      if [[ -d "$d" ]] && ls "$d"/*.json >/dev/null 2>&1; then
        # 验证目录里有 vless inbound
        local combined
        combined="$(jq -sc '[.[].inbounds? // [] | .[]]' "$d"/*.json 2>/dev/null || echo '[]')"
        if echo "$combined" | jq -e '[.[] | select(.protocol=="vless")] | length > 0' >/dev/null 2>&1; then
          xray_path="$d"; break
        fi
      fi
    done
  fi

  # sing-box
  local sing_candidates=(
    /usr/local/etc/sing-box/config.json
    /etc/sing-box/config.json
    /etc/v2ray-agent/sing-box/conf/config.json
    /etc/v2ray-agent/sing-box/config.json
  )
  for c in "${sing_candidates[@]}"; do
    if [[ -f "$c" ]] && jq -e '.inbounds // .outbounds' "$c" >/dev/null 2>&1; then
      sing_path="$c"; break
    fi
  done

  [[ -n "$xray_path" ]] && log "发现 Xray 配置: $xray_path" || warn "未找到 Xray 配置"
  [[ -n "$sing_path" ]] && log "发现 sing-box 配置: $sing_path" || warn "未找到 sing-box 配置"

  echo "${xray_path}|${sing_path}"
}

# ─── 3. 解析配置 → server.json ────────────────────────────────────────────────
# 把 Xray/sing-box 配置里的端口/密钥提取成统一的 server.json
build_server_json() {
  local domain="$1" xray_path="$2" sing_path="$3"
  log "解析协议参数 → $SERVER_JSON"
  mkdir -p "$SUB_ROOT"

  # 合并 Xray inbounds（单文件或分片目录）
  local xray_inbounds='[]'
  if [[ -d "$xray_path" ]]; then
    xray_inbounds="$(jq -sc '[.[].inbounds? // [] | .[]]' "$xray_path"/*.json 2>/dev/null || echo '[]')"
  elif [[ -f "$xray_path" ]]; then
    xray_inbounds="$(jq -c '.inbounds // []' "$xray_path" 2>/dev/null || echo '[]')"
  fi

  # 解析 VLESS inbounds
  local vless_reality_port=8888 vless_reality_sni="$domain"
  local vless_reality_pubkey="" vless_reality_shortid="" vless_reality_flow="xtls-rprx-vision"
  local vless_tls_port=443 vless_tls_sni="$domain" vless_tls_flow="xtls-rprx-vision"
  local found_reality=false found_tls=false

  # 用 jq 逐个 inbound 解析
  local parsed_reality parsed_tls
  parsed_reality="$(echo "$xray_inbounds" | jq -c '
    [ .[] | select(.protocol == "vless")
      | select(
          (.streamSettings.security == "reality") or
          ((.streamSettings.realitySettings | type) == "object" and
           (.streamSettings.realitySettings | keys | length) > 0)
        )
    ] | .[0] // null
  ')"
  parsed_tls="$(echo "$xray_inbounds" | jq -c '
    [ .[] | select(.protocol == "vless")
      | select(
          (.streamSettings.security == "tls") or
          (.streamSettings.security == "")  or
          (.streamSettings.security == null)
        )
      | select(
          (.streamSettings.realitySettings | type) != "object" or
          (.streamSettings.realitySettings | keys | length) == 0
        )
    ] | .[0] // null
  ')"

  if [[ "$parsed_reality" != "null" && -n "$parsed_reality" ]]; then
    found_reality=true
    vless_reality_port="$(echo "$parsed_reality" | jq -r '.port // 8888')"
    local re_settings
    re_settings="$(echo "$parsed_reality" | jq -c '.streamSettings.realitySettings // {}')"
    # serverNames
    local sni_val
    sni_val="$(echo "$re_settings" | jq -r '
      if (.serverNames | type) == "array" and (.serverNames | length) > 0 then .serverNames[0]
      elif (.dest | type) == "string" and (.dest | length) > 0 then .dest | split(":")[0]
      else ""
      end
    ')"
    [[ -n "$sni_val" && "$sni_val" != "null" ]] && vless_reality_sni="$sni_val"
    # publicKey
    local pk
    pk="$(echo "$re_settings" | jq -r '.publicKey // .public_key // ""')"
    [[ -n "$pk" && "$pk" != "null" ]] && vless_reality_pubkey="$pk"
    # shortId
    local sid
    sid="$(echo "$re_settings" | jq -r '
      if (.shortIds | type) == "array" and (.shortIds | length) > 0 then .shortIds[0]
      elif (.shortId | type) == "string" and (.shortId | length) > 0 then .shortId
      elif (.short_ids | type) == "array" then .short_ids[0]
      elif (.short_id | type) == "string" then .short_id
      else ""
      end
    ')"
    [[ -n "$sid" && "$sid" != "null" ]] && vless_reality_shortid="$sid"
    ok "VLESS+REALITY: port=$vless_reality_port sni=$vless_reality_sni pk=${vless_reality_pubkey:0:16}…"
  fi

  if [[ "$parsed_tls" != "null" && -n "$parsed_tls" ]]; then
    found_tls=true
    vless_tls_port="$(echo "$parsed_tls" | jq -r '.port // 443')"
    local tls_sni
    tls_sni="$(echo "$parsed_tls" | jq -r '
      .streamSettings.tlsSettings.serverName
      // (.streamSettings.tlsSettings.serverNames // [] | .[0])
      // ""
    ')"
    [[ -n "$tls_sni" && "$tls_sni" != "null" ]] && vless_tls_sni="$tls_sni"
    ok "VLESS+TLS: port=$vless_tls_port sni=$vless_tls_sni"
  fi

  # 解析 Hysteria2 (sing-box)
  local hy2_port=8443 hy2_sni="$domain" hy2_alpn='["h3"]'
  if [[ -f "$sing_path" ]]; then
    local hy2_ib
    hy2_ib="$(jq -c '[.. | objects | select(.type == "hysteria2")] | .[0] // null' "$sing_path" 2>/dev/null || echo 'null')"
    if [[ "$hy2_ib" != "null" && -n "$hy2_ib" ]]; then
      hy2_port="$(echo "$hy2_ib" | jq -r '.listen_port // .port // 8443')"
      local h2_sni
      h2_sni="$(echo "$hy2_ib" | jq -r '.tls.server_name // ""')"
      [[ -n "$h2_sni" && "$h2_sni" != "null" ]] && hy2_sni="$h2_sni"
      local h2_alpn
      h2_alpn="$(echo "$hy2_ib" | jq -c '.tls.alpn // ["h3"]' 2>/dev/null || echo '["h3"]')"
      hy2_alpn="$h2_alpn"
      ok "Hysteria2: port=$hy2_port sni=$hy2_sni"
    fi
  fi

  # 写入 server.json
  jq -n \
    --arg domain "$domain" \
    --argjson vless_reality_port "$vless_reality_port" \
    --arg vless_reality_sni "$vless_reality_sni" \
    --arg vless_reality_pubkey "$vless_reality_pubkey" \
    --arg vless_reality_shortid "$vless_reality_shortid" \
    --arg vless_reality_flow "$vless_reality_flow" \
    --argjson vless_tls_port "$vless_tls_port" \
    --arg vless_tls_sni "$vless_tls_sni" \
    --arg vless_tls_flow "$vless_tls_flow" \
    --argjson hy2_port "$hy2_port" \
    --arg hy2_sni "$hy2_sni" \
    --argjson hy2_alpn "$hy2_alpn" \
    --argjson found_reality "$found_reality" \
    --argjson found_tls "$found_tls" \
    '{
      domain: $domain,
      vless_reality: {
        port: $vless_reality_port,
        sni: $vless_reality_sni,
        public_key: $vless_reality_pubkey,
        short_id: $vless_reality_shortid,
        flow: $vless_reality_flow
      },
      vless_tls: {
        port: $vless_tls_port,
        sni: $vless_tls_sni,
        flow: $vless_tls_flow
      },
      hysteria2: {
        port: $hy2_port,
        sni: $hy2_sni,
        alpn: $hy2_alpn
      },
      meta: {
        has_reality: $found_reality,
        has_tls: $found_tls,
        has_hysteria2: true
      }
    }' > "$SERVER_JSON"
  ok "server.json 写入完成"
}

# ─── 4. 注入 Xray Stats + API（幂等）────────────────────────────────────────
# 对单个 JSON 文件执行注入（幂等，使用临时文件防止写坏）
_inject_stats_file() {
  local f="$1"
  # 只处理含 vless inbound 的文件
  jq -e '[.inbounds? // [] | .[] | select(.protocol=="vless")] | length > 0' "$f" >/dev/null 2>&1 || return 0

  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  jq -M \
    --arg api_tag "$XRAY_API_TAG" \
    --argjson api_port "$XRAY_API_PORT" \
    '
    # stats 对象（无内容，但必须存在）
    .stats = (.stats // {})
    # api inbound on loopback grpc
    | .api = (
        if (.api | type) == "object" then
          .api
          | .tag = ($api_tag)
          | .services = (
              (.services // []) as $s
              | if ($s | map(select(. == "StatsService")) | length) > 0 then $s
                else $s + ["StatsService"] end
              | if (map(select(. == "HandlerService")) | length) > 0 then .
                else . + ["HandlerService"] end
            )
        else
          {tag: $api_tag, services: ["HandlerService", "StatsService"]}
        end
      )
    # policy: 开启用户粒度统计
    | .policy.levels."0".statsUserUplink = true
    | .policy.levels."0".statsUserDownlink = true
    | .policy.system.statsInboundUplink = true
    | .policy.system.statsInboundDownlink = true
    # routing: 注入 api inbound tag（幂等）
    | .routing = (
        (.routing // {rules: []}) as $r
        | $r
        | .rules = (
            ($r.rules // []) as $rules
            | if ($rules | map(select(.outboundTag == $api_tag)) | length) > 0
              then $rules
              else [{
                type: "field",
                inboundTag: [$api_tag],
                outboundTag: $api_tag
              }] + $rules
              end
          )
      )
    ' "$f" >"$tmp" \
    && mv "$tmp" "$f" \
    || { warn "stats 注入失败: $f"; return 1; }
}

# 注入 api inbound（分离到独立文件，v2ray-agent 分片目录专用）
_ensure_api_inbound_file() {
  local dir="$1"
  local api_file="$dir/10_api.json"
  # 检查是否已有 api inbound
  if grep -rl "\"tag\":\"${XRAY_API_TAG}\"" "$dir"/ >/dev/null 2>&1 \
     || grep -rl "\"tag\": \"${XRAY_API_TAG}\"" "$dir"/ >/dev/null 2>&1; then
    return 0
  fi
  log "写入分片 API inbound: $api_file"
  jq -n \
    --arg tag "$XRAY_API_TAG" \
    --argjson port "$XRAY_API_PORT" \
    '{
      inbounds: [{
        tag: $tag,
        port: $port,
        listen: "127.0.0.1",
        protocol: "dokodemo-door",
        settings: {address: "127.0.0.1"}
      }]
    }' > "$api_file"
}

inject_xray_stats() {
  local xray_path="$1"
  [[ -n "$xray_path" ]] || { warn "无 Xray 配置，跳过 stats 注入"; return 0; }

  log "注入 Xray stats/api…"
  if [[ -d "$xray_path" ]]; then
    _ensure_api_inbound_file "$xray_path"
    for f in "$xray_path"/*.json; do
      _inject_stats_file "$f" 2>/dev/null || true
    done
  elif [[ -f "$xray_path" ]]; then
    # 单文件：确保有 api inbound（直接塞进 inbounds 数组）
    local tmp; tmp="$(mktemp)"
    trap "rm -f '$tmp'" RETURN
    jq -M \
      --arg tag "$XRAY_API_TAG" \
      --argjson port "$XRAY_API_PORT" \
      '
      if ([ .inbounds? // [] | .[] | select(.tag == $tag)] | length) == 0 then
        .inbounds = (.inbounds // []) + [{
          tag: $tag,
          port: $port,
          listen: "127.0.0.1",
          protocol: "dokodemo-door",
          settings: {address: "127.0.0.1"}
        }]
      else . end
      ' "$xray_path" > "$tmp" && mv "$tmp" "$xray_path"
    _inject_stats_file "$xray_path" 2>/dev/null || true
  fi
  ok "Xray stats 注入完成（API port: $XRAY_API_PORT）"
}

# ─── 5. 写入 sub-api.env ──────────────────────────────────────────────────────
write_env() {
  local domain="$1" xray_path="$2" sing_path="$3"
  mkdir -p "$SUB_ROOT"
  cat >"$ENV_FILE" <<EOF
# Managed by deploy.sh — do not hand-edit, re-run deploy.sh to regenerate
SUB_PUBLIC_DOMAIN=${domain}
SUB_API_ENV=${ENV_FILE}
XRAY_CONFIG=${xray_path}
SINGBOX_CONFIG=${sing_path}
XRAY_API_PORT=${XRAY_API_PORT}
# 若 sing-box 开启了 Clash API 填入，例: http://127.0.0.1:9191
SINGBOX_CLASH_API=
EOF
  ok "sub-api.env 写入完成"
}

# ─── 6. 生成 app.py（Flask 订阅服务）────────────────────────────────────────
write_app_py() {
  log "生成 app.py..."
  cat >"$SUB_ROOT/app.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, time
from pathlib import Path
from flask import Flask, request, Response, abort

ROOT        = Path(os.environ.get("SUB_ROOT", "/opt/sub-api"))
SERVER_JSON = ROOT / "server.json"
TOKENS_JSON = ROOT / "tokens.json"
app = Flask(__name__)

def load_server():
    return json.loads(SERVER_JSON.read_text())

def load_tokens():
    try:
        return json.loads(TOKENS_JSON.read_text())
    except Exception:
        return []

def find_token(token):
    for t in load_tokens():
        if t.get("token") == token:
            return t
    return None

def build_proxies(srv, uuid, note):
    domain  = srv["domain"]
    reality = srv.get("vless_reality", {})
    tls_cfg = srv.get("vless_tls",    {})
    hy2     = srv.get("hysteria2",    {})
    meta    = srv.get("meta",         {})
    blocks, names = [], []

    # Hysteria2 (fastest, first)
    if hy2.get("port"):
        n = "\U0001f680 " + note + " Hysteria2"
        alpn_yaml = "\n".join("      - " + a for a in hy2.get("alpn", ["h3"]))
        blocks.append(
            "  - name: " + n + "\n"
            "    type: hysteria2\n"
            "    server: " + domain + "\n"
            "    port: " + str(hy2["port"]) + "\n"
            "    password: " + uuid + "\n"
            "    sni: " + hy2.get("sni", domain) + "\n"
            "    skip-cert-verify: false\n"
            "    udp: true\n"
            "    alpn:\n" + alpn_yaml
        )
        names.append(n)

    # VLESS + REALITY
    if meta.get("has_reality") and reality.get("public_key"):
        n = "\U0001f512 " + note + " VLESS-Reality"
        blocks.append(
            "  - name: " + n + "\n"
            "    type: vless\n"
            "    server: " + domain + "\n"
            "    port: " + str(reality["port"]) + "\n"
            "    uuid: " + uuid + "\n"
            "    network: tcp\n"
            "    tls: true\n"
            "    udp: true\n"
            "    flow: " + reality.get("flow", "xtls-rprx-vision") + "\n"
            "    servername: " + reality.get("sni", domain) + "\n"
            "    reality-opts:\n"
            "      public-key: " + reality["public_key"] + "\n"
            "      short-id: " + reality.get("short_id", "") + "\n"
            "    client-fingerprint: chrome"
        )
        names.append(n)

    # VLESS + TLS
    if meta.get("has_tls"):
        n = "\U0001f310 " + note + " VLESS-TLS"
        blocks.append(
            "  - name: " + n + "\n"
            "    type: vless\n"
            "    server: " + domain + "\n"
            "    port: " + str(tls_cfg["port"]) + "\n"
            "    uuid: " + uuid + "\n"
            "    network: tcp\n"
            "    tls: true\n"
            "    udp: true\n"
            "    servername: " + tls_cfg.get("sni", domain) + "\n"
            "    client-fingerprint: chrome"
        )
        names.append(n)

    if not blocks:
        n = note
        blocks.append(
            "  - name: " + n + "\n"
            "    type: vless\n"
            "    server: " + domain + "\n"
            "    port: 443\n"
            "    uuid: " + uuid + "\n"
            "    network: tcp\n"
            "    tls: true"
        )
        names.append(n)

    return blocks, names

def build_clash_yaml(srv, entry):
    uuid  = entry["uuid"]
    note  = entry.get("note", uuid[:8])
    blocks, names = build_proxies(srv, uuid, note)
    proxies_yaml  = "\n\n".join(blocks)
    names_indent  = "\n".join("      - " + n for n in names)

    lines = [
        "proxies:",
        proxies_yaml,
        "",
        "proxy-groups:",
        "  - name: \U0001f527 " + note + " Manual",
        "    type: select",
        "    proxies:",
        names_indent,
        "      - DIRECT",
        "",
        "  - name: \u26a1 " + note + " Auto",
        "    type: url-test",
        "    url: http://www.gstatic.com/generate_204",
        "    interval: 300",
        "    tolerance: 50",
        "    proxies:",
        names_indent,
        "",
        "  - name: \U0001f4fa " + note + " Streaming",
        "    type: select",
        "    proxies:",
        names_indent,
        "      - DIRECT",
        "",
        "dns:",
        "  enable: true",
        "  listen: 0.0.0.0:1053",
        "  enhanced-mode: fake-ip",
        "  fake-ip-range: 198.18.0.1/16",
        "  nameserver:",
        "    - https://doh.pub/dns-query",
        "    - https://dns.alidns.com/dns-query",
        "  fallback:",
        "    - https://1.1.1.1/dns-query",
        "    - https://dns.google/dns-query",
        "  fallback-filter:",
        "    geoip: true",
        "    geoip-code: CN",
        "    ipcidr:",
        "      - 240.0.0.0/4",
        "  default-nameserver:",
        "    - 223.5.5.5",
        "    - 119.29.29.29",
        "",
        "rules:",
        "  - DOMAIN-SUFFIX,localhost,DIRECT",
        "  - IP-CIDR,127.0.0.0/8,DIRECT",
        "  - IP-CIDR,192.168.0.0/16,DIRECT",
        "  - IP-CIDR,10.0.0.0/8,DIRECT",
        "  - DOMAIN-SUFFIX,baidu.com,DIRECT",
        "  - DOMAIN-SUFFIX,qq.com,DIRECT",
        "  - DOMAIN-SUFFIX,wechat.com,DIRECT",
        "  - DOMAIN-SUFFIX,weixin.qq.com,DIRECT",
        "  - DOMAIN-SUFFIX,bilibili.com,DIRECT",
        "  - DOMAIN-SUFFIX,taobao.com,DIRECT",
        "  - DOMAIN-SUFFIX,jd.com,DIRECT",
        "  - DOMAIN-SUFFIX,alicdn.com,DIRECT",
        "  - DOMAIN-SUFFIX,alipay.com,DIRECT",
        "  - DOMAIN-SUFFIX,163.com,DIRECT",
        "  - DOMAIN-SUFFIX,126.com,DIRECT",
        "  - DOMAIN-SUFFIX,zhihu.com,DIRECT",
        "  - DOMAIN-SUFFIX,csdn.net,DIRECT",
        "  - DOMAIN-SUFFIX,douyin.com,DIRECT",
        "  - DOMAIN-SUFFIX,weibo.com,DIRECT",
        "  - DOMAIN-SUFFIX,youku.com,DIRECT",
        "  - DOMAIN-SUFFIX,iqiyi.com,DIRECT",
        "  - DOMAIN-SUFFIX,mi.com,DIRECT",
        "  - DOMAIN-SUFFIX,huawei.com,DIRECT",
        "  - DOMAIN-SUFFIX,bytedance.com,DIRECT",
        "  - GEOIP,CN,DIRECT",
        "  - MATCH,\U0001f527 " + note + " Manual",
    ]
    return "\n".join(lines) + "\n"

@app.get("/sub")
def sub():
    token = request.args.get("token", "")
    if not token:
        abort(403)
    entry = find_token(token)
    if not entry:
        abort(403)
    srv = load_server()
    yaml_content = build_clash_yaml(srv, entry)
    filename = "clash-" + entry.get("note", "sub") + ".yaml"
    return Response(yaml_content, mimetype="text/plain; charset=utf-8",
                    headers={"Content-Disposition": "attachment; filename=\"" + filename + "\""})

@app.get("/health")
def health():
    return {"status": "ok", "ts": int(time.time())}

if __name__ == "__main__":
    host = os.environ.get("SUB_API_HOST", "127.0.0.1")
    port = int(os.environ.get("SUB_API_PORT", 8080))
    app.run(host=host, port=port, debug=False)
PYEOF
  ok "app.py generated"
}

# ─── 7. 生成 requirements.txt ────────────────────────────────────────────────
write_requirements() {
  cat >"$SUB_ROOT/requirements.txt" <<'EOF'
flask>=3.0
gunicorn>=21.0
EOF
}

# ─── 8. 安装 Python venv ──────────────────────────────────────────────────────
venv_install() {
  log "创建 Python venv…"
  python3 -m venv "$SUB_ROOT/venv"
  # shellcheck disable=SC1091
  source "$SUB_ROOT/venv/bin/activate"
  pip install --upgrade pip -q
  pip install -r "$SUB_ROOT/requirements.txt" -q
  deactivate
  ok "venv 安装完成"
}

# ─── 9. 生成 vpn CLI（完整自包含）────────────────────────────────────────────
write_vpn_cli() {
  log "生成 vpn CLI…"
  cat >/usr/local/bin/vpn <<'VPNEOF'
#!/usr/bin/env bash
# vpn CLI — 管理 clash-sub-api 订阅用户
set -euo pipefail

ROOT="/opt/sub-api"
ENV_FILE="$ROOT/sub-api.env"
TOKENS_JSON="$ROOT/tokens.json"

# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
DOMAIN="${SUB_PUBLIC_DOMAIN:-}"
XRAY_CFG="${XRAY_CONFIG:-}"
SING_CFG="${SINGBOX_CONFIG:-}"
XRAY_API_PORT="${XRAY_API_PORT:-10085}"

die()  { echo "[vpn] error: $*" >&2; exit 1; }
log()  { echo "[vpn] $*" >&2; }

load_tokens() { jq -c . "$TOKENS_JSON" 2>/dev/null || echo '[]'; }
save_tokens() { echo "$1" | jq . >"$TOKENS_JSON"; chmod 0640 "$TOKENS_JSON"; }

gen_uuid()  { uuidgen | tr '[:upper:]' '[:lower:]'; }
gen_token() { openssl rand -hex 20; }

# 向单个 JSON 文件添加 VLESS 用户（幂等）
_xray_add_to_file() {
  local f="$1" uuid="$2"
  jq -e '[.inbounds? // [] | .[] | select(.protocol=="vless")] | length > 0' \
    "$f" >/dev/null 2>&1 || return 0
  local tmp; tmp="$(mktemp)"
  jq -M --arg uuid "$uuid" \
    '(.inbounds[] | select(.protocol=="vless") | .settings.clients) |= (
       if . == null then [{id: $uuid, email: $uuid, flow: "xtls-rprx-vision"}]
       elif map(select(.id == $uuid)) | length > 0 then .
       else . + [{id: $uuid, email: $uuid, flow: "xtls-rprx-vision"}]
       end
     )' "$f" > "$tmp" && mv "$tmp" "$f"
}

# 向 Xray config 添加 VLESS 用户
_xray_add_user() {
  local uuid="$1"
  if [[ -d "$XRAY_CFG" ]]; then
    for f in "$XRAY_CFG"/*.json; do _xray_add_to_file "$f" "$uuid"; done
  elif [[ -f "$XRAY_CFG" ]]; then
    _xray_add_to_file "$XRAY_CFG" "$uuid"
  fi
}

# 从单个 JSON 文件删除 VLESS 用户
_xray_del_from_file() {
  local f="$1" uuid="$2"
  jq -e '[.inbounds? // [] | .[] | select(.protocol=="vless")] | length > 0' \
    "$f" >/dev/null 2>&1 || return 0
  local tmp; tmp="$(mktemp)"
  jq -M --arg uuid "$uuid" \
    '(.inbounds[] | select(.protocol=="vless") | .settings.clients) |=
       map(select(.id != $uuid))' \
    "$f" > "$tmp" && mv "$tmp" "$f"
}

# 从 Xray config 删除 VLESS 用户
_xray_del_user() {
  local uuid="$1"
  if [[ -d "$XRAY_CFG" ]]; then
    for f in "$XRAY_CFG"/*.json; do _xray_del_from_file "$f" "$uuid"; done
  elif [[ -f "$XRAY_CFG" ]]; then
    _xray_del_from_file "$XRAY_CFG" "$uuid"
  fi
}

# 向 sing-box 添加 Hysteria2 密码
_singbox_add_user() {
  local uuid="$1"
  [[ -f "$SING_CFG" ]] || return 0
  local tmp; tmp="$(mktemp)"
  jq -M \
    --arg pwd "$uuid" \
    '(.inbounds[] | select(.type=="hysteria2") | .users) |= (
      if . == null then [{name: $pwd, password: $pwd}]
      elif map(select(.password == $pwd)) | length > 0 then .
      else . + [{name: $pwd, password: $pwd}]
      end
    )' "$SING_CFG" > "$tmp" && mv "$tmp" "$SING_CFG"
}

# 向 sing-box 删除 Hysteria2 用户
_singbox_del_user() {
  local uuid="$1"
  [[ -f "$SING_CFG" ]] || return 0
  local tmp; tmp="$(mktemp)"
  jq -M \
    --arg pwd "$uuid" \
    '(.inbounds[] | select(.type=="hysteria2") | .users) |= map(select(.password != $pwd))' \
    "$SING_CFG" > "$tmp" && mv "$tmp" "$SING_CFG"
}

reload_cores() {
  for svc in xray sing-box v2ray-agent; do
    systemctl is-active --quiet "$svc" 2>/dev/null && systemctl restart "$svc" && log "restarted $svc" || true
  done
  systemctl is-active --quiet sub-api 2>/dev/null && systemctl restart sub-api && log "restarted sub-api" || true
}

# 从 Xray gRPC Stats API 查询用户流量
_xray_traffic() {
  local uuid="$1"
  local up="-" down="-"
  if command -v grpcurl >/dev/null 2>&1; then
    local raw
    raw="$(grpcurl -plaintext \
      -d "{\"name\": \"user>>>${uuid}>>>traffic>>>uplink\", \"reset\": false}" \
      "127.0.0.1:${XRAY_API_PORT}" \
      xray.app.stats.command.StatsService/GetStats 2>/dev/null || echo '{}')"
    up="$(echo "$raw" | jq -r '.stat.value // "-"' 2>/dev/null || echo '-')"
    raw="$(grpcurl -plaintext \
      -d "{\"name\": \"user>>>${uuid}>>>traffic>>>downlink\", \"reset\": false}" \
      "127.0.0.1:${XRAY_API_PORT}" \
      xray.app.stats.command.StatsService/GetStats 2>/dev/null || echo '{}')"
    down="$(echo "$raw" | jq -r '.stat.value // "-"' 2>/dev/null || echo '-')"
  else
    # 尝试 xray API over HTTP (v1.8+)
    local url_base="http://127.0.0.1:${XRAY_API_PORT}"
    up="$(curl -sf "${url_base}/v1/stats/user?name=${uuid}&reset=false" 2>/dev/null \
      | jq -r '.stat.uplink // "-"' 2>/dev/null || echo '-')"
    down="$(curl -sf "${url_base}/v1/stats/user?name=${uuid}&reset=false" 2>/dev/null \
      | jq -r '.stat.downlink // "-"' 2>/dev/null || echo '-')"
  fi
  echo "${up}|${down}"
}

_fmt_bytes() {
  local n="$1"
  [[ "$n" == "-" || "$n" == "null" ]] && echo "-" && return
  local gb mb kb
  gb=$(( n / 1073741824 )); mb=$(( (n % 1073741824) / 1048576 ))
  kb=$(( (n % 1048576) / 1024 ))
  if   (( gb > 0 )); then echo "${gb}.$(( mb * 10 / 1024 ))G"
  elif (( mb > 0 )); then echo "${mb}.$(( kb * 10 / 1024 ))M"
  elif (( kb > 0 )); then echo "${kb}K"
  else                    echo "${n}B"; fi
}

cmd_create() {
  local note="${1:-device}"
  local uuid token sub_url
  uuid="$(gen_uuid)"
  token="$(gen_token)"
  [[ -n "$DOMAIN" ]] || die "SUB_PUBLIC_DOMAIN 未设置，请检查 $ENV_FILE"

  _xray_add_user "$uuid"
  _singbox_add_user "$uuid"

  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tokens new_entry
  tokens="$(load_tokens)"
  new_entry="$(jq -n \
    --arg token "$token" --arg uuid "$uuid" \
    --arg note "$note" --arg created "$now" \
    '{token: $token, uuid: $uuid, note: $note, created: $created}')"
  tokens="$(echo "$tokens" | jq ". + [$new_entry]")"
  save_tokens "$tokens"

  reload_cores

  sub_url="https://${DOMAIN}/sub?token=${token}"
  echo ""
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│  新用户已创建                                               │"
  echo "├─────────────────────────────────────────────────────────────┤"
  printf "│  备注  : %-52s│\n" "$note"
  printf "│  UUID  : %-52s│\n" "$uuid"
  printf "│  Token : %-52s│\n" "$token"
  echo "├─────────────────────────────────────────────────────────────┤"
  printf "│  订阅 URL:\n"
  printf "│  %s\n" "$sub_url"
  echo "└─────────────────────────────────────────────────────────────┘"
  echo ""
}

cmd_list() {
  local tokens
  tokens="$(load_tokens)"
  local count; count="$(echo "$tokens" | jq 'length')"
  echo ""
  printf "%-12s  %-36s  %-14s  %-8s  %-8s  %-8s  %s\n" \
    "TOKEN(前8)" "UUID" "备注" "↑VLESS" "↓VLESS" "创建时间" ""
  printf '%0.s─' {1..100}; echo ""
  local i=0
  while [[ $i -lt $count ]]; do
    local entry token uuid note created traffic up down
    entry="$(echo "$tokens" | jq -r ".[$i]")"
    token="$(echo "$entry" | jq -r '.token')"
    uuid="$(echo "$entry" | jq -r '.uuid')"
    note="$(echo "$entry" | jq -r '.note // "-"')"
    created="$(echo "$entry" | jq -r '.created // "-"')"
    traffic="$(_xray_traffic "$uuid")"
    up="$(_fmt_bytes "${traffic%%|*}")"
    down="$(_fmt_bytes "${traffic##*|}")"
    printf "%-12s  %-36s  %-14s  %-8s  %-8s  %s\n" \
      "${token:0:8}…" "$uuid" "$note" "$up" "$down" "${created:0:10}"
    i=$(( i + 1 ))
  done
  echo ""
}

cmd_revoke() {
  local token="${1:-}"
  [[ -n "$token" ]] || die "用法: vpn revoke <token>"
  local tokens entry uuid
  tokens="$(load_tokens)"
  entry="$(echo "$tokens" | jq -r "[.[] | select(.token==\"$token\")] | .[0]")"
  [[ "$entry" != "null" && -n "$entry" ]] || die "Token 不存在: $token"
  uuid="$(echo "$entry" | jq -r '.uuid')"
  _xray_del_user "$uuid"
  _singbox_del_user "$uuid"
  tokens="$(echo "$tokens" | jq "[.[] | select(.token != \"$token\")]")"
  save_tokens "$tokens"
  reload_cores
  echo "[vpn] 已吊销 token=${token:0:8}… uuid=$uuid"
}

cmd_url() {
  local token="${1:-}"
  [[ -n "$token" ]] || die "用法: vpn url <token>"
  [[ -n "$DOMAIN" ]] || die "SUB_PUBLIC_DOMAIN 未设置"
  local entry
  entry="$(load_tokens | jq -r "[.[] | select(.token==\"$token\")] | .[0]")"
  [[ "$entry" != "null" && -n "$entry" ]] || die "Token 不存在"
  echo "https://${DOMAIN}/sub?token=${token}"
}

cmd_status() {
  systemctl status sub-api --no-pager -l || true
}

cmd_reload() {
  reload_cores
}

cmd_help() {
  cat <<'HELP'
用法: vpn <命令> [参数]

命令:
  create [备注]     新建用户（生成 token + UUID，写入 Xray/sing-box）
  list              列出所有用户及流量统计
  revoke <token>    吊销用户（从 Xray/sing-box 删除）
  url <token>       打印订阅 URL
  status            显示 sub-api 服务状态
  reload            重启 Xray / sing-box / sub-api
  help              显示此帮助
HELP
}

case "${1:-help}" in
  create)  cmd_create  "${2:-}" ;;
  list)    cmd_list ;;
  revoke)  cmd_revoke  "${2:-}" ;;
  url)     cmd_url     "${2:-}" ;;
  status)  cmd_status ;;
  reload)  cmd_reload ;;
  help|*)  cmd_help ;;
esac
VPNEOF
  chmod +x /usr/local/bin/vpn
  ok "vpn CLI 安装完成 → /usr/local/bin/vpn"
}

# ─── 10. 生成 sub-api-stop 工具 ──────────────────────────────────────────────
write_stop_script() {
  cat >/usr/local/bin/sub-api-stop <<'EOF'
#!/usr/bin/env bash
systemctl stop sub-api && echo "[sub-api-stop] sub-api 已停止" || echo "[sub-api-stop] 停止失败"
EOF
  chmod +x /usr/local/bin/sub-api-stop
}

# ─── 11. systemd 服务 ─────────────────────────────────────────────────────────
write_systemd() {
  log "配置 systemd sub-api.service…"
  cat >/etc/systemd/system/sub-api.service <<EOF
[Unit]
Description=Clash Subscription API (sub-api)
After=network.target

[Service]
Type=simple
WorkingDirectory=${SUB_ROOT}
EnvironmentFile=-${ENV_FILE}
Environment=SUB_ROOT=${SUB_ROOT}
ExecStart=${SUB_ROOT}/venv/bin/gunicorn --bind 127.0.0.1:8080 --workers 2 --timeout 30 app:app
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sub-api
  systemctl restart sub-api || true   # 失败继续，下面会检测端口

  # 等待最多 12 秒确认 8080 端口真的在监听
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if ss -tlnp 2>/dev/null | grep -q ':8080 '; then
      ok "sub-api 启动成功，8080 端口已监听"
      return 0
    fi
    sleep 1
  done
  warn "sub-api 启动后 8080 端口未检测到 — 查看日志: journalctl -u sub-api -n 30"
}

# ─── 12. Nginx 配置 ───────────────────────────────────────────────────────────
# 生成 proxy_pass 片段（Python 写文件，避免 bash heredoc 转义地狱）
_write_location_snippet() {
  local dest_file="$1"
  python3 - "$dest_file" <<'PY'
import sys
f = sys.argv[1]
snippet = """    location /sub {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }
    location /health {
        proxy_pass       http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
"""
open(f, "w").write(snippet)
PY
}

# 检测当前 Nginx 是否已经代理了 /sub 到 8080
_nginx_has_sub_proxy() {
  nginx -T 2>/dev/null | grep -q "proxy_pass.*127.0.0.1:8080" && \
  nginx -T 2>/dev/null | grep -q "location /sub"
}

# 修补单个 nginx conf 文件（幂等，用 Python 做插入避免 sed 转义问题）
_patch_nginx_conf() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -q "location /sub" "$f" && { log "$f 已有 /sub 配置"; return 0; }

  # 写出 snippet 到临时文件
  local snippet_file; snippet_file="$(mktemp)"
  _write_location_snippet "$snippet_file"

  python3 - "$f" "$snippet_file" <<'PY'
import sys, re
conf_path = sys.argv[1]
snippet   = open(sys.argv[2]).read()
text      = open(conf_path).read()

# 在第一个 "location / {" 或 "location ~ ^/s/" 前插入
markers = [r'^\s*location\s*/\s*\{', r'^\s*location\s*~\s*\^/s/']
insert_pos = None
for pat in markers:
    m = re.search(pat, text, re.MULTILINE)
    if m:
        insert_pos = m.start()
        break

if insert_pos is None:
    # 找不到 marker，插到最后一个 } 之前
    insert_pos = text.rfind("}")
    if insert_pos == -1:
        print(f"[patch] cannot find insert point in {conf_path}", flush=True)
        sys.exit(1)

new_text = text[:insert_pos] + snippet + text[insert_pos:]
open(conf_path, "w").write(new_text)
print(f"[patch] patched {conf_path}", flush=True)
PY
  rm -f "$snippet_file"
}

# 核心函数：检测 nginx 场景并配置
configure_nginx() {
  local domain="$1"
  log "检测 Nginx 配置场景…"

  # ── 场景A：v2ray-agent 的分片配置（conf.d/alone.conf 或 subscribe.conf）
  local v2ray_nginx_patched=false
  for cf in /etc/nginx/conf.d/alone.conf /etc/nginx/conf.d/subscribe.conf; do
    if [[ -f "$cf" ]]; then
      log "发现 v2ray-agent nginx 配置: $cf"
      if _patch_nginx_conf "$cf"; then
        v2ray_nginx_patched=true
        ok "已修补: $cf"
      fi
    fi
  done

  if $v2ray_nginx_patched; then
    nginx -t && systemctl reload nginx && ok "v2ray-agent nginx 修补并重载完成"
    # v2ray-agent 场景下 certbot 证书已存在，不需要新建 server block
    log "v2ray-agent 场景：跳过新建 server block，证书由 v2ray-agent 管理"
    return 0
  fi

  # ── 场景B：纯净 nginx，新建 server block + certbot
  log "未检测到 v2ray-agent nginx，新建独立站点配置…"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html

  # 确保 nginx.conf 包含 sites-enabled
  if ! grep -q 'sites-enabled' /etc/nginx/nginx.conf 2>/dev/null; then
    sed -i '/http {/a\\tinclude /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
  fi

  python3 - "$domain" >/etc/nginx/sites-available/sub-api <<'PY'
import sys
d = sys.argv[1]
print(f"""server {{
    listen 80;
    listen [::]:80;
    server_name {d};
    root /var/www/html;
    location /.well-known/acme-challenge/ {{ }}
    location /sub {{
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }}
    location /health {{
        proxy_pass       http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }}
}}""")
PY
  ln -sf /etc/nginx/sites-available/sub-api /etc/nginx/sites-enabled/sub-api
  nginx -t && systemctl reload nginx && ok "Nginx 站点配置写入完成"

  # 申请证书
  run_certbot "$domain"
}

# ─── 13. Let's Encrypt ───────────────────────────────────────────────────────
run_certbot() {
  local domain="$1"
  log "申请 TLS 证书（域名: $domain）…"

  if certbot certificates 2>/dev/null | grep -q "Domains:.*${domain}"; then
    ok "证书已存在，跳过申请"
    return 0
  fi

  local args=(--nginx -d "$domain" --non-interactive --agree-tos --redirect)
  if [[ -n "${CERTBOT_EMAIL:-}" ]]; then
    args+=(--email "$CERTBOT_EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi

  certbot "${args[@]}" && ok "证书申请成功" || {
    warn "certbot 失败 — 请确认域名已解析且 80 端口可访问"
    warn "手动补跑: certbot --nginx -d ${domain} --agree-tos --register-unsafely-without-email --redirect"
  }
  nginx -t && systemctl reload nginx || true
}

# ─── 14. 重启核心服务 ────────────────────────────────────────────────────────
reload_cores() {
  log "重启代理核心…"
  for svc in xray sing-box v2ray-agent; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      systemctl restart "$svc" && ok "restarted $svc" || warn "restart $svc failed"
    fi
  done
}

# ─── 初始化 tokens.json ───────────────────────────────────────────────────────
init_tokens() {
  [[ -f "$TOKENS_JSON" ]] || { echo '[]' >"$TOKENS_JSON"; chmod 0640 "$TOKENS_JSON"; }
}

# ─── 打印部署摘要 ─────────────────────────────────────────────────────────────
print_summary() {
  local domain="$1"
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  clash-sub-api 部署完成"
  echo "═══════════════════════════════════════════════════════════════"
  echo "  订阅域名  : https://${domain}/sub?token=<token>"
  echo "  健康检查  : https://${domain}/health"
  echo "  配置文件  : ${SERVER_JSON}"
  echo "  环境变量  : ${ENV_FILE}"
  echo ""
  echo "  常用命令:"
  echo "    vpn create <备注>   # 新建用户"
  echo "    vpn list            # 查看用户与流量"
  echo "    vpn revoke <token>  # 吊销用户"
  echo "    vpn reload          # 重启服务"
  echo "    sudo sub-api-stop   # 停止订阅 API"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────
main() {
  need_root

  local domain
  domain="$(require_domain "${1:-}")"

  log "开始部署 clash-sub-api → 域名: $domain"

  # ── 停止所有旧服务 ──────────────────────────────────────────────────────────
  log "停止旧服务…"
  # 停 sub-api（若存在）
  if systemctl is-active --quiet sub-api 2>/dev/null; then
    systemctl stop sub-api && log "stopped sub-api" || true
  fi
  systemctl disable sub-api 2>/dev/null || true

  # 杀掉任何仍然占用 8080 的进程
  local pids
  pids="$(ss -tlnp 2>/dev/null | awk '/:8080 /{print $0}'          | grep -oP 'pid=\K[0-9]+' || true)"
  if [[ -n "$pids" ]]; then
    log "杀掉占用 8080 的进程: $pids"
    echo "$pids" | xargs -r kill -9 2>/dev/null || true
    sleep 1
  fi

  # 清理旧的 venv / app（保留 tokens.json）
  if [[ -d "$SUB_ROOT/venv" ]]; then
    log "清理旧 venv…"
    rm -rf "$SUB_ROOT/venv"
  fi

  # 确保 nginx 在运行（certbot 需要）
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl start nginx || true
  fi
  ok "旧服务清理完成"

  # 安装依赖
  install_packages

  # 探测配置
  local paths xray_path sing_path
  paths="$(discover_configs)"
  xray_path="${paths%%|*}"
  sing_path="${paths##*|}"

  # 初始化目录
  mkdir -p "$SUB_ROOT"
  init_tokens

  # 生成配置文件
  write_env "$domain" "$xray_path" "$sing_path"
  build_server_json "$domain" "$xray_path" "$sing_path"

  # 注入 Xray stats
  inject_xray_stats "$xray_path"

  # 重启代理核心（让 stats API 生效）
  [[ -n "$xray_path" ]] && reload_cores || true

  # 生成 Python 应用
  write_app_py
  write_requirements
  venv_install

  # 安装 CLI 工具
  write_vpn_cli
  write_stop_script

  # 配置系统服务
  write_systemd

  # 配置 Nginx（自动检测 v2ray-agent 场景 vs 纯净场景）
  configure_nginx "$domain"

  # 创建首个用户
  log "创建首个订阅用户…"
  SUB_PUBLIC_DOMAIN="$domain" /usr/local/bin/vpn create "first-device" || true

  print_summary "$domain"
}

main "$@"