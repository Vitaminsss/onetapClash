#!/usr/bin/env bash
# 在已安装 v2ray-agent 的机器上，把 /sub 反代补进 /etc/nginx/conf.d/subscribe.conf
# 用法: sudo bash patch-subscribe-nginx.sh your.domain.com
set -euo pipefail
[[ "${EUID:-0}" -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
DOMAIN="${1:?用法: sudo bash patch-subscribe-nginx.sh your.domain.com}"
F="/etc/nginx/conf.d/subscribe.conf"
[[ -f "$F" ]] || { echo "未找到 $F，本机可能不是 v2ray-agent 默认 nginx 布局"; exit 1; }

if grep -q 'location /sub' "$F"; then
  echo "已存在 location /sub，无需重复"
  exit 0
fi

python3 - "$F" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "location /sub" in text:
    sys.exit(0)
snippet = """    location /sub {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    location /health {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
"""
mark = "location ~ ^/s/"
if mark in text:
    i = text.index(mark)
    text = text[:i] + snippet + "\n" + text[i:]
else:
    i = text.find("    location / {")
    if i == -1:
        print("未找到插入点，请手动编辑", path, file=sys.stderr)
        sys.exit(1)
    text = text[:i] + snippet + "\n" + text[i:]
path.write_text(text, encoding="utf-8")
print("已写入", path)
PY

nginx -t
systemctl reload nginx
echo "完成。请测试: curl -sI https://${DOMAIN}/sub  （若 HTTPS 在 35172 等非 443 端口，请加上 :端口）"
