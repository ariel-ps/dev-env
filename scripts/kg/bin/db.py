"""Shared Postgres connection for the kg-* scripts.

Connects to the local ``kg`` database (created once via ``createdb kg`` and
``schema.sql``). Override with KG_DB_NAME / KG_DB_HOST / KG_DB_PORT /
KG_DB_USER if pointing at something other than the default local instance.
"""
import os
import psycopg2
import psycopg2.extras


def get_conn():
    return psycopg2.connect(
        dbname=os.environ.get("KG_DB_NAME", "kg"),
        host=os.environ.get("KG_DB_HOST", ""),  # empty -> unix socket
        port=os.environ.get("KG_DB_PORT", "5432"),
        user=os.environ.get("KG_DB_USER") or None,
    )


def dict_cursor(conn):
    return conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
