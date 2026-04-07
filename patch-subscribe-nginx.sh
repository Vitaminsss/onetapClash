#!/usr/bin/env bash
# 单独修补 v2ray-agent 的 nginx：alone.conf（443 fallback）+ subscribe.conf（35172）
# 用法: sudo bash patch-subscribe-nginx.sh
# 依赖同目录下的 nginx_patch_v2ray.py；若已部署到 /opt/sub-api/ 则优先使用。
set -euo pipefail
[[ "${EUID:-0}" -eq 0 ]] || { echo "请用 root: sudo bash $0"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_INSTALL="/opt/sub-api/nginx_patch_v2ray.py"
PY_SRC="${SCRIPT_DIR}/nginx_patch_v2ray.py"

mkdir -p /opt/sub-api
if [[ ! -f "$PY_INSTALL" ]]; then
  if [[ -f "$PY_SRC" ]]; then
    install -m0644 "$PY_SRC" "$PY_INSTALL"
    echo "已安装 $PY_INSTALL（来自脚本同目录）"
  else
    echo "缺少 $PY_INSTALL 且同目录无 nginx_patch_v2ray.py，请 git 拉最新或运行 deploy.sh"
    exit 1
  fi
fi

PY="$PY_INSTALL"
sed -i 's/\r$//' "$PY" 2>/dev/null || true
python3 "$PY"
nginx -t
systemctl reload nginx
echo "完成。测试: curl -sI \"https://你的域名/sub?token=...\""
