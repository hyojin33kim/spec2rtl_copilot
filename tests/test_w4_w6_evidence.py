from __future__ import annotations

import json
import pathlib
import unittest
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[1]
EXPECTED_SIGNALS = {
    "link_state",
    "tx_credit",
    "got_fct",
    "send_nchar",
    "credit_error",
    "tx_credit_overflow",
    "nchar_valid",
    "nchar_ready",
}


class W4W6EvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.latest = json.loads((ROOT / "runs/latest.json").read_text(encoding="utf-8"))
        cls.run_dir = ROOT / cls.latest["path"]
        cls.run_payload = json.loads((cls.run_dir / "run.json").read_text(encoding="utf-8"))

    def test_latest_run_is_immutable_directory_and_passed(self):
        self.assertEqual("PASS", self.latest["status"])
        self.assertEqual(self.latest["run_id"], self.run_dir.name)
        self.assertEqual(self.latest["run_id"], self.run_payload["run_id"])
        self.assertEqual("PASS", self.run_payload["status"])

    def test_run_matches_declared_schema_fields(self):
        schema = json.loads((ROOT / "manifests/run-schema.json").read_text(encoding="utf-8"))
        self.assertTrue(set(schema["required"]).issubset(self.run_payload))
        self.assertEqual(1, self.run_payload["schema_version"])
        self.assertEqual(7, self.run_payload["summary"]["total"])
        self.assertEqual(0, self.run_payload["summary"]["failed"])
        self.assertFalse(self.run_payload["summary"]["command_failed"])

    def test_standard_artifacts_exist(self):
        for name in ("run.json", "junit.xml", "stdout.log", "waveform.vcd", "waveform.json"):
            path = self.run_dir / name
            self.assertTrue(path.is_file(), path)
            self.assertGreater(path.stat().st_size, 0, path)

    def test_junit_contains_seven_passing_cases(self):
        suite = ET.parse(self.run_dir / "junit.xml").getroot()
        self.assertEqual("7", suite.attrib["tests"])
        self.assertEqual("0", suite.attrib["failures"])
        self.assertEqual(7, len(suite.findall("testcase")))

    def test_waveform_has_canonical_timelines(self):
        waveform = json.loads((self.run_dir / "waveform.json").read_text(encoding="utf-8"))
        signal_contract = json.loads(
            (ROOT / "manifests/waveform-signals.json").read_text(encoding="utf-8")
        )
        self.assertEqual(EXPECTED_SIGNALS, set(signal_contract["signals"]))
        self.assertEqual(EXPECTED_SIGNALS, set(waveform["signals"]))
        for name, signal in waveform["signals"].items():
            self.assertTrue(signal["changes"], name)
        credit_values = {
            item["integer"] for item in waveform["signals"]["tx_credit"]["changes"]
        }
        self.assertTrue({0, 4, 8, 10, 16, 17, 56}.issubset(credit_values))


if __name__ == "__main__":
    unittest.main()
