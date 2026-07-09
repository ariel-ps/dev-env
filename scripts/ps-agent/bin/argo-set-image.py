#!/usr/bin/env python3
"""Surgically pin a service's image in a ps-argocd-dev-envs values.yaml.

Text-based on purpose (not a YAML round-trip): it edits only the target lines
so the file's formatting and comments stay byte-for-byte identical elsewhere,
producing a minimal git diff. A YAML round-tripper (yq/ruamel) reformats the
whole file and can't turn a commented-out block into real keys anyway.

Handles the three shapes a service's image block appears in:
  A) a real (possibly partial) block  ->  replace with the canonical 3 fields
  B) a fully commented-out block       ->  replace those comment lines
  C) no block at all                   ->  insert right after the service key

Usage:
  argo-set-image.py <values.yaml> <registry> <tag> <service:imageName> [...]
"""
import re
import sys

# Indentation in these files: allServices(2) -> service(4) -> field(6) -> sub(8).
SERVICE_INDENT = 4
IMAGE_INDENT = 6
FIELD_INDENT = 8


def block_lines(registry, name, tag):
    p = " " * IMAGE_INDENT
    f = " " * FIELD_INDENT
    return [
        f"{p}image:\n",
        f"{f}registry: {registry}\n",
        f"{f}name: {name}\n",
        f'{f}imageTag: "{tag}"\n',
    ]


def find_service(lines, svc):
    """Return (start, end) line range of the service block, or None."""
    key = re.compile(r"^ {%d}%s:\s*$" % (SERVICE_INDENT, re.escape(svc)))
    start = next((i for i, l in enumerate(lines) if key.match(l)), None)
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        l = lines[j]
        if not l.strip():
            continue
        indent = len(l) - len(l.lstrip(" "))
        if indent <= SERVICE_INDENT:
            end = j
            break
    return start, end


def pin(lines, svc, name, registry, tag):
    span = find_service(lines, svc)
    if span is None:
        sys.exit(f"argo-set-image: service '{svc}' not found under allServices")
    start, end = span
    new = block_lines(registry, name, tag)

    real = re.compile(r"^ {%d}image:\s*$" % IMAGE_INDENT)
    commented = re.compile(r"^ {%d}#\s*image:\s*$" % IMAGE_INDENT)

    # Case A: an existing real image: block -> replace it wholesale.
    for i in range(start + 1, end):
        if real.match(lines[i]):
            k = i + 1
            while k < end:
                l = lines[k]
                if not l.strip():
                    break
                indent = len(l) - len(l.lstrip(" "))
                if indent >= FIELD_INDENT and not l.lstrip().startswith("#"):
                    k += 1
                else:
                    break
            return lines[:i] + new + lines[k:]

    # Case B: a commented-out image: block -> replace the comment lines.
    for i in range(start + 1, end):
        if commented.match(lines[i]):
            k = i + 1
            while k < end and re.match(r"^ {%d}#" % IMAGE_INDENT, lines[k]) \
                    and re.search(r"registry|name|imageTag", lines[k]):
                k += 1
            return lines[:i] + new + lines[k:]

    # Case C: no image block -> insert right after the service key line.
    return lines[:start + 1] + new + lines[start + 1:]


def main(argv):
    if len(argv) < 5:
        sys.exit("usage: argo-set-image.py <values.yaml> <registry> <tag> "
                 "<service:imageName> [...]")
    path, registry, tag, specs = argv[1], argv[2], argv[3], argv[4:]
    with open(path) as fh:
        lines = fh.readlines()
    for spec in specs:
        svc, _, name = spec.partition(":")
        name = name or svc
        lines = pin(lines, svc, name, registry, tag)
    with open(path, "w") as fh:
        fh.writelines(lines)


if __name__ == "__main__":
    main(sys.argv)
