#!/usr/bin/env python3
"""
Convert mitmproxy capture files (.mitm / .flow) to JSONL.

Each output line is one JSON object representing an HTTP flow:
  { id, timestamp_start, request: {...}, response: {...} | null }

Body decoding priority: JSON → UTF-8 text → base64.

Usage:
    mitm-to-jsonl capture.mitm                    # stdout
    mitm-to-jsonl capture.mitm -o out.jsonl       # file
    mitm-to-jsonl a.mitm b.mitm -o combined.jsonl # multiple inputs
    cat capture.mitm | mitm-to-jsonl -            # stdin
"""

import argparse
import base64
import json
import sys

from mitmproxy.http import HTTPFlow
from mitmproxy.io import FlowReader


def decode_body(content: bytes | None) -> str | dict | list | None:
    if not content:
        return None
    try:
        parsed = json.loads(content)
        return parsed
    except Exception:
        pass
    try:
        return content.decode("utf-8")
    except Exception:
        return base64.b64encode(content).decode("ascii")


def headers_to_dict(headers) -> dict:
    result = {}
    for k, v in headers.items():
        key = k.lower()
        if key in result:
            existing = result[key]
            result[key] = existing if isinstance(existing, list) else [existing]
            result[key].append(v)
        else:
            result[key] = v
    return result


def flow_to_dict(flow: HTTPFlow) -> dict:
    req = flow.request
    record = {
        "id": flow.id,
        "type": flow.type,
        "timestamp_start": flow.timestamp_start,
        "request": {
            "timestamp": req.timestamp_start,
            "method": req.method,
            "scheme": req.scheme,
            "host": req.pretty_host,
            "port": req.port,
            "path": req.path,
            "url": req.pretty_url,
            "http_version": req.http_version,
            "headers": headers_to_dict(req.headers),
            "body": decode_body(req.content),
        },
        "response": None,
    }

    if flow.response:
        resp = flow.response
        record["response"] = {
            "timestamp": resp.timestamp_start,
            "status_code": resp.status_code,
            "reason": resp.reason,
            "http_version": resp.http_version,
            "headers": headers_to_dict(resp.headers),
            "body": decode_body(resp.content),
        }

    return record


def convert(input_stream, out):
    reader = FlowReader(input_stream)
    count = 0
    for flow in reader.stream():
        if not isinstance(flow, HTTPFlow):
            continue
        out.write(json.dumps(flow_to_dict(flow), ensure_ascii=False))
        out.write("\n")
        count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description="Convert mitmproxy captures to JSONL")
    parser.add_argument("inputs", nargs="+", metavar="FILE",
                        help="mitmproxy capture file(s); use - for stdin")
    parser.add_argument("-o", "--output", metavar="FILE",
                        help="output file (default: stdout)")
    args = parser.parse_args()

    out = open(args.output, "w", encoding="utf-8") if args.output else sys.stdout

    total = 0
    try:
        for path in args.inputs:
            if path == "-":
                total += convert(sys.stdin.buffer, out)
            else:
                with open(path, "rb") as f:
                    total += convert(f, out)
    finally:
        if args.output:
            out.close()

    if args.output:
        print(f"Wrote {total} flows → {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
