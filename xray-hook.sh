#!/usr/bin/env bash
# Helpers to merge users into Xray / sing-box JSON and inject stats API.
# Source: /opt/sub-api/xray-hook.sh

set -euo pipefail

ENV_FILE="${SUB_API_ENV:-/opt/sub-api/sub-api.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

XRAY_CONFIG="${XRAY_CONFIG:-}"
SINGBOX_CONFIG="${SINGBOX_CONFIG:-}"
XRAY_API_PORT="${XRAY_API_PORT:-10085}"

log() { echo "[sub-api] $*" >&2; }

merge_xray_stats() {
  local f="$1"
  [[ -f "$f" ]] || { log "Xray config not found: $f"; return 1; }
  local tmp
  tmp="$(mktemp)"
  jq --argjson port "$XRAY_API_PORT" '
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

# Add VLESS client {id, email, flow} to every inbound with protocol vless and settings.clients array.
xray_add_vless_user() {
  local f="$1" uuid="$2"
  [[ -f "$f" ]] || return 1
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$uuid" --arg em "$uuid" '
    walk(
      if type == "object"
         and .protocol == "vless"
         and (.settings.clients | type == "array")
      then
        .settings.clients as $c
        | if ($c | map(.id) | index($id)) != null then
            .
          else
            .settings.clients = $c + [{
              "id": $id,
              "email": $em,
              "encryption": "none",
              "flow": "xtls-rprx-vision"
            }]
          end
      else . end
    )
  ' "$f" >"$tmp"
  mv "$tmp" "$f"
}

xray_remove_vless_user() {
  local f="$1" uuid="$2"
  [[ -f "$f" ]] || return 1
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$uuid" '
    walk(
      if type == "object"
         and .protocol == "vless"
         and (.settings.clients | type == "array")
      then .settings.clients |= map(select(.id != $id))
      else . end
    )
  ' "$f" >"$tmp"
  mv "$tmp" "$f"
}

# sing-box: hysteria2 inbound users[] { name, password }
singbox_add_hy2_user() {
  local f="$1" uuid="$2"
  [[ -f "$f" ]] || { log "sing-box config not found: $f"; return 0; }
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$uuid" '
    walk(
      if type == "object" and .type == "hysteria2" then
        (if (.users | type) != "array" then .users = [] else . end)
        | .users as $u
        | if ($u | map(.password) | index($id)) != null then .
          else .users = $u + [{"name": $id, "password": $id}]
          end
      else . end
    )
  ' "$f" >"$tmp"
  mv "$tmp" "$f"
}

singbox_remove_hy2_user() {
  local f="$1" uuid="$2"
  [[ -f "$f" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$uuid" '
    walk(
      if type == "object" and .type == "hysteria2" and (.users | type) == "array" then
        .users |= map(select(.password != $id))
      else . end
    )
  ' "$f" >"$tmp"
  mv "$tmp" "$f"
}

register_user() {
  local uuid="$1"
  [[ -n "$XRAY_CONFIG" && -f "$XRAY_CONFIG" ]] && {
    merge_xray_stats "$XRAY_CONFIG" || true
    xray_add_vless_user "$XRAY_CONFIG" "$uuid"
  }
  [[ -n "$SINGBOX_CONFIG" && -f "$SINGBOX_CONFIG" ]] && singbox_add_hy2_user "$SINGBOX_CONFIG" "$uuid"
}

revoke_user() {
  local uuid="$1"
  [[ -n "$XRAY_CONFIG" && -f "$XRAY_CONFIG" ]] && xray_remove_vless_user "$XRAY_CONFIG" "$uuid"
  [[ -n "$SINGBOX_CONFIG" && -f "$SINGBOX_CONFIG" ]] && singbox_remove_hy2_user "$SINGBOX_CONFIG" "$uuid"
}

reload_cores() {
  for s in xray sing-box v2ray-agent; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
      log "restarting $s"
      systemctl restart "$s" || true
    fi
  done
}

inject_stats_only() {
  [[ -n "$XRAY_CONFIG" && -f "$XRAY_CONFIG" ]] && merge_xray_stats "$XRAY_CONFIG"
}
