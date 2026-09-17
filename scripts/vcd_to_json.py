#!/usr/bin/env python3
"""Extract a compact canonical signal timeline from an Icarus VCD file."""

from __future__ import annotations

import argparse
import json
import pathlib
from collections import defaultdict


ROOT = pathlib.Path(__file__).resolve().parents[1]
SIGNAL_MANIFEST = ROOT / "manifests/waveform-signals.json"


def load_signal_map() -> dict[str, str]:
    payload = json.loads(SIGNAL_MANIFEST.read_text(encoding="utf-8"))
    return payload["signals"]


def _decoded(bits: str):
    return int(bits, 2) if bits and set(bits) <= {"0", "1"} else None


def parse_vcd(path: pathlib.Path, signal_map: dict[str, str] | None = None) -> dict:
    signal_map = signal_map or load_signal_map()
    scopes: list[str] = []
    names_by_id: dict[str, list[str]] = defaultdict(list)
    timescale = "unknown"
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    data_start = 0

    index = 0
    while index < len(lines):
        line = lines[index].strip()
        if line.startswith("$timescale"):
            tokens = line.split()
            if len(tokens) >= 3:
                timescale = tokens[1]
            elif index + 1 < len(lines):
                timescale = lines[index + 1].strip()
        elif line.startswith("$scope"):
            parts = line.split()
            scopes.append(parts[2])
        elif line.startswith("$upscope"):
            if scopes:
                scopes.pop()
        elif line.startswith("$var"):
            parts = line.split()
            identifier = parts[3]
            reference = parts[4]
            names_by_id[identifier].append(".".join([*scopes, reference]))
        elif line.startswith("$enddefinitions"):
            data_start = index + 1
            break
        index += 1

    id_by_canonical: dict[str, str] = {}
    for canonical, hierarchical_name in signal_map.items():
        matches = [identifier for identifier, names in names_by_id.items() if hierarchical_name in names]
        if len(matches) != 1:
            raise ValueError(f"expected one VCD match for {canonical}={hierarchical_name}, got {matches}")
        id_by_canonical[canonical] = matches[0]

    canonical_by_id = {identifier: name for name, identifier in id_by_canonical.items()}
    changes: dict[str, list[dict]] = {name: [] for name in signal_map}
    last_value: dict[str, str] = {}
    current_time = 0

    for raw_line in lines[data_start:]:
        line = raw_line.strip()
        if not line or line.startswith("$"):
            continue
        if line.startswith("#"):
            current_time = int(line[1:])
            continue
        if line[0] in "01xXzZ":
            value = line[0].lower()
            identifier = line[1:]
        elif line[0] in "bB":
            value, identifier = line[1:].split(maxsplit=1)
            value = value.lower()
        else:
            continue
        canonical = canonical_by_id.get(identifier)
        if canonical is None or last_value.get(canonical) == value:
            continue
        last_value[canonical] = value
        changes[canonical].append(
            {"time": current_time, "value": value, "integer": _decoded(value)}
        )

    return {
        "schema_version": 1,
        "source": path.name,
        "timescale": timescale,
        "signals": {
            name: {"source": signal_map[name], "changes": changes[name]}
            for name in signal_map
        },
    }


def convert(input_path: pathlib.Path, output_path: pathlib.Path) -> None:
    payload = parse_vcd(input_path)
    output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    convert(args.input, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
