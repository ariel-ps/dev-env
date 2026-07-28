#!/usr/bin/env python3
"""Rewrite every raw_relation endpoint to its canonical entity and load it.

Usage: assemble_relations.py

Idempotent and safe to re-run any time after new documents/resolutions land
(unresolved endpoints are simply skipped and reported — run resolution for
the missing type/name and re-run this). Recomputes entities.degree after
loading.
"""
import json

from db import get_conn


def main():
    conn = get_conn()
    loaded = 0
    skipped = []
    try:
        with conn, conn.cursor() as cur:
            # raw_relations.source_name/target_name are only unique within the
            # document they were extracted from — recover each endpoint's type
            # from raw_entities of that same document, then resolve via aliases.
            cur.execute("""
                SELECT rr.id, rr.document_id, rr.source_name, rr.predicate, rr.target_name
                FROM raw_relations rr
            """)
            rows = cur.fetchall()

            for rr_id, doc_id, source_name, predicate, target_name in rows:
                src_id = _resolve_endpoint(cur, doc_id, source_name)
                tgt_id = _resolve_endpoint(cur, doc_id, target_name)
                if src_id is None or tgt_id is None:
                    skipped.append({
                        "raw_relation_id": rr_id, "source": source_name,
                        "predicate": predicate, "target": target_name,
                        "reason": "source unresolved" if src_id is None else "target unresolved",
                    })
                    continue
                cur.execute(
                    """INSERT INTO relations (source_id, predicate, target_id, source_document_id)
                       VALUES (%s, %s, %s, %s)
                       ON CONFLICT (source_id, target_id, predicate, source_document_id) DO NOTHING""",
                    (src_id, predicate, tgt_id, doc_id),
                )
                if cur.rowcount:
                    loaded += 1

            cur.execute("""
                UPDATE entities e SET degree = sub.deg
                FROM (
                    SELECT id, COUNT(*) AS deg FROM (
                        SELECT source_id AS id FROM relations
                        UNION ALL
                        SELECT target_id AS id FROM relations
                    ) x GROUP BY id
                ) sub
                WHERE e.id = sub.id
            """)
            cur.execute("UPDATE entities SET degree = 0 WHERE id NOT IN (SELECT source_id FROM relations UNION SELECT target_id FROM relations)")
    finally:
        conn.close()

    print(json.dumps({"relations_loaded": loaded, "skipped": skipped}, indent=2))


def _resolve_endpoint(cur, doc_id, name):
    cur.execute(
        """SELECT a.entity_id FROM raw_entities re
           JOIN aliases a ON a.type = re.type AND a.alias = re.name
           WHERE re.document_id = %s AND re.name = %s
           LIMIT 1""",
        (doc_id, name),
    )
    row = cur.fetchone()
    return row[0] if row else None


if __name__ == "__main__":
    main()
