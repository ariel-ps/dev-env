#!/usr/bin/env python3
"""Graph diagnostics (playbook Section V.E / IX.F monitoring signals).

Usage: stats.py

Reports: entity/relation counts, resolution compression ratio (raw surface
forms / canonical entities — near 1.0 means resolution is doing little,
above 2.0 means heavy naming variation), degree distribution, and connected
components (a growing count of small components suggests resolution is
missing cross-document links that should have merged).
"""
import json

from db import get_conn


def main():
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM documents")
            n_docs = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM entities")
            n_entities = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM relations")
            n_relations = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM aliases")
            n_aliases = cur.fetchone()[0]

            compression_ratio = round(n_aliases / n_entities, 2) if n_entities else None
            density_ratio = round(n_relations / n_entities, 2) if n_entities else None

            cur.execute("SELECT degree, COUNT(*) FROM entities GROUP BY degree ORDER BY degree DESC")
            degree_hist = {str(d): c for d, c in cur.fetchall()}

            cur.execute("SELECT id FROM entities")
            all_ids = [r[0] for r in cur.fetchall()]
            cur.execute("SELECT source_id, target_id FROM relations")
            edges = cur.fetchall()

            components = _connected_components(all_ids, edges)
    finally:
        conn.close()

    print(json.dumps({
        "documents": n_docs,
        "entities": n_entities,
        "relations": n_relations,
        "aliases": n_aliases,
        "resolution_compression_ratio": compression_ratio,
        "density_ratio_relations_per_entity": density_ratio,
        "degree_histogram": degree_hist,
        "connected_components": len(components),
        "largest_component_size": max((len(c) for c in components), default=0),
        "isolated_entities": sum(1 for c in components if len(c) == 1),
    }, indent=2))


def _connected_components(node_ids, edges):
    parent = {n: n for n in node_ids}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    for s, t in edges:
        union(s, t)

    groups = {}
    for n in node_ids:
        groups.setdefault(find(n), []).append(n)
    return list(groups.values())


if __name__ == "__main__":
    main()
