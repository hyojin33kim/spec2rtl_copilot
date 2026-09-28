"""Isolated HTTP contracts for the deployed FastAPI application."""

from __future__ import annotations

import asyncio
import importlib.util
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "app/backend"))
HAS_FASTAPI = importlib.util.find_spec("fastapi") is not None
if HAS_FASTAPI:
    import fastapi_server
    import history


async def request_asgi(method: str, url: str, body: bytes = b"") -> tuple[int, dict, bytes]:
    """Exercise the real ASGI routes without opening a socket or network access."""
    parsed = urllib.parse.urlsplit(url)
    messages: list[dict] = []
    received = False
    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
        "method": method, "scheme": "http", "path": parsed.path,
        "raw_path": parsed.path.encode("ascii"), "query_string": parsed.query.encode("ascii"),
        "root_path": "", "headers": [(b"content-length", str(len(body)).encode("ascii"))],
        "client": ("127.0.0.1", 12345), "server": ("127.0.0.1", 8765),
    }

    async def receive() -> dict:
        nonlocal received
        if not received:
            received = True
            return {"type": "http.request", "body": body, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        messages.append(message)

    await fastapi_server.app(scope, receive, send)
    start = next(message for message in messages if message["type"] == "http.response.start")
    response_body = b"".join(message.get("body", b"") for message in messages
                             if message["type"] == "http.response.body")
    headers = {key.decode("latin-1"): value.decode("latin-1") for key, value in start["headers"]}
    return start["status"], headers, response_body


@unittest.skipUnless(HAS_FASTAPI, "FastAPI image required; see README Docker test command")
class FastApiContract(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.temp_path = pathlib.Path(self.temp.name)
        database = self.temp_path / "qa.sqlite3"
        patch = mock.patch.object(history, "database_path", return_value=database)
        patch.start()
        self.addCleanup(patch.stop)

    def get(self, url: str) -> tuple[int, dict, bytes]:
        return asyncio.run(request_asgi("GET", url))

    def post(self, url: str, payload: dict) -> tuple[int, dict, dict]:
        status, headers, body = asyncio.run(request_asgi("POST", url, json.dumps(payload).encode()))
        return status, headers, json.loads(body)

    def test_catalog_source_and_sqlite_search(self) -> None:
        status, _, body = self.get("/api/catalog")
        self.assertEqual(status, 200)
        self.assertEqual(len(json.loads(body)["requirements"]), 4)

        status, _, body = self.get("/api/source?path=assets/rtl/spw_datalink_v2.sv&focus_start=657&focus_end=680")
        self.assertEqual(status, 200)
        self.assertTrue(any("r_tx_credit" in line["text"] for line in json.loads(body)["lines"]))
        status, _, body = self.get("/api/source?path=../spacewire/README.md")
        self.assertEqual((status, json.loads(body)["error"]["code"]), (400, "BAD_REQUEST"))

        status, _, body = self.get("/api/spec/search?q=zero%20credit")
        self.assertEqual(status, 200)
        self.assertEqual([item["requirement_id"] for item in json.loads(body)["items"]], ["REQ-FC-F"])
        self.assertTrue((self.temp_path / "qa.sqlite3").is_file())

    def test_qa_stores_only_selected_history_with_mocked_provider(self) -> None:
        answer = {"answer": "FCT adds eight [S1].", "mode": "llm", "model": "mock-model",
                  "sources": [{"id": "S1", "kind": "spec", "page": 74}]}
        with mock.patch.object(fastapi_server.legacy, "latest_run_dir", side_effect=FileNotFoundError), \
             mock.patch.object(fastapi_server, "answer_question", return_value=answer) as provider:
            status, _, result = self.post("/api/qa", {"requirement_id": "REQ-FC-E1", "question": "FCT?"})
            self.assertEqual(status, 200)
            self.assertTrue(result["history_saved"])
            self.assertEqual(result["model"], "mock-model")
            provider.assert_called_once()
            self.assertEqual(provider.call_args.args[0]["id"], "REQ-FC-E1")

        status, _, body = self.get("/api/qa/history?requirement_id=REQ-FC-E1")
        self.assertEqual(status, 200)
        self.assertEqual([item["question"] for item in json.loads(body)["items"]], ["FCT?"])
        status, _, body = self.get("/api/qa/history?requirement_id=REQ-FC-F")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["items"], [])
        with sqlite3.connect(self.temp_path / "qa.sqlite3") as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM qa_history").fetchone()[0], 1)

    def test_qa_rejects_unknown_requirement_and_oversized_body(self) -> None:
        with mock.patch.object(fastapi_server, "answer_question") as provider:
            status, _, body = self.post("/api/qa", {"requirement_id": "REQ-OTHER", "question": "why?"})
            self.assertEqual((status, body["error"]["code"]), (400, "UNKNOWN_REQUIREMENT"))
            status, _, raw = asyncio.run(request_asgi("POST", "/api/qa", b"x" * 4097))
            self.assertEqual((status, json.loads(raw)["error"]["code"]), (400, "BAD_REQUEST"))
            provider.assert_not_called()

    def test_run_contract_and_lock_without_executing_runner(self) -> None:
        bundle = {"latest": {"run_id": "mock-run"},
                  "run": {"run_id": "mock-run", "status": "PASS", "summary": {"passed": 7}},
                  "log": "", "stage_logs": {}, "waveform": None}
        completed = subprocess.CompletedProcess(["python3"], 0, "runner ok", "")
        with mock.patch.object(fastapi_server.subprocess, "run", return_value=completed) as runner, \
             mock.patch.object(fastapi_server.legacy, "latest_bundle", return_value=bundle):
            status, _, result = self.post("/api/run", {})
            self.assertEqual(status, 200)
            self.assertEqual(result["run"]["summary"]["passed"], 7)
            self.assertEqual(result["runner"]["stdout"], "runner ok")
            runner.assert_called_once()

        fastapi_server.legacy.RUN_LOCK.acquire()
        try:
            status, _, result = self.post("/api/run", {})
        finally:
            fastapi_server.legacy.RUN_LOCK.release()
        self.assertEqual((status, result["error"]["code"]), (409, "RUN_IN_PROGRESS"))

        with mock.patch.object(fastapi_server.subprocess, "run") as runner:
            status, _, result = self.post("/api/run", {"fault": "compile"})
            self.assertEqual((status, result["error"]["code"]), (403, "FAULT_DISABLED"))
            runner.assert_not_called()

    def test_artifact_download_and_path_guard(self) -> None:
        (self.temp_path / "junit.xml").write_text("<testsuite tests='7'/>", encoding="utf-8")
        with mock.patch.object(fastapi_server.legacy, "latest_run_dir", return_value=({}, self.temp_path)):
            status, headers, body = self.get("/api/artifact?name=junit")
        self.assertEqual(status, 200)
        self.assertIn("application/xml", headers["content-type"])
        self.assertIn(b"testsuite", body)
        status, _, body = self.get("/api/artifact?name=junit&run_id=..%2F..")
        self.assertEqual((status, json.loads(body)["error"]["code"]), (400, "BAD_REQUEST"))


if __name__ == "__main__":
    unittest.main()
