"""Rebuildable SQLite search index for the approved Spec-to-trace catalog."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
from contextlib import closing

from history import connect


def sync_catalog(catalog: dict, path: pathlib.Path | None = None) -> str:
    """Replace the index only when the manifest content changes."""
    digest = hashlib.sha256(json.dumps(catalog, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    with closing(connect(path)) as connection:
        row = connection.execute("SELECT catalog_sha256 FROM spec_index_state WHERE id=1").fetchone()
        if row and row[0] == digest:
            return digest
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT catalog_sha256 FROM spec_index_state WHERE id=1").fetchone()
            if row and row[0] == digest:
                connection.commit()
                return digest
            connection.execute("DELETE FROM spec_trace_links")
            connection.execute("DELETE FROM spec_requirements")
            connection.execute("DELETE FROM spec_fts")
            pilot = catalog["pilot"]
            for req in catalog["requirements"]:
                spec = req["spec"]
                connection.execute(
                    """INSERT INTO spec_requirements
                       (requirement_id, trace_id, document, published, spec_asset,
                        clause, title, excerpt, pdf_page, printed_page)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (req["id"], req.get("trace_id", req["id"]), pilot["document"],
                     pilot["published"], pilot["spec_asset"], spec["clause"],
                     req["title"], spec["excerpt"], spec["pdf_pages"][0],
                     spec["printed_pages"][0]),
                )
                connection.execute(
                    "INSERT INTO spec_fts (requirement_id, clause, title, excerpt) VALUES (?, ?, ?, ?)",
                    (req["id"], spec["clause"], req["title"], spec["excerpt"]),
                )
                for layer in ("golden", "rtl", "test"):
                    for ordinal, link in enumerate(req["trace"][layer], 1):
                        connection.execute(
                            """INSERT INTO spec_trace_links
                               (requirement_id, layer, ordinal, file, symbol, start_line, end_line, role)
                               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                            (req["id"], layer, ordinal, link["file"], link["symbol"],
                             link["start"], link["end"], link["role"]),
                        )
            connection.execute(
                "INSERT OR REPLACE INTO spec_index_state (id, catalog_sha256) VALUES (1, ?)",
                (digest,),
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
    return digest


def search_spec(query: str, catalog: dict, limit: int = 20,
                path: pathlib.Path | None = None) -> list[dict]:
    """Search clause IDs or indexed text; return its executable trace links."""
    query = query.strip()
    if not 1 <= len(query) <= 120:
        raise ValueError("Search query must be 1–120 characters")
    if not 1 <= limit <= 50:
        raise ValueError("Search limit must be 1–50")
    sync_catalog(catalog, path)
    with closing(connect(path)) as connection:
        if "." in query:
            rows = connection.execute(
                "SELECT * FROM spec_requirements WHERE instr(clause, ?) > 0 ORDER BY clause LIMIT ?",
                (query, limit),
            ).fetchall()
        else:
            tokens = re.findall(r"\w+", query, re.UNICODE)
            if not tokens:
                return []
            match = " AND ".join(f'"{token}"' for token in tokens)
            rows = connection.execute(
                """SELECT * FROM spec_requirements
                   WHERE requirement_id IN (SELECT requirement_id FROM spec_fts WHERE spec_fts MATCH ?)
                   ORDER BY clause LIMIT ?""",
                (match, limit),
            ).fetchall()
        items = [dict(row) for row in rows]
        for item in items:
            links = connection.execute(
                """SELECT layer, ordinal, file, symbol, start_line, end_line, role
                   FROM spec_trace_links WHERE requirement_id=? ORDER BY layer, ordinal""",
                (item["requirement_id"],),
            ).fetchall()
            item["trace_links"] = [dict(link) for link in links]
        return items
