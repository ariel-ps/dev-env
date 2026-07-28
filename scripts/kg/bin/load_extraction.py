#!/usr/bin/env python3
"""Load one extraction worker's output into the raw (pre-resolution) staging tables.

Usage:
    <worker's JSON> | load_extraction.py [--path SOURCE_PATH]

Input JSON must validate against schemas.ExtractedGraph:
    {"document": "apollo-11.txt",
     "entities":  [{"name": "...", "type": "PERSON", "description": "..."}],
     "relations": [{"source": "...", "predicate": "...", "target": "..."}]}

Re-running for the same document name replaces its raw rows (idempotent —
safe to re-extract after fixing a document or prompt).
"""
import argparse
import json
import sys

from db import get_conn
from schemas import ExtractedGraph


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", default=None, help="source path/URL to record on the document")
    args = ap.parse_args()

    raw = json.load(sys.stdin)
    graph = ExtractedGraph.model_validate(raw)

    conn = get_conn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """INSERT INTO documents (name, path) VALUES (%s, %s)
                   ON CONFLICT (name) DO UPDATE SET path = COALESCE(EXCLUDED.path, documents.path)
                   RETURNING id""",
                (graph.document, args.path),
            )
            doc_id = cur.fetchone()[0]

            # idempotent re-extraction: wipe this doc's prior raw rows first
            cur.execute("DELETE FROM raw_entities WHERE document_id = %s", (doc_id,))
            cur.execute("DELETE FROM raw_relations WHERE document_id = %s", (doc_id,))

            for e in graph.entities:
                cur.execute(
                    """INSERT INTO raw_entities (document_id, name, type, description)
                       VALUES (%s, %s, %s, %s)
                       ON CONFLICT (document_id, name, type) DO UPDATE
                       SET description = EXCLUDED.description""",
                    (doc_id, e.name, e.type, e.description),
                )
            for r in graph.relations:
                cur.execute(
                    """INSERT INTO raw_relations (document_id, source_name, predicate, target_name)
                       VALUES (%s, %s, %s, %s)""",
                    (doc_id, r.source, r.predicate, r.target),
                )
        print(json.dumps({
            "document_id": doc_id,
            "document": graph.document,
            "entities_loaded": len(graph.entities),
            "relations_loaded": len(graph.relations),
        }))
    finally:
        conn.close()


if __name__ == "__main__":
    main()
