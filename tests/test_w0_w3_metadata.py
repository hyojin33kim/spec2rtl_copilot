from __future__ import annotations

import hashlib
import pathlib
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_yaml(relative_path: str):
    with (ROOT / relative_path).open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


class W0W3MetadataTest(unittest.TestCase):
    def test_yaml_documents_parse(self):
        for path in (
            "manifests/source-baseline.yaml",
            "requirements/flow-control.yaml",
            "trace/flow-control.yaml",
        ):
            self.assertIsInstance(load_yaml(path), dict, path)

    def test_every_requirement_has_one_trace(self):
        requirements = load_yaml("requirements/flow-control.yaml")
        trace = load_yaml("trace/flow-control.yaml")
        requirement_ids = {item["id"] for item in requirements["requirements"]}
        trace_ids = [item["requirement"] for item in trace["traces"]]
        self.assertEqual(requirement_ids, set(trace_ids))
        self.assertEqual(len(trace_ids), len(set(trace_ids)))

    def test_trace_files_and_symbols_exist(self):
        trace = load_yaml("trace/flow-control.yaml")
        for relation in trace["traces"]:
            for layer in ("golden", "rtl", "tests"):
                for artifact in relation[layer]:
                    path = ROOT / artifact["file"]
                    self.assertTrue(path.is_file(), path)
                    text = path.read_text(encoding="utf-8")
                    symbol_leaf = artifact["symbol"].split(".")[-1]
                    self.assertIn(symbol_leaf, text, f"{path}: {symbol_leaf}")

    def test_snapshot_hashes(self):
        sums = ROOT / "manifests/SHA256SUMS"
        for raw_line in sums.read_text(encoding="utf-8").splitlines():
            expected, relative_path = raw_line.split(maxsplit=1)
            path = ROOT / relative_path
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(expected, digest, relative_path)


if __name__ == "__main__":
    unittest.main()
