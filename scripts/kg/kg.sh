#!/usr/bin/env zsh
# Knowledge-graph store — shared memory for multi-agent Claude sessions.
# Sourced by init.zsh. Backed by a local Postgres db ("kg"); schema and
# reasoning follow the Anthropic knowledge-graph playbook: extraction and
# resolution are done by Agent-tool worker subagents (orchestrator spawns
# them with the prompts in bin/PROMPTS.md), these functions are just the
# persistence layer those workers' JSON gets piped through.
#
# Typical flow from an orchestrating Claude session:
#   kg-init                                        # once
#   <spawn extraction worker on doc.txt>  -> json | kg-load doc.txt
#   kg-pending PERSON                              # -> feed to a resolution worker
#   <resolution worker output>            -> json | kg-resolve
#   kg-assemble                                    # wire raw_relations -> relations
#   kg-find "armstrong"                            # pick a seed entity id
#   kg-graph 3 --hops 2                            # serialize subgraph for a query worker
#   kg-stats

_KG_DIR="${0:A:h}"
_KG_BIN="$_KG_DIR/bin"

_kg_py() {
  command -v python3 >/dev/null 2>&1 || { echo "kg: python3 not found" >&2; return 1; }
  PYTHONPATH="$_KG_BIN${PYTHONPATH:+:$PYTHONPATH}" python3 "$_KG_BIN/$1" "${@:2}"
}

# usage: kg-init
#   Starts the local Postgres service if needed, creates the "kg" database
#   (no-op if it already exists), and applies schema.sql (idempotent).
kg-init() {
  command -v pg_ctl >/dev/null 2>&1 || { echo "kg-init: postgresql not installed (brew install postgresql@18)" >&2; return 1; }
  brew services list 2>/dev/null | grep -q '^postgresql@18 *started' \
    || brew services start postgresql@18
  createdb kg 2>/dev/null
  psql -d kg -f "$_KG_BIN/schema.sql"
}

# usage: <extraction-worker-json> | kg-load DOC_NAME [--path SOURCE_PATH]
#   Loads one worker's ExtractedGraph JSON into the raw staging tables under
#   document DOC_NAME. Re-running for the same doc replaces its raw rows.
#   NOTE: the JSON's own "document" field is what's actually stored; DOC_NAME
#   here is just for a clear error if you pipe the wrong file's output.
kg-load() {
  _kg_py load_extraction.py "${@:2}"
}

