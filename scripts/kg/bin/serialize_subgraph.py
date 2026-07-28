#!/usr/bin/env python3
"""Serialize the k-hop neighborhood of a seed entity as provenance-carrying triples.

Usage: serialize_subgraph.py --seed-id ID [--hops 2] [--json]

Mirrors the playbook's serialize_subgraph() (Appendix E) but as one
recursive SQL query instead of an in-memory NetworkX BFS (Section IX.D's
scaling note: the schema maps straight onto recursive CTEs at this size).

Prints triple lines by default:
    (Neil Armstrong) --[walked on]--> (Moon)  [source: neil-armstrong.txt]
Pass --json for a machine-readable form (for feeding to a query/ask worker
alongside the question, or for a downstream evaluator to verify citations).
"""
import argparse
import json

from db import get_conn


SUBGRAPH_SQL = """
WITH RECURSIVE frontier(id, depth) AS (
    SELECT %(seed)s::int, 0
    UNION
    SELECT CASE WHEN r.source_id = f.id THEN r.target_id ELSE r.source_id END, f.depth + 1
    FROM relations r
    JOIN frontier f ON r.source_id = f.id OR r.target_id = f.id
    WHERE f.depth < %(hops)s
)
SELECT DISTINCT id FROM frontier
"""

EDGES_SQL = """
SELECT es.canonical_name AS source, r.predicate, et.canonical_name AS target,
       d.name AS source_document
FROM relations r
JOIN entities es ON es.id = r.source_id
JOIN entities et ON et.id = r.target_id
LEFT JOIN documents d ON d.id = r.source_document_id
WHERE r.source_id = ANY(%(nodes)s) AND r.target_id = ANY(%(nodes)s)
ORDER BY es.canonical_name, r.predicate, et.canonical_name
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed-id", type=int, required=True, help="entity id from find_entity.py")
    ap.add_argument("--hops", type=int, default=2)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(SUBGRAPH_SQL, {"seed": args.seed_id, "hops": args.hops})
            nodes = [r[0] for r in cur.fetchall()]
            if not nodes:
                print("[]" if args.json else "")
                return
            cur.execute(EDGES_SQL, {"nodes": nodes})
            edges = [
                {"source": s, "predicate": p, "target": t, "source_document": d}
                for s, p, t, d in cur.fetchall()
            ]
    finally:
        conn.close()

    if args.json:
        print(json.dumps(edges, indent=2))
    else:
        for e in edges:
            doc = f"  [source: {e['source_document']}]" if e["source_document"] else ""
            print(f"({e['source']}) --[{e['predicate']}]--> ({e['target']}){doc}")


if __name__ == "__main__":
    main()
