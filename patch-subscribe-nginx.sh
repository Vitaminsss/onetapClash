#!/usr/bin/env bash
# 单独修补 v2ray-agent 的 nginx：alone.conf（443 fallback）+ subscribe.conf（35172）
# 用法: sudo bash patch-subscribe-nginx.sh
# 依赖同目录下的 nginx_patch_v2ray.py；若已部署到 /opt/sub-api/ 则优先使用。
set -euo pipefail
[[ "${EUID:-0}" -eq 0 ]] || { echo "请用 root: sudo bash $0"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="/opt/sub-api/nginx_patch_v2ray.py"
if [[ ! -f "$PY" ]]; then
  PY="${SCRIPT_DIR}/nginx_patch_v2ray.py"
fi
[[ -f "$PY" ]] || { echo "未找到 nginx_patch_v2ray.py（请与脚本同目录或先运行 deploy.sh）"; exit 1; }

sed -i 's/\r$//' "$PY" 2>/dev/null || true
python3 "$PY"
nginx -t
systemctl reload nginx
echo "完成。测试: curl -sI \"https://你的域名/sub?token=...\""
