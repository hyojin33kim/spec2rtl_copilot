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
    "rx_credit",
    "send_fct",
    "got_nchar",
    "rx_credit_error",
    "rx_free_space",
    "fct_send_ok",
    "initial_fct_requests",
    "link_start",
    "port_reset",
    "disconnect_error",
    "parity_error",
    "esc_error",
    "eep_pending",
    "eep_write_now",
    "tx_flushing",
    "enc_tx_char",
    "enc_tx_valid",
    "enc_tx_ready",
    "enc_rx_char",
    "enc_rx_valid",
    "enc_parity_error",
    "ds_data",
    "ds_strobe",
    "phy_rx_strobe",
    "phy_seen_edge",
    "phy_disconnect",
    "enc_rx_enable",
    "enc_raw_parity_error",
    "enc_got_null",
    "enc_valid_parity_error",
    "enc_null_window",
    "enc_null_window_bits",
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
        self.assertEqual(22, self.run_payload["summary"]["total"])
        self.assertEqual(0, self.run_payload["summary"]["failed"])
        self.assertFalse(self.run_payload["summary"]["command_failed"])

    def test_standard_artifacts_exist(self):
        for name in ("run.json", "junit.xml", "stdout.log", "waveform.vcd", "waveform.json"):
            path = self.run_dir / name
            self.assertTrue(path.is_file(), path)
            self.assertGreater(path.stat().st_size, 0, path)

    def test_junit_contains_twenty_two_passing_cases(self):
        suite = ET.parse(self.run_dir / "junit.xml").getroot()
        self.assertEqual("22", suite.attrib["tests"])
        self.assertEqual("0", suite.attrib["failures"])
        self.assertEqual(22, len(suite.findall("testcase")))

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
