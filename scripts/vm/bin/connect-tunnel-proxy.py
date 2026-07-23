"""Minimal HTTP CONNECT-tunnel proxy. Forwards HTTPS via CONNECT; no MITM.

Use case: a VM (or other host) without outbound HTTPS, where you still want
pip / app traffic to reach the internet. Run this on a host that *does*
have internet, bound to the interface the VM can reach (e.g. the host's
private NAT address). Then from the VM:

    HTTPS_PROXY=http://<host-ip>:8888 pip install ...

Handles only CONNECT (HTTPS tunneling). Plain HTTP via this proxy will get
405 Method Not Allowed — pip doesn't need that path, and most modern
clients use HTTPS anyway.

LISTEN_HOST / LISTEN_PORT can be overridden via the VM_PROXY_HOST /
VM_PROXY_PORT environment variables (the `vm` dev-env profile sets these).
"""
import os
import socket
import threading
import sys

LISTEN_HOST = os.environ.get("VM_PROXY_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("VM_PROXY_PORT", "8888"))
BUF = 65536


def pipe(a: socket.socket, b: socket.socket):
    try:
        while True:
            data = a.recv(BUF)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client: socket.socket, addr):
    try:
        client.settimeout(15)
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = client.recv(BUF)
            if not chunk:
                return
            head += chunk
            if len(head) > 16384:
                return
        client.settimeout(None)
        first_line = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = first_line.split()
        if len(parts) < 3 or parts[0].upper() != "CONNECT":
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            return
        host, _, port = parts[1].partition(":")
        port = int(port or "443")
        try:
            upstream = socket.create_connection((host, port), timeout=15)
        except OSError as exc:
            client.sendall(f"HTTP/1.1 502 Bad Gateway\r\n\r\n{exc}".encode())
            return
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        t1 = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
        t2 = threading.Thread(target=pipe, args=(upstream, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
        upstream.close()
    finally:
        try:
            client.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_HOST, LISTEN_PORT))
    srv.listen(64)
    print(f"CONNECT proxy listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    while True:
        client, addr = srv.accept()
        threading.Thread(target=handle, args=(client, addr), daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
