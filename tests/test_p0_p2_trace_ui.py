"""P0-P2 provenance and evidence-presentation contract tests."""

from __future__ import annotations

import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class TraceUiContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads((ROOT / "manifests/catalog.json").read_text(encoding="utf-8"))
        cls.html = (ROOT / "app/ui/spec2rtl_harness_demo_v1_7_4.html").read_text(encoding="utf-8")

    def test_pdf_provenance_is_explicit(self):
        expected_pages = {"REQ-FC-E1": 74, "REQ-FC-E2": 74, "REQ-FC-F": 74, "REQ-FC-HJ": 75}
        for requirement in self.catalog["requirements"]:
            spec = requirement["spec"]
            self.assertEqual(spec["pdf_pages"], [expected_pages[requirement["id"]]])
            self.assertEqual(spec["printed_pages"], spec["pdf_pages"])
            self.assertGreater(len(spec["excerpt"]), 40)

    def test_each_requirement_has_executable_contract(self):
        for requirement in self.catalog["requirements"]:
            self.assertEqual(set(requirement["behavior"]), {"trigger", "precondition", "expected", "verdict"})
            self.assertTrue(requirement["result_ids"])
            self.assertTrue(requirement["waveform"]["signals"])
            self.assertLess(requirement["waveform"]["window_start"], requirement["waveform"]["window_end"])
            for layer in ("golden", "rtl", "test"):
                self.assertTrue(requirement["trace"][layer])
                for item in requirement["trace"][layer]:
                    self.assertTrue((ROOT / item["file"]).is_file())
                    self.assertLessEqual(item["start"], item["end"])

    def test_ui_exposes_required_views(self):
        for token in (
            "Open PDF page", "highlighted trace target", "Summary", "Golden", "Compile",
            "Simulation", "stdout.log", "VERDICT EVENT", "Open JUnit", "Download VCD",
        ):
            self.assertIn(token, self.html)


if __name__ == "__main__":
    unittest.main()
