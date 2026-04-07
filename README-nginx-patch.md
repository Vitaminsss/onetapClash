# Nginx /sub 与 v2ray-agent

外网 `https://域名/sub` 经 Xray 443 fallback 进入 `**/etc/nginx/conf.d/alone.conf**` 中带 `real_ip_header proxy_protocol` 的 `server` 块；仅改 `subscribe.conf`（35172）无法修复默认 HTTPS。

部署脚本会运行 `**nginx_patch_v2ray.py**`，向以下文件幂等插入 `/sub` 与 `/health` 反代到 `127.0.0.1:8080`：

- `alone.conf`（proxy_protocol 块内、在 `location /` 之前）
- `subscribe.conf`（在 `location ~ ^/s/` 或 `location /` 之前）

单独修补（无需完整 deploy）：

```bash
cd ~/dev/clash-sub-api   # 确保目录里有 nginx_patch_v2ray.py
sudo bash patch-subscribe-nginx.sh
```

`patch-subscribe-nginx.sh` 若发现 `/opt/sub-api/nginx_patch_v2ray.py` 不存在，会**从脚本同目录复制**到 `/opt/sub-api/` 再执行。

若从未跑过新版 `deploy.sh`，也可手动安装一次：

```bash
sudo install -m0644 nginx_patch_v2ray.py /opt/sub-api/nginx_patch_v2ray.py
sudo python3 /opt/sub-api/nginx_patch_v2ray.py && sudo nginx -t && sudo systemctl reload nginx
```

或重新执行完整部署（会复制该文件）：

```bash
sudo bash deploy.sh vps.ooooxo.com
```

