#!/usr/bin/env python3
"""Fuzzy-find candidate seed entities by name fragment.

Usage: find_entity.py "armstrong"

Prints JSON list of {"id", "canonical_name", "type", "degree", "matched_alias"}
sorted by degree descending (hub nodes first), for picking a query seed.
"""
import json
import sys

from db import get_conn


def main():
    if len(sys.argv) != 2:
        print("usage: find_entity.py NAME_FRAGMENT", file=sys.stderr)
        sys.exit(1)
    fragment = sys.argv[1]

    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """SELECT DISTINCT e.id, e.canonical_name, e.type, e.degree, a.alias
                   FROM aliases a JOIN entities e ON e.id = a.entity_id
                   WHERE a.alias ILIKE %s
                   ORDER BY e.degree DESC, e.canonical_name""",
                (f"%{fragment}%",),
            )
            results = [
                {"id": r[0], "canonical_name": r[1], "type": r[2], "degree": r[3], "matched_alias": r[4]}
                for r in cur.fetchall()
            ]
    finally:
        conn.close()

    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
