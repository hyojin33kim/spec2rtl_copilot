"""Grounding and API contracts for selected-requirement Q&A."""

from __future__ import annotations

import io
import json
import pathlib
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT / "app/backend"))
import qa  # noqa: E402
import history  # noqa: E402
import server  # noqa: E402


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class QaContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads((ROOT / "manifests/catalog.json").read_text(encoding="utf-8"))

    def test_context_contains_only_selected_trace_and_bounded_sources(self):
        req = self.catalog["requirements"][0]
        context, sources = qa.evidence_context(req, None)
        self.assertIn(req["id"], context)
        self.assertNotIn(self.catalog["requirements"][1]["id"], context)
        self.assertEqual(sources[0]["id"], "S1")
        self.assertEqual({source["kind"] for source in sources}, {"spec", "source"})
        self.assertTrue(all(source["end"] - source["start"] < 40 for source in sources[1:]))

    def test_behavior_question_omits_golden_scenario_and_test_evidence(self):
        req = self.catalog["requirements"][3]
        context, sources = qa.evidence_context(req, None, include_tests=False)
        self.assertNotIn("scenario_9_credit_error_injection", context)
        self.assertFalse(any(item["id"].startswith("T") or item["id"] == "E1" for item in sources))

    def test_answer_uses_provider_without_storing_and_returns_real_citation(self):
        req = self.catalog["requirements"][0]
        observed = {}

        def fake_open(request, timeout):
            observed["request"] = json.loads(request.data)
            observed["timeout"] = timeout
            return FakeResponse(json.dumps({"output": [{"type": "message", "content": [
                {"type": "output_text", "text": "FCT 수신 시 8 증가합니다 [S1]."}]}]}).encode())

        with mock.patch.object(qa, "setting", side_effect=lambda name: "test-key" if name == "OPENAI_API_KEY" else ""), \
             mock.patch.object(qa.urllib.request, "urlopen", side_effect=fake_open):
            result = qa.answer_question(req, "FCT 효과는?")
        self.assertFalse(observed["request"]["store"])
        self.assertEqual(observed["request"]["reasoning"], {"effort": "minimal"})
        self.assertEqual(observed["request"]["max_output_tokens"], 2000)
        self.assertIn(req["id"], observed["request"]["input"])
        self.assertIn("ALLOWED CITATION IDS: S1", observed["request"]["input"])
        self.assertNotIn("[T1]", observed["request"]["input"])
        self.assertNotIn("[E1]", observed["request"]["input"])
        self.assertIn("Answer only for the selected requirement", observed["request"]["instructions"])
        self.assertIn("never claim recovery", observed["request"]["instructions"])
        self.assertIn("No Test or run evidence was supplied", observed["request"]["instructions"])
        self.assertEqual([source["id"] for source in result["sources"]], ["S1"])

    def test_test_question_includes_test_and_latest_run(self):
        req = self.catalog["requirements"][0]
        run = {"run_id": "sample-run", "status": "PASS", "tests": [
            {"id": "REQ-FC-E1", "status": "PASS", "detail": "tx_credit=16 expected=16"}]}
        context, sources = qa.evidence_context(req, run, include_tests=True)
        self.assertIn("[T1]", context)
        self.assertIn("[E1]", context)
        self.assertEqual({item["id"] for item in sources if item["id"] in {"T1", "E1"}}, {"T1", "E1"})
        self.assertIn("run_id=sample-run", next(item["url"] for item in sources if item["id"] == "E1"))

    def test_rejects_answer_without_valid_evidence_citation(self):
        req = self.catalog["requirements"][0]
        response = FakeResponse(json.dumps({"output": [{"type": "message", "content": [
            {"type": "output_text", "text": "Uncited assertion."}]}]}).encode())
        with mock.patch.object(qa, "setting", return_value="test-key"), \
             mock.patch.object(qa.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(qa.QAError) as caught:
                qa.answer_question(req, "Why?")
        self.assertEqual(caught.exception.code, "QA_UNGROUNDED")

    def test_comma_separated_valid_citations_are_normalized(self):
        req = self.catalog["requirements"][0]
        response = FakeResponse(json.dumps({"output": [{"type": "message", "content": [
            {"type": "output_text", "text": "FCT adds eight [S1,G1]."}]}]}).encode())
        with mock.patch.object(qa, "setting", return_value="test-key"), \
             mock.patch.object(qa.urllib.request, "urlopen", return_value=response):
            result = qa.answer_question(req, "FCT는 어떻게 동작하나요?")
        self.assertIn("[S1][G1]", result["answer"])
        self.assertEqual([source["id"] for source in result["sources"]], ["S1", "G1"])

    def test_line_qualified_citations_are_normalized(self):
        req = self.catalog["requirements"][0]
        response = FakeResponse(json.dumps({"output": [{"type": "message", "content": [
            {"type": "output_text", "text": "Credit rises [G1:626-629][R1:672-679, R1:675-677]."}]}]}).encode())
        with mock.patch.object(qa, "setting", return_value="test-key"), \
             mock.patch.object(qa.urllib.request, "urlopen", return_value=response):
            result = qa.answer_question(req, "FCT는 어떻게 동작하나요?")
        self.assertIn("[G1][R1]", result["answer"])
        self.assertEqual([source["id"] for source in result["sources"]], ["G1", "R1"])

    def test_test_claim_without_test_evidence_is_rejected(self):
        req = self.catalog["requirements"][0]
        response = FakeResponse(json.dumps({"output": [{"type": "message", "content": [
            {"type": "output_text", "text": "테스트 PASS입니다 [S1]."}]}]}).encode())
        with mock.patch.object(qa, "setting", return_value="test-key"), \
             mock.patch.object(qa.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(qa.QAError) as caught:
                qa.answer_question(req, "FCT는 어떻게 동작하나요?")
        self.assertEqual(caught.exception.code, "QA_UNSUPPORTED_TEST_CLAIM")

    def test_out_of_scope_questions_do_not_call_provider_or_claim_a_verdict(self):
        cases = (("REQ-FC-E1", "수신 크레딧 accounting 수식은?"),
                 ("REQ-FC-F", "Router 라우팅 우선순위 알고리즘과 PASS 여부는?"))
        by_id = {item["id"]: item for item in self.catalog["requirements"]}
        with mock.patch.object(qa.urllib.request, "urlopen") as provider:
            for req_id, question in cases:
                response = qa.answer_question(by_id[req_id], question)
                self.assertIn("설명하거나 PASS/FAIL을 판정할 수 없습니다", response["answer"])
                self.assertEqual([source["id"] for source in response["sources"]], ["S1"])
        provider.assert_not_called()


class QaApiContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = server.MvpServer(("127.0.0.1", 0), server.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/api/qa"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def post(self, body):
        request = urllib.request.Request(self.url, json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as exc:
            return exc.code, json.load(exc)

    def test_accepts_only_catalog_requirement_and_passes_selected_run(self):
        status, error = self.post({"requirement_id": "REQ-OTHER", "question": "why?"})
        self.assertEqual((status, error["error"]["code"]), (400, "UNKNOWN_REQUIREMENT"))
        with mock.patch.object(server, "answer_question", return_value={"answer": "x", "sources": []}) as answer, \
             mock.patch.object(server, "save_answer", return_value={"id": 1}):
            status, _ = self.post({"requirement_id": "REQ-FC-E1", "question": "why?"})
        self.assertEqual(status, 200)
        self.assertEqual(answer.call_args.args[0]["id"], "REQ-FC-E1")

    def test_qa_history_is_saved_and_filtered_by_requirement(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = pathlib.Path(temp_dir) / "history.sqlite3"
            answer = {"requirement_id": "REQ-FC-E1", "mode": "llm", "model": "test-model",
                      "answer": "FCT adds eight [S1].", "sources": [{"id": "S1", "kind": "spec", "page": 74}]}
            with mock.patch.object(history, "database_path", return_value=path), \
                 mock.patch.object(server, "answer_question", return_value=answer):
                status, response = self.post({"requirement_id": "REQ-FC-E1", "question": "FCT?"})
                self.assertEqual(status, 200)
                self.assertTrue(response["history_saved"])
                with urllib.request.urlopen(self.url + "/history?requirement_id=REQ-FC-E1") as result:
                    items = json.load(result)["items"]
                with urllib.request.urlopen(self.url + "/history?requirement_id=REQ-FC-F") as result:
                    other = json.load(result)["items"]
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0]["question"], "FCT?")
            self.assertEqual(items[0]["sources"], answer["sources"])
            self.assertEqual(items[0]["model"], "test-model")
            self.assertEqual(other, [])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_saved_run_artifact_link_uses_explicit_run_and_rejects_traversal(self):
        run_id = server.latest_run_dir()[1].name
        with urllib.request.urlopen(
            f"http://127.0.0.1:{self.server.server_port}/api/artifact?name=junit&run_id={urllib.parse.quote(run_id, safe='')}"
        ) as result:
            self.assertEqual(result.status, 200)
            self.assertIn(b"<testsuite", result.read())
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(
                f"http://127.0.0.1:{self.server.server_port}/api/artifact?name=junit&run_id=..%2F.."
            )
        self.assertEqual(caught.exception.code, 400)


class QaHistoryStore(unittest.TestCase):
    def test_reopen_preserves_order_and_source_links(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = pathlib.Path(temp_dir) / "qa.sqlite3"
            response = {"mode": "llm", "model": "test-model", "answer": "result [E1]",
                        "sources": [{"id": "E1", "kind": "evidence",
                                     "url": "/api/artifact?name=junit&run_id=sample-run"}]}
            first = history.save_answer("REQ-FC-E1", "first", response, "sample-run", path)
            second = history.save_answer("REQ-FC-E1", "second", response, "sample-run", path)
            self.assertLess(first["id"], second["id"])
            self.assertEqual([item["question"] for item in history.list_answers("REQ-FC-E1", path=path)],
                             ["second", "first"])
            self.assertEqual(history.list_answers("REQ-FC-E2", path=path), [])
            with closing(sqlite3.connect(path)) as connection:
                self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 2)


if __name__ == "__main__":
    unittest.main()
