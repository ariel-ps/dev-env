#!/usr/bin/env python3
"""Print the input a resolution worker needs for one entity type.

Usage: pending_resolution.py TYPE

Emits JSON: {"type": TYPE, "existing": [{"canonical": ..., "description": ...}],
             "unresolved": [{"name": ..., "description": ...}]}

"existing" are already-canonicalized entities of this type (their summary or,
absent that, their oldest raw description) — anchors so new raw names can
join an existing cluster instead of forking a duplicate. "unresolved" are raw
names of this type with no alias row yet (never resolved, or added since the
last resolve pass — this is what makes incremental updates cheap: only new
names get sent to the resolver, per playbook Section IX.C).

If "unresolved" is empty there is nothing to resolve for this type.
"""
import json
import sys

from db import get_conn


def main():
    if len(sys.argv) != 2:
        print("usage: pending_resolution.py TYPE", file=sys.stderr)
        sys.exit(1)
    etype = sys.argv[1]

    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """SELECT canonical_name, summary FROM entities WHERE type = %s
                   ORDER BY canonical_name""",
                (etype,),
            )
            existing = [{"canonical": row[0], "description": row[1] or ""} for row in cur.fetchall()]

            cur.execute(
                """SELECT DISTINCT re.name, re.description
                   FROM raw_entities re
                   WHERE re.type = %s
                     AND NOT EXISTS (
                       SELECT 1 FROM aliases a WHERE a.type = re.type AND a.alias = re.name
                     )
                   ORDER BY re.name""",
                (etype,),
            )
            unresolved = [{"name": row[0], "description": row[1]} for row in cur.fetchall()]
    finally:
        conn.close()

    print(json.dumps({"type": etype, "existing": existing, "unresolved": unresolved}, indent=2))


if __name__ == "__main__":
    main()
