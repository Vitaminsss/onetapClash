#!/usr/bin/env python3
"""
Patch v2ray-agent nginx configs so /sub proxies to sub-api (127.0.0.1:8080).

1) alone.conf — server blocks with real_ip_header proxy_protocol (443 fallback → nginx).
2) subscribe.conf — before location ~ ^/s/ or before empty location /.

Idempotent: safe to run multiple times.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def _make_snippet(indent: str) -> str:
    """indent = leading whitespace before `location` lines in this file."""
    i = indent + "    "
    return (
        f"{indent}location /sub {{\n"
        f"{i}proxy_pass http://127.0.0.1:8080;\n"
        f"{i}proxy_set_header Host $host;\n"
        f"{i}proxy_set_header X-Real-IP $remote_addr;\n"
        f"{i}proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
        f"{i}proxy_set_header X-Forwarded-Proto $scheme;\n"
        f"{indent}}}\n"
        f"{indent}location /health {{\n"
        f"{i}proxy_pass http://127.0.0.1:8080;\n"
        f"{i}proxy_set_header Host $host;\n"
        f"{indent}}}\n"
    )


def patch_alone_conf(text: str) -> tuple[str, bool]:
    """Insert /sub before catch-all `location /` in proxy_protocol server blocks."""
    marker = "real_ip_header proxy_protocol"
    if marker not in text:
        return text, False

    out = text
    changed = False
    search_from = 0
    while True:
        i = out.find(marker, search_from)
        if i == -1:
            break
        sub = out[i:]
        m = re.search(r"^(\s*)location /\s*\{\s*$", sub, re.MULTILINE)
        if not m:
            search_from = i + len(marker)
            continue
        rel_start = m.start()
        j = i + rel_start
        segment = out[i:j]
        if "location /sub" in segment:
            search_from = i + len(marker)
            continue
        indent = m.group(1)
        snippet = _make_snippet(indent)
        out = out[:j] + snippet + out[j:]
        changed = True
        search_from = j + len(snippet)

    return out, changed


def patch_subscribe_conf(text: str) -> tuple[str, bool]:
    """Insert /sub before v2ray subscribe regex or catch-all location /."""
    if "location /sub" in text:
        return text, False

    snippet = _make_snippet("    ")
    mark = "location ~ ^/s/"
    if mark in text:
        idx = text.index(mark)
        return text[:idx] + snippet + text[idx:], True
    idx = text.find("    location / {")
    if idx != -1:
        return text[:idx] + snippet + text[idx:], True
    return text, False


def main() -> int:
    alone = Path("/etc/nginx/conf.d/alone.conf")
    sub = Path("/etc/nginx/conf.d/subscribe.conf")
    any_change = False

    if alone.is_file():
        t = alone.read_text(encoding="utf-8")
        new_t, ch = patch_alone_conf(t)
        if ch:
            alone.write_text(new_t, encoding="utf-8")
            print(f"patched {alone}", file=sys.stderr)
            any_change = True

    if sub.is_file():
        t = sub.read_text(encoding="utf-8")
        new_t, ch = patch_subscribe_conf(t)
        if ch:
            sub.write_text(new_t, encoding="utf-8")
            print(f"patched {sub}", file=sys.stderr)
            any_change = True

    if not alone.is_file() and not sub.is_file():
        print("no alone.conf or subscribe.conf found", file=sys.stderr)
        return 1

    if not any_change:
        print("already patched or nothing to do", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
