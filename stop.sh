#!/usr/bin/env bash
# 停止 systemd 服务 sub-api（订阅 API），不影响 nginx / Xray / sing-box

if grep -qU $'\r' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"
  exec bash "$0" "$@"
fi

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "请使用 root: sudo sub-api-stop" >&2
  exit 1
fi

if systemctl is-active --quiet sub-api 2>/dev/null; then
  systemctl stop sub-api
  echo "sub-api 已停止"
else
  echo "sub-api 未在运行"
fi
