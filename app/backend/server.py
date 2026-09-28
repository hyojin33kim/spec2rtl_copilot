#!/usr/bin/env python3
"""Local-only API and static server for the Spec2RTL MVP."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sqlite3
import subprocess
import sys
import threading
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from qa import QAError, answer_question
from history import list_answers, save_answer
from spec_index import search_spec


ROOT = pathlib.Path(__file__).resolve().parents[2]
UI = ROOT / "app/ui/spec2rtl_harness_demo_v1_7_4.html"
CATALOG = ROOT / "manifests/catalog.json"
BEHAVIOR_MODELS = ROOT / "manifests/behavior-models.json"
RUNNER = ROOT / "scripts/run_mvp.py"
SPEC_PDF = ROOT / "assets/spec/ECSS-E-ST-50-12C-Rev.1(15May2019).pdf"
SPEC_TOTAL_PAGES = 124
SPEC_PAGE_CACHE = ROOT / "app/backend/.runtime/spec-pages"
ALLOWED_SOURCE_ROOTS = tuple((ROOT / path).resolve() for path in (
    "assets/golden", "assets/rtl", "assets/tb", "tests/rtl",
    "requirements", "trace", "manifests",
))
ALLOWED_SUFFIXES = {".py", ".sv", ".yaml", ".json", ".md", ".log", ".xml"}
RUN_LOCK = threading.Lock()
SPEC_RENDER_LOCK = threading.Lock()


def read_json(path: pathlib.Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def split_stage_logs(log: str) -> dict[str, str]:
    """Split the persisted runner transcript without losing the raw log."""
    parts = re.split(r"\n===== ([^=\n]+) =====\n", log)
    return {
        parts[index].strip(): parts[index + 1].strip()
        for index in range(1, len(parts) - 1, 2)
    }


def latest_run_dir() -> tuple[dict, pathlib.Path]:
    latest_path = ROOT / "runs/latest.json"
    if not latest_path.exists():
        raise FileNotFoundError("No test run exists")
    latest = read_json(latest_path)
    run_dir = (ROOT / latest["path"]).resolve()
    runs_root = (ROOT / "runs").resolve()
    if not run_dir.is_relative_to(runs_root):
        raise ValueError("Invalid latest run path")
    return latest, run_dir


def latest_bundle() -> dict:
    latest, run_dir = latest_run_dir()
    run = read_json(run_dir / "run.json")
    log = (run_dir / "stdout.log").read_text(encoding="utf-8", errors="replace")
    wave_path = run_dir / "waveform.json"
    return {"latest": latest, "run": run, "log": log, "stage_logs": split_stage_logs(log),
            "waveform": read_json(wave_path) if wave_path.exists() else None}


class MvpServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, enable_test_faults: bool = False):
        super().__init__(address, handler)
        self.enable_test_faults = enable_test_faults


class Handler(BaseHTTPRequestHandler):
    server_version = "Spec2RTLMVP/1"

    def json_response(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def error_response(self, status: int, code: str, message: str) -> None:
        self.json_response({"error": {"code": code, "message": message}}, status)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        try:
            if parsed.path in ("/", "/index.html"):
                body = UI.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif parsed.path == "/api/catalog":
                catalog = read_json(CATALOG)
                catalog["pilot"]["spec_available"] = SPEC_PDF.is_file()
                catalog["pilot"]["spec_total_pages"] = SPEC_TOTAL_PAGES
                catalog["behavior_models"] = read_json(BEHAVIOR_MODELS)["models"]
                self.json_response(catalog)
            elif parsed.path == "/api/latest":
                self.json_response(latest_bundle())
            elif parsed.path == "/api/qa/history":
                self.serve_qa_history(urllib.parse.parse_qs(parsed.query))
            elif parsed.path == "/api/spec/search":
                self.serve_spec_search(urllib.parse.parse_qs(parsed.query))
            elif parsed.path == "/api/spec/pdf":
                self.serve_file(SPEC_PDF, "application/pdf", inline=True)
            elif parsed.path == "/api/spec/page":
                self.serve_spec_page(urllib.parse.parse_qs(parsed.query))
            elif parsed.path == "/api/source":
                self.serve_source(urllib.parse.parse_qs(parsed.query))
            elif parsed.path == "/api/artifact":
                self.serve_artifact(urllib.parse.parse_qs(parsed.query))
            elif parsed.path == "/api/health":
                self.json_response({"status": "ok", "run_locked": RUN_LOCK.locked()})
            else:
                self.error_response(404, "NOT_FOUND", "Unknown endpoint")
        except FileNotFoundError as exc:
            self.error_response(404, "NOT_FOUND", str(exc))
        except (ValueError, KeyError) as exc:
            self.error_response(400, "BAD_REQUEST", str(exc))

    def serve_source(self, query: dict) -> None:
        rel = query.get("path", [""])[0]
        if not rel or pathlib.PurePosixPath(rel).is_absolute():
            raise ValueError("A repository-relative source path is required")
        path = (ROOT / rel).resolve()
        if not any(path.is_relative_to(root) for root in ALLOWED_SOURCE_ROOTS):
            raise ValueError("Source path is outside the approved roots")
        if path.suffix.lower() not in ALLOWED_SUFFIXES or not path.is_file():
            raise ValueError("Source type is not approved")
        focus_start = max(1, int(query.get("focus_start", query.get("start", ["1"]))[0]))
        focus_end = max(focus_start, int(query.get("focus_end", query.get("end", [str(focus_start)]))[0]))
        start = max(1, int(query.get("start", [str(max(1, focus_start - 5))])[0]))
        end = max(start, int(query.get("end", [str(focus_end + 5)])[0]))
        end = min(end, start + 299)
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        excerpt = [{"line": n, "text": lines[n - 1]} for n in range(start, min(end, len(lines)) + 1)]
        self.json_response({"path": rel, "start": start, "end": end,
                            "focus_start": focus_start, "focus_end": focus_end,
                            "lines": excerpt})

    def serve_file(self, path: pathlib.Path, content_type: str, inline: bool = False) -> None:
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        disposition = "inline" if inline else "attachment"
        self.send_header("Content-Disposition", f'{disposition}; filename="{path.name}"')
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def serve_artifact(self, query: dict) -> None:
        name = query.get("name", [""])[0]
        allowed = {
            "junit": ("junit.xml", "application/xml"),
            "vcd": ("waveform.vcd", "text/plain; charset=utf-8"),
            "waveform": ("waveform.json", "application/json"),
            "log": ("stdout.log", "text/plain; charset=utf-8"),
        }
        if name not in allowed:
            raise ValueError("Unknown or disallowed artifact")
        run_id = query.get("run_id", [None])[0]
        if run_id is None:
            _, run_dir = latest_run_dir()
        else:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+._-]{0,119}", run_id):
                raise ValueError("Invalid run ID")
            run_dir = (ROOT / "runs" / run_id).resolve()
            if not run_dir.is_relative_to((ROOT / "runs").resolve()):
                raise ValueError("Invalid run ID")
        filename, content_type = allowed[name]
        path = run_dir / filename
        if not path.is_file():
            raise FileNotFoundError(f"Artifact not found: {filename}")
        self.serve_file(path, content_type, inline=name in {"junit", "waveform", "log"})

    def serve_qa_history(self, query: dict) -> None:
        requirement_id = query.get("requirement_id", [""])[0]
        catalog = read_json(CATALOG)
        if requirement_id not in {item["id"] for item in catalog["requirements"]}:
            raise ValueError("Requirement is outside the TX-credit pilot")
        limit = int(query.get("limit", ["5"])[0])
        if not 1 <= limit <= 20:
            raise ValueError("History limit must be 1–20")
        try:
            items = list_answers(requirement_id, limit)
        except (sqlite3.Error, OSError, ValueError):
            self.error_response(503, "HISTORY_UNAVAILABLE", "Q&A history is unavailable")
            return
        self.json_response({"requirement_id": requirement_id, "items": items})

    def serve_spec_search(self, query: dict) -> None:
        text = query.get("q", [""])[0]
        limit = int(query.get("limit", ["20"])[0])
        try:
            items = search_spec(text, read_json(CATALOG), limit)
        except (sqlite3.Error, OSError):
            self.error_response(503, "SPEC_INDEX_UNAVAILABLE", "Spec search is unavailable")
            return
        self.json_response({"query": text.strip(), "source": "manifests/catalog.json", "items": items})

    def serve_spec_page(self, query: dict) -> None:
        if not SPEC_PDF.is_file():
            raise FileNotFoundError("Local ECSS PDF is not installed")
        page = int(query.get("page", ["0"])[0])
        if not 1 <= page <= SPEC_TOTAL_PAGES:
            raise ValueError(f"PDF page must be in range 1..{SPEC_TOTAL_PAGES}")
        SPEC_PAGE_CACHE.mkdir(parents=True, exist_ok=True)
        image = SPEC_PAGE_CACHE / f"page-{page}.png"
        with SPEC_RENDER_LOCK:
            if not image.exists():
                prefix = SPEC_PAGE_CACHE / f"page-{page}"
                try:
                    result = subprocess.run(
                        ["pdftoppm", "-f", str(page), "-l", str(page), "-png",
                         "-r", "120", "-singlefile", str(SPEC_PDF), str(prefix)],
                        text=True, capture_output=True, timeout=30, check=False,
                    )
                except (OSError, subprocess.TimeoutExpired) as exc:
                    raise ValueError(f"Unable to render PDF page: {exc}") from exc
                if result.returncode != 0 or not image.exists():
                    raise ValueError(f"Unable to render PDF page: {result.stderr.strip()}")
        self.serve_file(image, "image/png", inline=True)

    def do_POST(self) -> None:  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/qa":
            self.ask_qa()
            return
        if path != "/api/run":
            self.error_response(404, "NOT_FOUND", "Unknown endpoint")
            return
        if not RUN_LOCK.acquire(blocking=False):
            self.error_response(409, "RUN_IN_PROGRESS", "An MVP run is already in progress")
            return
        try:
            size = min(int(self.headers.get("Content-Length", "0")), 4096)
            body = json.loads(self.rfile.read(size) or b"{}")
            fault = body.get("fault", "none")
            if fault != "none" and not self.server.enable_test_faults:
                self.error_response(403, "FAULT_DISABLED", "Fault injection is disabled")
                return
            if fault not in {"none", "compile", "simulation"}:
                self.error_response(400, "BAD_REQUEST", "Unsupported fault mode")
                return
            argv = ["python3", str(RUNNER)]
            if fault != "none":
                argv += ["--fault", fault]
            try:
                result = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True,
                                        timeout=120, check=False)
            except subprocess.TimeoutExpired:
                self.error_response(504, "RUN_TIMEOUT", "MVP runner exceeded 120 seconds")
                return
            bundle = latest_bundle()
            bundle["runner"] = {"exit_code": result.returncode, "stdout": result.stdout,
                                "stderr": result.stderr}
            self.json_response(bundle, 200 if result.returncode == 0 else 422)
        except (json.JSONDecodeError, ValueError) as exc:
            self.error_response(400, "BAD_REQUEST", str(exc))
        finally:
            RUN_LOCK.release()

    def ask_qa(self) -> None:
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 4096:
                raise QAError("BAD_REQUEST", "Request body must be 1–4096 bytes")
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict) or not isinstance(body.get("requirement_id"), str) or not isinstance(body.get("question"), str):
                raise QAError("BAD_REQUEST", "requirement_id and question are required")
            catalog = read_json(CATALOG)
            req = next((item for item in catalog["requirements"] if item["id"] == body["requirement_id"]), None)
            if req is None:
                raise QAError("UNKNOWN_REQUIREMENT", "Requirement is outside the TX-credit pilot")
            try:
                _, run_dir = latest_run_dir()
                run = read_json(run_dir / "run.json")
            except FileNotFoundError:
                run = None
            answer = answer_question(req, body["question"], run)
            linked_run = run["run_id"] if run and any(
                item["kind"] == "evidence" for item in answer["sources"]) else None
            try:
                saved = save_answer(req["id"], body["question"].strip(), answer, linked_run)
                answer["history_saved"] = True
                answer["history_id"] = saved["id"]
            except (sqlite3.Error, OSError, ValueError):
                answer["history_saved"] = False
            self.json_response(answer)
        except (ValueError, json.JSONDecodeError):
            self.error_response(400, "BAD_REQUEST", "Invalid JSON request")
        except QAError as exc:
            self.error_response(exc.status, exc.code, str(exc))

    def log_message(self, fmt: str, *args) -> None:
        print(f"{self.address_string()} - {fmt % args}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--enable-test-faults", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    server = MvpServer((args.host, args.port), Handler, args.enable_test_faults)
    print(f"Spec2RTL MVP: http://{args.host}:{server.server_port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
