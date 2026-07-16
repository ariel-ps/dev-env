#!/usr/bin/env python3
"""Capture the SAMLResponse the IdP POSTs during an AWS Client VPN login.

The AWS Client VPN SAML flow redirects the browser to the identity provider;
on success the IdP POSTs `SAMLResponse=<url-encoded base64>` back to
http://127.0.0.1:<port>/ . This tiny server binds that port, waits for the
POST, prints the (url-decoded) SAMLResponse to stdout, and exits 0.

Usage: aws-saml-capture.py [port] [timeout_seconds]
       defaults: port 35001, timeout 180
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 35001
TIMEOUT = int(sys.argv[2]) if len(sys.argv) > 2 else 180

result = {}

_DONE_PAGE = (
    b"<!doctype html><html><head><meta charset='utf-8'>"
    b"<title>AWS VPN</title></head><body style='font-family:sans-serif'>"
    b"<h2>Authentication received.</h2>"
    b"<p>You can close this tab and return to the terminal.</p>"
    b"</body></html>"
)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 (http.server API)
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        # parse_qs handles form-encoding: '+' -> space, %xx decoded, so real
        # base64 '+' (sent as %2B) survives intact.
        saml = parse_qs(body).get("SAMLResponse", [""])[0]
        if saml:
            result["saml"] = saml
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(_DONE_PAGE)

    def do_GET(self):  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"waiting for SAML POST")

    def log_message(self, *_args):  # silence request logging
        pass


def main():
    httpd = HTTPServer(("127.0.0.1", PORT), Handler)
    httpd.timeout = 5
    deadline = time.monotonic() + TIMEOUT
    while "saml" not in result and time.monotonic() < deadline:
        httpd.handle_request()  # returns after a request or the 5s timeout
    if result.get("saml"):
        sys.stdout.write(result["saml"])
        sys.stdout.flush()
        return 0
    sys.stderr.write("aws-saml-capture: timed out waiting for SAMLResponse\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
