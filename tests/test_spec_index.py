"""Spec catalog projection and SQLite migration contracts."""

from __future__ import annotations

import copy
import json
import pathlib
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from contextlib import closing
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "app/backend"))
import history  # noqa: E402
import server  # noqa: E402
import spec_index  # noqa: E402


class SpecIndexStore(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads((ROOT / "manifests/catalog.json").read_text(encoding="utf-8"))

    def test_clause_text_and_trace_links_are_searchable(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = pathlib.Path(temp_dir) / "spec.sqlite3"
            by_text = spec_index.search_spec("zero credit", self.catalog, path=path)
            by_clause = spec_index.search_spec("5.5.4.e.1", self.catalog, path=path)
            self.assertEqual([item["requirement_id"] for item in by_text], ["REQ-FC-F", "REQ-RC-ERR"])
            self.assertEqual([item["requirement_id"] for item in by_clause], ["REQ-FC-E1"])
            self.assertEqual({link["layer"] for link in by_text[0]["trace_links"]},
                             {"golden", "rtl", "test"})
            self.assertEqual(by_text[0]["document"], "ECSS-E-ST-50-12C Rev.1")
            with closing(sqlite3.connect(path)) as connection:
                self.assertEqual(connection.execute("SELECT count(*) FROM spec_requirements").fetchone()[0], 18)
                self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 2)

    def test_catalog_change_rebuilds_search_without_duplicates(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = pathlib.Path(temp_dir) / "spec.sqlite3"
            spec_index.sync_catalog(self.catalog, path)
            changed = copy.deepcopy(self.catalog)
            changed["requirements"][0]["title"] = "Distinctive quasar credit rule"
            self.assertEqual([item["requirement_id"] for item in
                              spec_index.search_spec("quasar", changed, path=path)], ["REQ-FC-E1"])
            with closing(sqlite3.connect(path)) as connection:
                self.assertEqual(connection.execute("SELECT count(*) FROM spec_requirements").fetchone()[0], 18)

    def test_v1_qa_history_survives_schema_upgrade(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = pathlib.Path(temp_dir) / "spec.sqlite3"
            with closing(sqlite3.connect(path)) as connection:
                connection.execute("""CREATE TABLE qa_history (
                    id INTEGER PRIMARY KEY, created_at TEXT NOT NULL, requirement_id TEXT NOT NULL,
                    question TEXT NOT NULL, answer TEXT NOT NULL, sources_json TEXT NOT NULL,
                    model TEXT, mode TEXT NOT NULL, run_id TEXT)""")
                connection.execute("""INSERT INTO qa_history
                    (created_at, requirement_id, question, answer, sources_json, mode)
                    VALUES ('2026-01-01', 'REQ-FC-E1', 'old?', 'old answer', '[]', 'scope')""")
                connection.execute("PRAGMA user_version=1")
                connection.commit()
            spec_index.sync_catalog(self.catalog, path)
            self.assertEqual(history.list_answers("REQ-FC-E1", path=path)[0]["answer"], "old answer")
            with closing(sqlite3.connect(path)) as connection:
                self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 2)


class SpecIndexApi(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = server.MvpServer(("127.0.0.1", 0), server.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def test_search_endpoint_uses_sqlite_and_validates_query(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = pathlib.Path(temp_dir) / "spec.sqlite3"
            with mock.patch.object(history, "database_path", return_value=path):
                with urllib.request.urlopen(self.base + "/api/spec/search?q=zero+credit") as result:
                    body = json.load(result)
                self.assertEqual([item["requirement_id"] for item in body["items"]],
                                 ["REQ-FC-F", "REQ-RC-ERR"])
                self.assertTrue(path.is_file())
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(self.base + "/api/spec/search?q=")
                self.assertEqual(caught.exception.code, 400)


if __name__ == "__main__":
    unittest.main()
