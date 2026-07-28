# kg worker prompts

Prompts for the Agent-tool subagents an orchestrator spawns to do the actual
LLM reasoning. Each worker's final message must be **JSON only** (no
markdown fence, no commentary) matching the schema below — the orchestrator
validates it against `bin/schemas.py` before piping it into the matching
`kg-*` command. Adapted from the Anthropic knowledge-graph playbook
(Sections III–VI).

## 1. Extraction worker (one per document)

Model tier: cheap/fast is fine (this is high-volume, schema-constrained).

Spawn with:
```
Extract a knowledge graph from the document below.

<document>
{text}
</document>

Guidelines:
- Extract only entities that are central to what this document is about — skip incidental mentions.
- For each entity, write a one-sentence description grounded in this document. These descriptions are used later to disambiguate entities with similar names.
- Predicates should be short verb phrases ("commanded", "launched from", "part of").
- Every relation must connect two entities you extracted.

Return ONLY JSON matching exactly this shape, no other text:
{"document": "<doc id you were given>",
 "entities": [{"name": str, "type": str, "description": str}],
 "relations": [{"source": str, "predicate": str, "target": str}]}
```
Orchestrator then: validate against `schemas.ExtractedGraph`, then
`echo '<json>' | kg-load <doc-name>`.

## 2. Resolution worker (one per entity type, only when kg-pending has unresolved names)

Model tier: needs real reasoning — use your best available model.

Get the input via `kg-pending TYPE`, then spawn with:
```
Below are {type} entities extracted from several documents. Some are different
surface forms of the same real-world entity. Some are already-known canonical
entities (below as "existing") — reuse those exact canonical names if a raw
name refers to the same entity; only create a new canonical name for a
genuinely new entity.

<existing>
{existing entities, as canonical name + description}
</existing>

<unresolved>
{unresolved raw names + descriptions, from kg-pending}
</unresolved>

Cluster them. Each input name from <unresolved> must appear in exactly one
cluster's aliases list. Entities that are genuinely distinct get their own
single-element cluster. Use the descriptions to avoid merging entities that
merely share a name. The canonical name should be the most complete,
unambiguous form.

Return ONLY JSON matching exactly this shape, no other text:
{"type": "{type}",
 "clusters": [{"canonical": str, "aliases": [str, ...]}]}
```
Orchestrator then: validate against `schemas.ResolvedClusters`, then
`echo '<json>' | kg-resolve`, then `kg-assemble` once all pending types
for this batch are resolved.

## 3. Summarization worker (optional, hub nodes only — degree >= 3)

Only worth it for entities `kg-stats`/`kg-find` show with high degree.
Model tier: needs synthesis quality.

```
Generate a knowledge-graph profile for this entity.

Entity: {canonical_name} ({type})

Source excerpts mentioning this entity:
{excerpts pulled from raw_entities.description across its source documents}

Known relations in the graph:
{kg-graph <id> --hops 1 output}

Write a 2-3 paragraph factual summary synthesized from the excerpts, resolving
any contradictions by preferring the most specific claim. Include 3-5 atomic
key facts, each traceable to the sources. For the time range, use YYYY or
YYYY-MM format. Do not invent facts not supported by the excerpts.

Return ONLY JSON matching exactly this shape, no other text:
{"summary": str, "key_facts": [str, ...], "time_range": {"start": str, "end": str}}
```
Orchestrator then: validate against `schemas.EntityProfile`, then
`UPDATE entities SET summary=..., key_facts=..., time_range=... WHERE id=...`
(no dedicated kg-* command yet — do it with a one-off `psql -d kg -c`).

## 4. Query worker (multi-hop question answering)

1. `kg-find "<keyword from the question>"` to pick a seed entity id.
2. `kg-graph <id> --hops 2` to serialize its neighborhood as triples.
3. Spawn a worker with:
```
Answer using only the knowledge graph below. Cite the specific edges that
support your answer.

<graph>
{kg-graph output}
</graph>

Question: {question}
```
No schema needed here — the answer is prose, but every claim in it must cite
a `(source) --[predicate]--> (target)` edge from the supplied graph. If the
graph doesn't contain the answer, say so explicitly rather than falling back
to pretraining knowledge (that's the whole point of grounding — see playbook
Section VI.A).

## Notes for the orchestrator

- Never write raw worker JSON straight to Postgres — always validate against
  `bin/schemas.py` first (`ExtractedGraph` / `ResolvedClusters` /
  `EntityProfile`). A worker that returns malformed JSON should fail loudly,
  not corrupt the graph.
- `kg-load` is idempotent per document name — safe to re-extract after fixing
  a prompt or a bad document.
- `kg-resolve` only needs to see names `kg-pending` reports as unresolved —
  that's what keeps incremental updates cheap as new documents arrive.
- Run `kg-stats` periodically: a resolution_compression_ratio near 1.0 means
  resolution is doing nothing (check your resolve prompt); a rising
  connected_components count means cross-document links are being missed.
