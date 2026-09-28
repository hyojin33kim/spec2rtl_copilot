#!/usr/bin/env python3
"""Run the Golden and RTL SpaceWire data-link pilot and persist evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

from vcd_to_json import convert as convert_vcd


ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNS = ROOT / "runs"
EXPECTED_RTL_TESTS = (
    "REQ-FC-E1",
    "REQ-FC-E2",
    "REQ-FC-F",
    "DEC-FC-SIMULTANEOUS-001",
    "REQ-FC-HJ-COMB",
    "REQ-FC-HJ-STATE",
    "REQ-RC-ACCOUNT",
    "REQ-FCT-INIT",
    "REQ-FCT-ELIGIBLE",
    "REQ-RC-ERR",
    "REQ-LINK-INIT",
    "REQ-LINK-ERROR",
    "REQ-PKT-RECOVERY",
    "REQ-ENC-SYMBOL",
    "REQ-ENC-DS-CORE",
    "REQ-ENC-DISCONNECT",
    "REQ-ENC-ESC",
    "REQ-ENC-FIRST-NULL",
    "REQ-ENC-NULL-DETECT",
    "REQ-ENC-PARITY-GATE",
)


def iso_now() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def tool_version(argv: list[str]) -> str:
    try:
        result = subprocess.run(argv, text=True, capture_output=True, timeout=10, check=False)
        text = (result.stdout or result.stderr).strip().splitlines()
        return text[0] if text else "unknown"
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"unavailable: {exc}"


def execute(stage: str, argv: list[str], cwd: pathlib.Path, timeout: int, log) -> dict:
    started = time.monotonic()
    log.write(f"\n===== {stage} =====\n$ {' '.join(argv)}\n")
    log.flush()
    timed_out = False
    try:
        result = subprocess.run(
            argv,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        output = result.stdout
        exit_code = result.returncode
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        output = (exc.stdout or "") + f"\nTIMEOUT after {timeout}s\n"
        exit_code = 124
    except OSError as exc:
        output = f"EXECUTION ERROR: {exc}\n"
        exit_code = 127
    log.write(output)
    log.flush()
    return {
        "stage": stage,
        "argv": argv,
        "cwd": str(cwd.relative_to(ROOT) if cwd.is_relative_to(ROOT) else cwd),
        "exit_code": exit_code,
        "duration_seconds": round(time.monotonic() - started, 6),
        "timed_out": timed_out,
        "output": output,
    }


def parse_rtl_results(output: str) -> list[dict]:
    found: dict[str, dict] = {}
    pattern = re.compile(r"^MVP_RESULT\|([^|]+)\|(PASS|FAIL)\|(.*)$", re.MULTILINE)
    for test_id, status, detail in pattern.findall(output):
        if test_id in EXPECTED_RTL_TESTS:
            found[test_id] = {"id": test_id, "layer": "rtl", "status": status, "detail": detail}
    results = []
    for test_id in EXPECTED_RTL_TESTS:
        results.append(found.get(test_id, {
            "id": test_id,
            "layer": "rtl",
            "status": "FAIL",
            "detail": "expected result marker missing",
        }))
    return results


def write_junit(path: pathlib.Path, tests: list[dict], duration: float) -> None:
    failures = sum(test["status"] != "PASS" for test in tests)
    suite = ET.Element(
        "testsuite",
        name="spec2rtl-tx-credit-mvp",
        tests=str(len(tests)),
        failures=str(failures),
        errors="0",
        time=f"{duration:.6f}",
    )
    for test in tests:
        case = ET.SubElement(suite, "testcase", classname=test["layer"], name=test["id"])
        if test["status"] != "PASS":
            failure = ET.SubElement(case, "failure", message=test["detail"])
            failure.text = test["detail"]
        ET.SubElement(case, "system-out").text = test["detail"]
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def atomic_json(path: pathlib.Path, payload: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", help="optional explicit unique run id")
    parser.add_argument("--fault", choices=("none", "compile", "simulation"), default="none",
                        help="acceptance-only failure injection")
    args = parser.parse_args()

    run_id = args.run_id or (
        dt.datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")
        + "-" + uuid.uuid4().hex[:8]
    )
    run_dir = RUNS / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    build_dir = run_dir / "build"
    build_dir.mkdir()
    started_at = iso_now()
    overall_started = time.monotonic()
    commands: list[dict] = []
    tests: list[dict] = []
    waveform_error = None

    with (run_dir / "stdout.log").open("w", encoding="utf-8") as log:
        golden = execute(
            "golden",
            ["python3", "spw_ref_model_test_v5.py"],
            ROOT / "assets/golden",
            60,
            log,
        )
        commands.append({key: value for key, value in golden.items() if key != "output"})
        golden_pass = golden["exit_code"] == 0 and "결과: PASS 147 / FAIL 0" in golden["output"]
        tests.append({
            "id": "GOLDEN-BASELINE-147",
            "layer": "golden",
            "status": "PASS" if golden_pass else "FAIL",
            "detail": "PASS 147 / FAIL 0" if golden_pass else "Golden baseline failed or summary missing",
        })

        encoding_golden = execute(
            "encoding_golden",
            ["python3", "golden/encoding_compliance.py"],
            ROOT,
            10,
            log,
        )
        commands.append({key: value for key, value in encoding_golden.items() if key != "output"})
        encoding_golden_pass = (
            encoding_golden["exit_code"] == 0
            and "ENCODING_GOLDEN|PASS" in encoding_golden["output"]
        )
        tests.append({
            "id": "GOLDEN-ENCODING-COMPLIANCE",
            "layer": "golden",
            "status": "PASS" if encoding_golden_pass else "FAIL",
            "detail": (
                "first Null, complete Null detection and parity gate PASS"
                if encoding_golden_pass else "Encoding compliance oracle failed"
            ),
        })

        rtl_binary = build_dir / "tb_credit_mvp.vvp"
        compile_sources = [
            *[str(path) for path in sorted((ROOT / "assets/rtl").glob("*.sv"))],
            *[str(path) for path in sorted((ROOT / "rtl").glob("*.sv"))],
            str(ROOT / "tests/rtl/tb_credit_mvp.sv"),
        ]
        if args.fault == "compile":
            compile_sources.append(str(ROOT / "tests/fixtures/rtl/compile_error.sv"))
        compile_result = execute(
            "rtl_compile",
            [
                "iverilog", "-g2005-sv", "-s", "tb_credit_mvp", "-o", str(rtl_binary),
                *compile_sources,
            ],
            ROOT,
            30,
            log,
        )
        commands.append({key: value for key, value in compile_result.items() if key != "output"})

        if compile_result["exit_code"] == 0:
            simulation_argv = ["vvp", str(rtl_binary)]
            if args.fault == "simulation":
                simulation_argv.append("+MVP_FORCE_FAIL")
            simulation = execute("rtl_simulation", simulation_argv, run_dir, 60, log)
            commands.append({key: value for key, value in simulation.items() if key != "output"})
            tests.extend(parse_rtl_results(simulation["output"]))
        else:
            simulation = None
            tests.extend({
                "id": test_id,
                "layer": "rtl",
                "status": "FAIL",
                "detail": "RTL compilation failed",
            } for test_id in EXPECTED_RTL_TESTS)

        vcd_path = run_dir / "waveform.vcd"
        if vcd_path.exists():
            try:
                convert_vcd(vcd_path, run_dir / "waveform.json")
            except Exception as exc:  # Evidence must survive conversion failure.
                waveform_error = str(exc)
                log.write(f"\nWAVEFORM CONVERSION ERROR: {exc}\n")
        else:
            waveform_error = "waveform.vcd was not generated"

    duration = time.monotonic() - overall_started
    passed = sum(test["status"] == "PASS" for test in tests)
    failed = len(tests) - passed
    command_failed = any(command["exit_code"] != 0 for command in commands)
    status = "PASS" if failed == 0 and not command_failed and waveform_error is None else "FAIL"
    finished_at = iso_now()
    artifacts = {
        "stdout": "stdout.log",
        "junit": "junit.xml",
        "waveform_vcd": "waveform.vcd" if (run_dir / "waveform.vcd").exists() else None,
        "waveform_json": "waveform.json" if (run_dir / "waveform.json").exists() else None,
    }
    payload = {
        "schema_version": 1,
        "run_id": run_id,
        "status": status,
        "started_at": started_at,
        "finished_at": finished_at,
        "duration_seconds": round(duration, 6),
        "source_snapshot": "spacewire-flow-control-2026-09-17",
        "fault_injection": args.fault,
        "tool_versions": {
            "python": tool_version(["python3", "--version"]),
            "iverilog": tool_version(["iverilog", "-V"]),
            "vvp": tool_version(["vvp", "-V"]),
        },
        "commands": commands,
        "tests": tests,
        "summary": {
            "total": len(tests),
            "passed": passed,
            "failed": failed,
            "command_failed": command_failed,
        },
        "waveform_error": waveform_error,
        "artifacts": artifacts,
    }
    atomic_json(run_dir / "run.json", payload)
    write_junit(run_dir / "junit.xml", tests, duration)
    atomic_json(RUNS / "latest.json", {
        "run_id": run_id,
        "status": status,
        "path": str(run_dir.relative_to(ROOT)),
        "finished_at": finished_at,
    })
    print(json.dumps({"run_id": run_id, "status": status, "summary": payload["summary"]}))
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