# usage: kg-pending TYPE
#   Prints {existing canonical entities of TYPE, unresolved raw names of
#   TYPE} — the input a resolution worker needs. Empty "unresolved" means
#   nothing to resolve for this type right now.
kg-pending() {
  [[ $# -eq 1 ]] || { echo "usage: kg-pending TYPE" >&2; return 1; }
  _kg_py pending_resolution.py "$1"
}

# usage: <resolution-worker-json> | kg-resolve
#   Applies a ResolvedClusters JSON (see bin/schemas.py) into entities/aliases.
kg-resolve() {
  _kg_py apply_resolution.py
}

# usage: kg-assemble
#   Rewrites every raw_relation endpoint to its canonical entity and loads it
#   into the resolved `relations` table with provenance. Re-run any time
#   after new documents or resolutions land; unresolved endpoints are skipped
#   and reported so you know what still needs a resolve pass.
kg-assemble() {
  _kg_py assemble_relations.py
}

# usage: kg-find "name fragment"
#   Fuzzy-search aliases for candidate seed entities (hub nodes first).
kg-find() {
  [[ $# -eq 1 ]] || { echo "usage: kg-find NAME_FRAGMENT" >&2; return 1; }
  _kg_py find_entity.py "$1"
}

# usage: kg-graph SEED_ENTITY_ID [--hops N] [--json]
#   Serializes the k-hop neighborhood of an entity (from kg-find) as
#   provenance-carrying triples, ready to hand to a query/ask worker.
kg-graph() {
  [[ $# -ge 1 ]] || { echo "usage: kg-graph SEED_ENTITY_ID [--hops N] [--json]" >&2; return 1; }
  local seed="$1"; shift
  _kg_py serialize_subgraph.py --seed-id "$seed" "$@"
}

# usage: kg-stats
#   Graph diagnostics: entity/relation counts, resolution compression ratio,
#   degree histogram, connected components.
kg-stats() {
  _kg_py stats.py
}

# --- read shortcuts (plain psql, for eyeballing the graph without writing SQL) ---

# usage: kg-entities [TYPE]
#   Table of all entities, optionally filtered by type, hub nodes first.
kg-entities() {
  if [[ $# -eq 1 ]]; then
    psql -d kg -c "SELECT id, canonical_name, type, degree, summary FROM entities WHERE type = '$1' ORDER BY degree DESC;"
  else
    psql -d kg -c "SELECT id, canonical_name, type, degree FROM entities ORDER BY degree DESC;"
  fi
}

# usage: kg-relations ["name fragment"]
#   Table of all relations with source-document provenance, optionally
#   filtered to ones touching an entity whose canonical name matches.
kg-relations() {
  local where="TRUE"
  [[ $# -eq 1 ]] && where="es.canonical_name ILIKE '%$1%' OR et.canonical_name ILIKE '%$1%'"
  psql -d kg -c "SELECT es.canonical_name AS source, r.predicate, et.canonical_name AS target, d.name AS doc
                 FROM relations r
                 JOIN entities es ON es.id = r.source_id
                 JOIN entities et ON et.id = r.target_id
                 LEFT JOIN documents d ON d.id = r.source_document_id
                 WHERE $where
                 ORDER BY source, predicate;"
}

# usage: kg-docs
#   Table of every document that has been loaded (kg-load'd) so far.
kg-docs() {
  psql -d kg -c "SELECT id, name, path, added_at FROM documents ORDER BY added_at;"
}

# usage: kg-show "name fragment" [--hops N]
#   One-shot read: finds the best-matching entity and prints its record plus
#   its subgraph (default 2 hops) with provenance. Convenience wrapper around
#   kg-find + kg-graph for humans; use kg-find/kg-graph directly if you need
#   the raw JSON (e.g. to hand to a query worker).
kg-show() {
  [[ $# -ge 1 ]] || { echo "usage: kg-show NAME_FRAGMENT [--hops N]" >&2; return 1; }
  local name="$1"; shift
  local hits id canonical etype degree
  hits="$(_kg_py find_entity.py "$name")" || return 1
  if [[ "$(echo "$hits" | jq 'length')" -eq 0 ]]; then
    echo "kg-show: no entity matches '$name'" >&2
    return 1
  fi
  id="$(echo "$hits" | jq '.[0].id')"
  canonical="$(echo "$hits" | jq -r '.[0].canonical_name')"
  etype="$(echo "$hits" | jq -r '.[0].type')"
  degree="$(echo "$hits" | jq -r '.[0].degree')"
  if [[ "$(echo "$hits" | jq 'length')" -gt 1 ]]; then
    echo "kg-show: multiple matches, showing top hit ($canonical, id=$id); others:" >&2
    echo "$hits" | jq -c '.[1:]' >&2
  fi
  echo "=== $canonical ($etype, id=$id, degree=$degree) ==="
  _kg_py serialize_subgraph.py --seed-id "$id" "$@"
}

# usage: kg <subcommand> [args...]
#   Dispatcher for the above (kg init, kg load, kg pending, kg resolve,
#   kg assemble, kg find, kg graph, kg stats, kg entities, kg relations,
#   kg docs, kg show).
kg() {
  local sub="${1:-}"; shift 2>/dev/null
  case "$sub" in
    init)      kg-init "$@" ;;
    load)      kg-load "$@" ;;
    pending)   kg-pending "$@" ;;
    resolve)   kg-resolve "$@" ;;
    assemble)  kg-assemble "$@" ;;
    find)      kg-find "$@" ;;
    graph)     kg-graph "$@" ;;
    stats)     kg-stats "$@" ;;
    entities)  kg-entities "$@" ;;
    relations) kg-relations "$@" ;;
    docs)      kg-docs "$@" ;;
    show)      kg-show "$@" ;;
    *)
      echo "usage: kg {init|load|pending|resolve|assemble|find|graph|stats|entities|relations|docs|show} [args...]" >&2
      return 1
      ;;
  esac
}
