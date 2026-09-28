"""Local SQLite store for Q&A history and a rebuildable Spec trace index."""

from __future__ import annotations

import json
import os
import pathlib
import sqlite3
from datetime import datetime, timezone

from qa import ROOT, setting


DEFAULT_DB = ROOT / "app/backend/.runtime/qa-history.sqlite3"
SCHEMA_VERSION = 2


def database_path() -> pathlib.Path:
    configured = setting("SPEC2RTL_DB_PATH")
    path = pathlib.Path(configured).expanduser() if configured else DEFAULT_DB
    return (ROOT / path).resolve() if not path.is_absolute() else path.resolve()


def connect(path: pathlib.Path | None = None) -> sqlite3.Connection:
    path = path or database_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        pass
    else:
        os.close(descriptor)
    connection = sqlite3.connect(path, timeout=5)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout = 5000")
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    if version not in (0, 1, SCHEMA_VERSION):
        connection.close()
        raise ValueError(f"Unsupported database schema version: {version}")
    try:
        connection.execute("""
        CREATE TABLE IF NOT EXISTS qa_history (
            id INTEGER PRIMARY KEY,
            created_at TEXT NOT NULL,
            requirement_id TEXT NOT NULL,
            question TEXT NOT NULL,
            answer TEXT NOT NULL,
            sources_json TEXT NOT NULL,
            model TEXT,
            mode TEXT NOT NULL CHECK (mode IN ('llm', 'scope')),
            run_id TEXT
        )
        """)
        connection.execute("CREATE INDEX IF NOT EXISTS qa_history_by_requirement ON qa_history(requirement_id, id DESC)")
        connection.execute("""
            CREATE TABLE IF NOT EXISTS spec_requirements (
                requirement_id TEXT PRIMARY KEY,
                trace_id TEXT NOT NULL,
                document TEXT NOT NULL,
                published TEXT NOT NULL,
                spec_asset TEXT NOT NULL,
                clause TEXT NOT NULL,
                title TEXT NOT NULL,
                excerpt TEXT NOT NULL,
                pdf_page INTEGER NOT NULL,
                printed_page INTEGER NOT NULL
            )
        """)
        connection.execute("""
            CREATE TABLE IF NOT EXISTS spec_trace_links (
                requirement_id TEXT NOT NULL,
                layer TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                file TEXT NOT NULL,
                symbol TEXT NOT NULL,
                start_line INTEGER NOT NULL,
                end_line INTEGER NOT NULL,
                role TEXT NOT NULL,
                PRIMARY KEY (requirement_id, layer, ordinal)
            )
        """)
        connection.execute("CREATE INDEX IF NOT EXISTS spec_trace_by_requirement ON spec_trace_links(requirement_id)")
        connection.execute("CREATE TABLE IF NOT EXISTS spec_index_state (id INTEGER PRIMARY KEY CHECK(id=1), catalog_sha256 TEXT NOT NULL)")
        connection.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS spec_fts USING fts5(
                requirement_id UNINDEXED, clause, title, excerpt, tokenize='unicode61'
            )
        """)
        if version < SCHEMA_VERSION:
            connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        connection.commit()
    except Exception:
        connection.close()
        raise
    return connection


def save_answer(requirement_id: str, question: str, response: dict,
                run_id: str | None = None, path: pathlib.Path | None = None) -> dict:
    """Persist only a successful answer and its source references."""
    created_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    connection = connect(path)
    try:
        cursor = connection.execute(
            """INSERT INTO qa_history
               (created_at, requirement_id, question, answer, sources_json, model, mode, run_id)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (created_at, requirement_id, question, response["answer"],
             json.dumps(response["sources"], ensure_ascii=False), response.get("model"),
             response.get("mode", "llm"), run_id),
        )
        connection.commit()
        return {"id": cursor.lastrowid, "created_at": created_at}
    finally:
        connection.close()


def list_answers(requirement_id: str, limit: int = 5,
                 path: pathlib.Path | None = None) -> list[dict]:
    connection = connect(path)
    try:
        rows = connection.execute(
            """SELECT id, created_at, requirement_id, question, answer, sources_json,
                      model, mode, run_id
               FROM qa_history WHERE requirement_id = ? ORDER BY id DESC LIMIT ?""",
            (requirement_id, limit),
        ).fetchall()
        items = []
        for row in rows:
            item = dict(row)
            item["sources"] = json.loads(item.pop("sources_json"))
            items.append(item)
        return items
    finally:
        connection.close()
