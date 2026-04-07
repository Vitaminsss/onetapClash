#!/usr/bin/env python3
"""
Clash Meta subscription API for /opt/sub-api
GET /sub?token=... -> full Clash YAML with per-token UUID
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import yaml
from flask import Flask, abort, request

BASE = Path(__file__).resolve().parent
TOKENS_FILE = BASE / "tokens.json"
SERVER_FILE = BASE / "server.json"


def load_json(path: Path, default):
    if not path.is_file():
        return default
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_server():
    data = load_json(SERVER_FILE, {})
    if not data.get("domain"):
        data["domain"] = "127.0.0.1"
    return data


def find_token_entry(token: str | None):
    if not token:
        return None
    tokens = load_json(TOKENS_FILE, [])
    for row in tokens:
        if row.get("token") == token:
            return row
    return None


def build_proxies(domain: str, srv: dict, user_uuid: str) -> list[dict]:
    """Build three proxies (Hysteria2, VLESS TLS Vision, VLESS REALITY) for one UUID."""
    name_h2 = "🚀 Hysteria2 极速"
    name_vis = "⚡ VLESS Vision"
    name_rel = "🌐 VLESS Reality"

    h2 = srv.get("hysteria2") or {}
    vt = srv.get("vless_tls") or {}
    vr = srv.get("vless_reality") or {}

    proxies: list[dict] = [
        {
            "name": name_h2,
            "type": "hysteria2",
            "server": domain,
            "port": int(h2.get("port", 8443)),
            "password": user_uuid,
            "sni": h2.get("sni") or domain,
            "skip-cert-verify": bool(h2.get("skip-cert-verify", False)),
            "udp": True,
            "alpn": h2.get("alpn") or ["h3"],
        },
        {
            "name": name_vis,
            "type": "vless",
            "server": domain,
            "port": int(vt.get("port", 443)),
            "uuid": user_uuid,
            "tls": True,
            "servername": vt.get("sni") or domain,
            "sni": vt.get("sni") or domain,
            "skip-cert-verify": bool(vt.get("skip-cert-verify", False)),
            "client-fingerprint": vt.get("client-fingerprint") or "chrome",
            "network": "tcp",
            "udp": True,
            "flow": vt.get("flow") or "xtls-rprx-vision",
        },
        {
            "name": name_rel,
            "type": "vless",
            "server": domain,
            "port": int(vr.get("port", 8888)),
            "uuid": user_uuid,
            "tls": True,
            "servername": vr.get("sni") or domain,
            "sni": vr.get("sni") or domain,
            "client-fingerprint": vr.get("client-fingerprint") or "chrome",
            "network": "tcp",
            "udp": True,
            "flow": vr.get("flow") or "xtls-rprx-vision",
            "reality-opts": {
                "public-key": vr.get("public_key", ""),
                "short-id": vr.get("short_id", ""),
            },
            "skip-cert-verify": bool(vr.get("skip-cert-verify", False)),
        },
    ]
    return proxies


# 延迟测速 URL：用于 url-test / fallback 策略组
_URL_TEST_URL = "https://www.gstatic.com/generate_204"
_URL_TEST_INTERVAL = 300  # 秒


def build_proxy_groups(names: list[str]) -> list[dict]:
    """
    构建四个策略组，MATCH 指向「🚀 自动选择」：

    1. 🚀 自动选择（url-test）   — 测延迟后自动选最快节点，作为 MATCH 兜底
    2. 🛡 故障切换（fallback）   — 主节点挂了自动跳下一个
    3. 🔧 手动选择（select）     — 手动指定，「自动选择」排第一
    4. 📺 流媒体（select）       — 为流媒体域名单独选节点
    """
    auto_name = "🚀 自动选择"
    fallback_name = "🛡 故障切换"
    manual_name = "🔧 手动选择"
    media_name = "📺 流媒体"

    groups: list[dict] = []

    if len(names) > 1:
        groups.append(
            {
                "name": auto_name,
                "type": "url-test",
                "proxies": names,
                "url": _URL_TEST_URL,
                "interval": _URL_TEST_INTERVAL,
                "tolerance": 50,
                "lazy": True,
            }
        )
        groups.append(
            {
                "name": fallback_name,
                "type": "fallback",
                "proxies": names,
                "url": _URL_TEST_URL,
                "interval": _URL_TEST_INTERVAL,
            }
        )
        groups.append(
            {
                "name": manual_name,
                "type": "select",
                "proxies": [auto_name, fallback_name] + names + ["DIRECT"],
            }
        )
        groups.append(
            {
                "name": media_name,
                "type": "select",
                "proxies": [auto_name] + names + ["DIRECT"],
            }
        )
    else:
        # 只有一个节点时，自动选择 = 直接使用那个节点（不需要多余的 url-test 组）
        groups.append(
            {
                "name": manual_name,
                "type": "select",
                "proxies": names + ["DIRECT"],
            }
        )
        groups.append(
            {
                "name": media_name,
                "type": "select",
                "proxies": names + ["DIRECT"],
            }
        )

    return groups


def _match_target(names: list[str]) -> str:
    """MATCH 兜底：多节点走自动选择，单节点直接走那个节点。"""
    if len(names) > 1:
        return "🚀 自动选择"
    return names[0] if names else "DIRECT"


def build_clash_rules(match_target: str) -> list[str]:
    """局域网直连 → 流媒体分流 → 国内域名直连 → GEOIP CN → MATCH。"""
    return [
        "DOMAIN-SUFFIX,localhost,DIRECT",
        "IP-CIDR,127.0.0.0/8,DIRECT",
        "IP-CIDR,192.168.0.0/16,DIRECT",
        "IP-CIDR,10.0.0.0/8,DIRECT",
        "DOMAIN-SUFFIX,netflix.com,📺 流媒体",
        "DOMAIN-SUFFIX,nflxvideo.net,📺 流媒体",
        "DOMAIN-SUFFIX,youtube.com,📺 流媒体",
        "DOMAIN-SUFFIX,googlevideo.com,📺 流媒体",
        "DOMAIN-SUFFIX,spotify.com,📺 流媒体",
        "DOMAIN-SUFFIX,twitch.tv,📺 流媒体",
        "DOMAIN-SUFFIX,tiktok.com,📺 流媒体",
        "DOMAIN-SUFFIX,instagram.com,📺 流媒体",
        "DOMAIN-SUFFIX,baidu.com,DIRECT",
        "DOMAIN-SUFFIX,qq.com,DIRECT",
        "DOMAIN-SUFFIX,wechat.com,DIRECT",
        "DOMAIN-SUFFIX,weixin.qq.com,DIRECT",
        "DOMAIN-SUFFIX,bilibili.com,DIRECT",
        "DOMAIN-SUFFIX,taobao.com,DIRECT",
        "DOMAIN-SUFFIX,jd.com,DIRECT",
        "DOMAIN-SUFFIX,alicdn.com,DIRECT",
        "DOMAIN-SUFFIX,alipay.com,DIRECT",
        "DOMAIN-SUFFIX,163.com,DIRECT",
        "DOMAIN-SUFFIX,126.com,DIRECT",
        "DOMAIN-SUFFIX,zhihu.com,DIRECT",
        "DOMAIN-SUFFIX,csdn.net,DIRECT",
        "DOMAIN-SUFFIX,douyin.com,DIRECT",
        "DOMAIN-SUFFIX,weibo.com,DIRECT",
        "DOMAIN-SUFFIX,youku.com,DIRECT",
        "DOMAIN-SUFFIX,iqiyi.com,DIRECT",
        "DOMAIN-SUFFIX,mi.com,DIRECT",
        "DOMAIN-SUFFIX,huawei.com,DIRECT",
        "DOMAIN-SUFFIX,bytedance.com,DIRECT",
        "GEOIP,CN,DIRECT",
        f"MATCH,{match_target}",
    ]


def build_full_config(proxies: list[dict], srv: dict | None = None) -> dict:
    srv = srv or {}
    names = [p["name"] for p in proxies]
    groups = build_proxy_groups(names)
    match = _match_target(names)

    return {
        "proxies": proxies,
        "proxy-groups": groups,
        "dns": {
            "enable": True,
            "listen": "0.0.0.0:1053",
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "nameserver": [
                "https://doh.pub/dns-query",
                "https://dns.alidns.com/dns-query",
            ],
            "fallback": [
                "https://1.1.1.1/dns-query",
                "https://dns.google/dns-query",
            ],
            "fallback-filter": {
                "geoip": True,
                "geoip-code": "CN",
                "ipcidr": ["240.0.0.0/4"],
            },
            "default-nameserver": ["223.5.5.5", "119.29.29.29"],
        },
        "rules": build_clash_rules(match),
    }


app = Flask(__name__)


@app.get("/sub")
def subscription():
    token = request.args.get("token")
    entry = find_token_entry(token)
    if not entry:
        abort(403)
    user_uuid = entry.get("uuid")
    if not user_uuid:
        abort(500)

    srv = load_server()
    domain = srv.get("domain", "127.0.0.1")
    proxies = build_proxies(domain, srv, user_uuid)
    cfg = build_full_config(proxies, srv)

    text = yaml.safe_dump(
        cfg,
        allow_unicode=True,
        default_flow_style=False,
        sort_keys=False,
    )
    return text, 200, {"Content-Type": "text/yaml; charset=utf-8"}


@app.get("/health")
def health():
    return {"ok": True}


if __name__ == "__main__":
    host = os.environ.get("SUB_API_HOST", "127.0.0.1")
    port = int(os.environ.get("SUB_API_PORT", "8080"))
    app.run(host=host, port=port, threaded=True)
