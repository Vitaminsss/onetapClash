# clash-sub-api

一键部署 **Clash Verge / Meta（mihomo）** 远程订阅：Flask 返回完整 YAML；`vpn` CLI 管理 token、向 Xray / sing-box 注册独立 UUID，并从 **Xray Stats API** 读取每用户流量。

## 环境

- Debian / Ubuntu（root）
- 已安装 **mack-a v2ray-agent**（或已有 Xray + sing-box JSON 配置）
- 域名已 **A 记录指向本机**（Let's Encrypt）

## 安装

```bash
cd /path/to/clash-sub-api
sudo bash deploy.sh your.domain.com
```

脚本会：

1. 安装 `python3`、`nginx`、`certbot`、`jq` 等依赖
2. 将程序安装到 `/opt/sub-api/`
3. 自动探测常见路径下的 `Xray`、`sing-box` 主配置，写入 `/opt/sub-api/sub-api.env`
4. 向 Xray 注入 `stats` + `api`（默认 `127.0.0.1:10085`）与 `policy.levels.0` 用户统计
5. 配置 Nginx：`/sub` → `127.0.0.1:8080`，并申请 HTTPS
6. 注册 systemd 服务 `sub-api`
7. 安装全局命令 `/usr/local/bin/vpn`，并创建首个用户

部署完成后，将输出的 **订阅 URL** 填入 Clash Verge。

## 命令


| 命令                   | 说明                                                                                 |
| -------------------- | ---------------------------------------------------------------------------------- |
| `vpn create [备注]`    | 新用户：生成 token + UUID，写入 Xray VLESS 与 sing-box Hysteria2                             |
| `vpn list`           | 列出用户；**Xray↑/↓** 为 VLESS（Vision+Reality）统计；**H2↑/↓** 需配置 `SINGBOX_CLASH_API` 时尝试拉取 |
| `vpn revoke <token>` | 吊销并从配置中删除该 UUID                                                                    |
| `vpn status`         | `sub-api` 服务状态                                                                     |
| `vpn reload`         | 重启 Xray/sing-box（若存在）与 `sub-api`                                                   |


## 配置说明

- `**/opt/sub-api/server.json`**：域名、各协议端口、REALITY `public_key` / `short_id` 等。部署时由 `discover.py` 尽量从现有配置推断，请按需手改后执行 `vpn reload`。
- **分流规则**：订阅中的 `proxy-groups`、`dns`、`rules`（局域网直连、流媒体 `📺 流媒体`、国内域名直连、`GEOIP,CN`、`MATCH`）与模板一致；多节点时「手动选择 / 流媒体」组内包含全部节点。可在 `server.json` 中增加 `**routing`** 调整 `MATCH` 目标，例如：
  ```json
  "routing": { "match": "manual" }
  ```
  - 不写 `routing` 时，默认 `**MATCH,🚀 Hysteria2 极速**`（与单节点示例一致）。
  - `"match": "manual"` → `**MATCH,🔧 手动选择**`（其余流量进手动组，自行选节点）。
  - `"match": "🔧 手动选择"` 或其它**代理/策略组名称**字符串 → 原样用于 `MATCH,...`。
- `**/opt/sub-api/sub-api.env`**：`SUB_PUBLIC_DOMAIN`、`XRAY_CONFIG`、`SINGBOX_CONFIG`、`XRAY_API_PORT`、`SINGBOX_CLASH_API`（可选）。

## 流量统计说明

- **Xray**：依赖客户端 `email` 与统计名 `user>>><uuid>>>traffic>>>`；脚本添加的 VLESS 用户已设置 `email=<uuid>`。
- **Hysteria2（sing-box）**：若面板未暴露兼容的 Clash traffic API，`vpn list` 中 H2 列可能为 `-`。可在 sing-box 中开启 `experimental.clash_api`，将 `http://127.0.0.1:端口` 写入 `SINGBOX_CLASH_API` 后重试。

## 故障排除：外网访问 `/sub` 返回 404，但本机 `curl 127.0.0.1:8080/sub` 正常

**不是防火墙问题。** 能返回 **404** 说明请求已经到达 Nginx；若端口被挡，一般是超时/连接拒绝。

常见原因：**mack-a / v2ray-agent** 在 **`/etc/nginx/conf.d/subscribe.conf`** 里用 **非 443 端口**（例如 **35172**）处理该域名的 HTTPS，而 `deploy.sh` 写在 `sites-enabled/sub-api` 里的是 **80 端口**。浏览器访问 `https://域名/sub` 时，命中的是 **subscribe.conf** 里那个 server，里面只有 `/s/...` 订阅路径，**没有** `/sub`，请求会落到空的 `location /` → **404**。

### 处理方式（二选一）

1. **重新跑一次部署脚本**（已内置 `patch_v2ray_subscribe_conf`，会给 `subscribe.conf` 打上 `/sub` 反代）：
   ```bash
   sudo bash deploy.sh vps.ooooxo.com
   ```

2. **只打补丁**（不重装 sub-api）：
   ```bash
   sudo bash patch-subscribe-nginx.sh vps.ooooxo.com
   ```

补丁会在 `location ~ ^/s/` **之前**插入：

```nginx
location /sub { proxy_pass http://127.0.0.1:8080; ... }
location /health { proxy_pass http://127.0.0.1:8080; ... }
```

### 若 HTTPS 不在 443

若面板或脚本把 TLS 开在 **35172** 等端口，订阅 URL 需带端口，例如：

`https://vps.ooooxo.com:35172/sub?token=...`

或用 `curl -k` 测：`curl -sI "https://127.0.0.1:35172/sub" --resolve vps.ooooxo.com:35172:127.0.0.1`

### 仍异常时

```bash
nginx -T 2>/dev/null | grep -n server_name | grep ooooxo
```

确认所有监听该域名的 `server { ... }` 里是否都有 `location /sub`。

## 安全

- 订阅 URL 含 token，请仅通过 HTTPS 分发。
- 定期 `vpn revoke` 不再使用的 token。

## 许可

MIT