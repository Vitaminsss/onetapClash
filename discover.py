#!/usr/bin/env python3
"""Best-effort discovery of server.json fields from local Xray / sing-box JSON."""
from __future__ import annotations

import json
import sys
from pathlib import Path


def load(p: Path) -> dict | list | None:
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def walk(obj, pred):
    if isinstance(obj, dict):
        if pred(obj):
            yield obj
        for v in obj.values():
            yield from walk(v, pred)
    elif isinstance(obj, list):
        for x in obj:
            yield from walk(x, pred)


def discover_xray(path: Path, domain_hint: str) -> dict:
    data = load(path)
    out = {
        "domain": domain_hint,
        "vless_tls": {"port": 443, "sni": domain_hint, "flow": "xtls-rprx-vision"},
        "vless_reality": {
            "port": 8888,
            "sni": domain_hint,
            "public_key": "",
            "short_id": "",
            "flow": "xtls-rprx-vision",
        },
    }
    if not isinstance(data, dict):
        return out
    inbounds = data.get("inbounds") or []
    for ib in inbounds:
        if not isinstance(ib, dict):
            continue
        if ib.get("protocol") != "vless":
            continue
        port = ib.get("port")
        st = ib.get("streamSettings") or {}
        sec = (st.get("security") or "").lower()
        reality = st.get("realitySettings") or {}
        sni = None
        if isinstance(st.get("tlsSettings"), dict):
            sni = (st["tlsSettings"].get("serverName") or [None])[0] if isinstance(
                st["tlsSettings"].get("serverName"), list
            ) else st["tlsSettings"].get("serverName")
        if sec == "reality" or reality:
            if port:
                out["vless_reality"]["port"] = int(port)
            if reality.get("serverNames"):
                sn = reality["serverNames"]
                if isinstance(sn, list) and sn:
                    out["vless_reality"]["sni"] = sn[0]
            pbk = reality.get("publicKey") or reality.get("public_key")
            if pbk:
                out["vless_reality"]["public_key"] = pbk
            sid = reality.get("shortIds") or reality.get("short_ids")
            if isinstance(sid, list) and sid:
                out["vless_reality"]["short_id"] = sid[0]
            elif isinstance(sid, str):
                out["vless_reality"]["short_id"] = sid
        else:
            if port:
                out["vless_tls"]["port"] = int(port)
            if sni:
                out["vless_tls"]["sni"] = sni
    return out


def discover_singbox(path: Path, domain_hint: str) -> dict:
    data = load(path)
    out = {"hysteria2": {"port": 8443, "sni": domain_hint, "alpn": ["h3"]}}
    if not isinstance(data, dict):
        return out
    for ib in walk(data, lambda o: isinstance(o, dict) and o.get("type") == "hysteria2"):
        lp = ib.get("listen_port") or ib.get("port")
        if lp:
            out["hysteria2"]["port"] = int(lp)
        tls = ib.get("tls") or {}
        if isinstance(tls, dict) and tls.get("server_name"):
            out["hysteria2"]["sni"] = tls["server_name"]
        break
    return out


def main():
    domain = sys.argv[1] if len(sys.argv) > 1 else "example.com"
    xray_path = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] not in ("", "-") else None
    sing_path = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] not in ("", "-") else None

    merged: dict = {"domain": domain}
    if xray_path is not None and xray_path.is_file():
        merged.update(discover_xray(xray_path, domain))
    else:
        merged.update(
            {
                "vless_tls": {"port": 443, "sni": domain, "flow": "xtls-rprx-vision"},
                "vless_reality": {
                    "port": 8888,
                    "sni": domain,
                    "public_key": "",
                    "short_id": "",
                    "flow": "xtls-rprx-vision",
                },
            }
        )
    if sing_path is not None and sing_path.is_file():
        merged["hysteria2"] = discover_singbox(sing_path, domain)["hysteria2"]
    else:
        merged["hysteria2"] = {
            "port": 9999,
            "sni": domain,
            "alpn": ["h3"],
        }
    print(json.dumps(merged, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
