"""Pydantic contracts for what extraction/resolution workers must return.

These mirror the Anthropic knowledge-graph playbook's Pydantic models
(Section III). An orchestrator spawning an Agent-tool worker should paste
the relevant model's `.model_json_schema()` (or the prompt text in
PROMPTS.md) into the worker's instructions, then validate the worker's JSON
against the model before handing it to load_extraction.py / apply_resolution.py.
Malformed worker output should fail loudly here, not corrupt the graph.
"""
from pydantic import BaseModel


class Entity(BaseModel):
    name: str
    type: str
    description: str  # one-line, grounded in the document; used for disambiguation


class Relation(BaseModel):
    source: str
    predicate: str
    target: str


class ExtractedGraph(BaseModel):
    document: str          # doc id/name, must match what you pass to load_extraction.py
    entities: list[Entity]
    relations: list[Relation]


class Cluster(BaseModel):
    canonical: str
    aliases: list[str]


class ResolvedClusters(BaseModel):
    type: str
    clusters: list[Cluster]


class TimeRange(BaseModel):
    start: str  # YYYY or "unknown"
    end: str    # YYYY or "ongoing"


class EntityProfile(BaseModel):
    summary: str            # 2-3 paragraphs
    key_facts: list[str]    # 3-5 atomic, traceable facts
    time_range: TimeRange
