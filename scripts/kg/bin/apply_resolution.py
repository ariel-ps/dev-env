#!/usr/bin/env python3
"""Apply a resolution worker's clustering into entities/aliases.

Usage: <worker's JSON> | apply_resolution.py

Input JSON must validate against schemas.ResolvedClusters:
    {"type": "PERSON",
     "clusters": [{"canonical": "Neil Alden Armstrong",
                    "aliases": ["Neil Armstrong", "Neil Alden Armstrong", "Armstrong"]}]}

For each cluster: reuse the existing entity if its canonical name (or any of
its aliases) already exists for this type, otherwise insert a new entity.
Every alias in the cluster is attached to that entity. An alias that already
points at a DIFFERENT entity is a resolver conflict — printed as a warning,
not silently overwritten (per the playbook's "two failure modes" guidance:
silent loss and over-merging are both worth surfacing, not swallowing).
"""
import json
import sys

from db import get_conn
from schemas import ResolvedClusters


def main():
    payload = ResolvedClusters.model_validate(json.load(sys.stdin))
    conflicts = []
    new_entities = 0
    reused_entities = 0
    aliases_added = 0

    conn = get_conn()
    try:
        with conn, conn.cursor() as cur:
            for cluster in payload.clusters:
                entity_id = None

                # does the canonical name already exist for this type?
                cur.execute(
                    "SELECT id FROM entities WHERE type = %s AND canonical_name = %s",
                    (payload.type, cluster.canonical),
                )
                row = cur.fetchone()
                if row:
                    entity_id = row[0]

                # does any alias in this cluster already resolve to an entity?
                if entity_id is None:
                    cur.execute(
                        "SELECT DISTINCT entity_id FROM aliases WHERE type = %s AND alias = ANY(%s)",
                        (payload.type, cluster.aliases),
                    )
                    hits = [r[0] for r in cur.fetchall()]
                    if len(hits) == 1:
                        entity_id = hits[0]
                    elif len(hits) > 1:
                        conflicts.append({
                            "cluster": cluster.canonical,
                            "reason": "aliases already split across multiple entities",
                            "entity_ids": hits,
                        })
                        continue  # don't guess; leave for a human/re-resolve pass

                if entity_id is None:
                    cur.execute(
                        "INSERT INTO entities (canonical_name, type) VALUES (%s, %s) RETURNING id",
                        (cluster.canonical, payload.type),
                    )
                    entity_id = cur.fetchone()[0]
                    new_entities += 1
                else:
                    reused_entities += 1

                for alias in set(cluster.aliases) | {cluster.canonical}:
                    cur.execute(
                        """INSERT INTO aliases (entity_id, type, alias) VALUES (%s, %s, %s)
                           ON CONFLICT (type, alias) DO NOTHING""",
                        (entity_id, payload.type, alias),
                    )
                    if cur.rowcount:
                        aliases_added += 1
                    else:
                        cur.execute(
                            "SELECT entity_id FROM aliases WHERE type = %s AND alias = %s",
                            (payload.type, alias),
                        )
                        existing_owner = cur.fetchone()[0]
                        if existing_owner != entity_id:
                            conflicts.append({
                                "alias": alias, "type": payload.type,
                                "reason": "already claimed by a different entity",
                                "claimed_by": existing_owner, "attempted_by": entity_id,
                            })
    finally:
        conn.close()

    print(json.dumps({
        "type": payload.type,
        "new_entities": new_entities,
        "reused_entities": reused_entities,
        "aliases_added": aliases_added,
        "conflicts": conflicts,
    }, indent=2))
    if conflicts:
        sys.exit(2)


if __name__ == "__main__":
    main()
