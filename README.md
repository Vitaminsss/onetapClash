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
2. 将程序安装到 `/opt/sub-api/`，并安装 `vpn`、`sub-api-stop`
3. 自动探测常见路径下的 `Xray`、`sing-box` 主配置，写入 `/opt/sub-api/sub-api.env`，并用 **jq** 生成 `/opt/sub-api/server.json`（与旧版 `discover.py` 逻辑一致）
4. 向 Xray 注入 `stats` + `api`（默认 `127.0.0.1:10085`）与 `policy.levels.0` 用户统计
5. 配置 Nginx：`/sub` → `127.0.0.1:8080`，并申请 HTTPS；若存在 v2ray-agent 的 `alone.conf` / `subscribe.conf`，会幂等插入 `/sub`、`/health` 反代
6. 注册 systemd 服务 `sub-api`
7. 创建首个用户

部署完成后，将输出的 **订阅 URL** 填入 Clash Verge。

## 命令

| 命令 | 说明 |
| --- | --- |
| `vpn create [备注]` | 新用户：生成 token + UUID，写入 Xray VLESS 与 sing-box Hysteria2 |
| `vpn list` | 列出用户；**Xray↑/↓** 为 VLESS（Vision+Reality）统计；**H2↑/↓** 需配置 `SINGBOX_CLASH_API` 时尝试拉取 |
| `vpn revoke <token>` | 吊销并从配置中删除该 UUID |
| `vpn status` | `sub-api` 服务状态 |
| `vpn reload` | 重启 Xray/sing-box（若存在）与 `sub-api` |
| `sudo sub-api-stop` | 仅停止订阅 API 服务 `sub-api`（不停止 nginx / 核心） |

## 配置说明

- **`/opt/sub-api/server.json`**：域名、各协议端口、REALITY `public_key` / `short_id` 等。部署时由 `deploy.sh` 从现有配置推断，请按需手改后执行 `vpn reload`。
- **分流规则**：订阅中的 `proxy-groups`、`dns`、`rules` 由 [app.py](app.py) 模板生成。说明文档中曾描述在 `server.json` 增加 `routing` 以调整 `MATCH`；若需该能力，须在 `app.py` 中读取并实现（当前未实现）。
- **`/opt/sub-api/sub-api.env`**：`SUB_PUBLIC_DOMAIN`、`XRAY_CONFIG`、`SINGBOX_CONFIG`、`XRAY_API_PORT`、`SINGBOX_CLASH_API`（可选）。

## 流量统计说明

- **Xray**：依赖客户端 `email` 与统计名 `user>>><uuid>>>traffic>>>`；脚本添加的 VLESS 用户已设置 `email=<uuid>`。
- **Hysteria2（sing-box）**：若面板未暴露兼容的 Clash traffic API，`vpn list` 中 H2 列可能为 `-`。可在 sing-box 中开启 `experimental.clash_api`，将 `http://127.0.0.1:端口` 写入 `SINGBOX_CLASH_API` 后重试。

## 故障排除：外网 `/sub` 404，本机 `curl 127.0.0.1:8080/sub` 正常

常见于 v2ray-agent 多套 Nginx `server`（例如 443 与非常规 HTTPS 端口）未统一反代。请先 **重新执行** `sudo bash deploy.sh <域名>`（脚本会再次尝试修补 `alone.conf` / `subscribe.conf`），再用 `nginx -T` 确认所有监听该域名的 `server` 块均包含 `location /sub`。

## 安全

- 订阅 URL 含 token，请仅通过 HTTPS 分发。
- 定期 `vpn revoke` 不再使用的 token。

## 许可

MIT
