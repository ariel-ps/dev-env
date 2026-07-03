#!/usr/bin/env python3
"""Tail and pretty-print mitm_capture.jsonl with extended connection info."""
import sys
import json
import subprocess
from urllib.parse import unquote_plus

LOG_PATH = "/Users/Shared/.prompt_security/mitm_capture.jsonl"

SKIP_URLS = ("anthropic", "169.254")


def fmt_entry(e):
    url = e.get("url", "")
    if any(s in url for s in SKIP_URLS):
        return

    t = e["type"]
    method = e.get("method", "")
    status = e.get("status", "")
    app = e.get("would_inspect_app") or "-"

    client_conn = e.get("client_conn_id", "")
    server_conn = e.get("server_conn_id", "")
    http_ver = e.get("http_version", "")
    tls = e.get("tls_established", "")

    rpcid = url.split("rpcids=")[1].split("&")[0] if "rpcids=" in url else ""

    body = e.get("body", "")
    decoded = ""
    if "f.req=" in body:
        decoded = unquote_plus(body.split("f.req=")[1].split("&")[0])[:300]

    label = f"[{t[:3]}] {method:4} {str(status):3}  app={app:15}  {url[:80]}"
    print(label)

    conn_info = []
    if client_conn:
        conn_info.append(f"client_conn={client_conn[:8]}")
    if server_conn:
        conn_info.append(f"server_conn={server_conn[:8]}")
    if http_ver:
        conn_info.append(f"http={http_ver}")
    if tls is not None:
        conn_info.append(f"tls={tls}")
    if conn_info:
        print("       " + "  ".join(conn_info))

    if rpcid:
        print(f"       rpcid={rpcid}")
    if decoded and len(decoded) > 20:
        print(f"       body: {decoded[:250]}")
    print()


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else LOG_PATH
    proc = subprocess.Popen(["tail", "-f", path], stdout=subprocess.PIPE, text=True)
    try:
        for line in proc.stdout:
            try:
                e = json.loads(line.strip())
                fmt_entry(e)
            except Exception:
                pass
    except KeyboardInterrupt:
        proc.terminate()


if __name__ == "__main__":
    main()
