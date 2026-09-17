"""Acceptance tests for the local W7-W9 backend and failure reporting."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import threading
import unittest
import urllib.error
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mvp_server", ROOT / "app/backend/server.py")
SERVER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(SERVER)


class BackendAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = SERVER.MvpServer(("127.0.0.1", 0), SERVER.Handler, enable_test_faults=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def request(self, path, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(self.base + path, data=data,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=130) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as exc:
            return exc.code, json.load(exc)

    def binary_request(self, path):
        with urllib.request.urlopen(self.base + path, timeout=10) as response:
            return response.status, response.headers, response.read()

    def test_01_catalog_and_source_trace(self):
        status, catalog = self.request("/api/catalog")
        self.assertEqual(status, 200)
        self.assertEqual(len(catalog["requirements"]), 4)
        status, source = self.request(
            "/api/source?path=assets/rtl/spw_datalink_v2.sv&focus_start=657&focus_end=680")
        self.assertEqual(status, 200)
        self.assertEqual(source["focus_start"], 657)
        self.assertEqual(source["focus_end"], 680)
        self.assertLess(source["start"], source["focus_start"])
        self.assertTrue(any("r_tx_credit" in line["text"] for line in source["lines"]))

    def test_01b_pdf_and_artifact_access(self):
        pdf = ROOT / "assets/spec/ECSS-E-ST-50-12C-Rev.1(15May2019).pdf"
        if pdf.is_file():
            status, headers, body = self.binary_request("/api/spec/pdf")
            self.assertEqual(status, 200)
            self.assertEqual(headers.get_content_type(), "application/pdf")
            self.assertTrue(body.startswith(b"%PDF"))
        else:
            status, payload = self.request("/api/spec/pdf")
            self.assertEqual(status, 404)
            self.assertEqual(payload["error"]["code"], "NOT_FOUND")
        status, headers, body = self.binary_request("/api/artifact?name=junit")
        self.assertEqual(status, 200)
        self.assertIn(b"testsuite", body)

    def test_02_source_containment(self):
        status, payload = self.request("/api/source?path=../spacewire/README.md")
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "BAD_REQUEST")

    def test_03_run_lock(self):
        SERVER.RUN_LOCK.acquire()
        try:
            status, payload = self.request("/api/run", {})
        finally:
            SERVER.RUN_LOCK.release()
        self.assertEqual(status, 409)
        self.assertEqual(payload["error"]["code"], "RUN_IN_PROGRESS")

    def test_04_compile_failure_evidence(self):
        status, payload = self.request("/api/run", {"fault": "compile"})
        self.assertEqual(status, 422)
        self.assertEqual(payload["run"]["status"], "FAIL")
        self.assertTrue(payload["run"]["summary"]["command_failed"])
        self.assertIn("syntax error", payload["log"].lower())

    def test_05_simulation_failure_evidence(self):
        status, payload = self.request("/api/run", {"fault": "simulation"})
        self.assertEqual(status, 422)
        self.assertEqual(payload["run"]["status"], "FAIL")
        self.assertIn("acceptance simulation fault injected", payload["log"])

    def test_99_normal_e2e_and_waveform(self):
        status, payload = self.request("/api/run", {})
        self.assertEqual(status, 200)
        self.assertEqual(payload["run"]["status"], "PASS")
        self.assertEqual(payload["run"]["summary"]["passed"], 7)
        self.assertIn("tx_credit", payload["waveform"]["signals"])
        self.assertEqual(set(payload["stage_logs"]), {"golden", "rtl_compile", "rtl_simulation"})


if __name__ == "__main__":
    unittest.main()
