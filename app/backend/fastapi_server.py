"""FastAPI preview of the existing local MVP API."""

from __future__ import annotations

import json
import os
import pathlib
import re
import sqlite3
import subprocess

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.concurrency import run_in_threadpool

import server as legacy
from history import list_answers, save_answer
from qa import QAError, answer_question
from spec_index import search_spec


app = FastAPI(title="Spec2RTL Copilot MVP", version="1.0")


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        self.status = status
        self.code = code
        self.message = message


def json_result(payload: dict, status: int = 200) -> JSONResponse:
    return JSONResponse(payload, status_code=status, headers={"Cache-Control": "no-store"})


@app.exception_handler(ApiError)
def api_error(_request: Request, exc: ApiError) -> JSONResponse:
    return json_result({"error": {"code": exc.code, "message": exc.message}}, exc.status)


@app.exception_handler(RequestValidationError)
def validation_error(_request: Request, _exc: RequestValidationError) -> JSONResponse:
    return json_result({"error": {"code": "BAD_REQUEST", "message": "Invalid request"}}, 400)


@app.exception_handler(StarletteHTTPException)
def http_error(_request: Request, exc: StarletteHTTPException) -> JSONResponse:
    if exc.status_code == 404:
        return json_result({"error": {"code": "NOT_FOUND", "message": "Unknown endpoint"}}, 404)
    return json_result({"error": {"code": "BAD_REQUEST", "message": str(exc.detail)}}, exc.status_code)


@app.exception_handler(FileNotFoundError)
def missing_file(_request: Request, exc: FileNotFoundError) -> JSONResponse:
    return api_error(_request, ApiError(404, "NOT_FOUND", str(exc)))


@app.exception_handler(ValueError)
def bad_value(_request: Request, exc: ValueError) -> JSONResponse:
    return api_error(_request, ApiError(400, "BAD_REQUEST", str(exc)))


@app.exception_handler(KeyError)
def bad_key(_request: Request, exc: KeyError) -> JSONResponse:
    return api_error(_request, ApiError(400, "BAD_REQUEST", str(exc)))


def query_value(request: Request, key: str, default: str = "") -> str:
    return request.query_params.get(key, default)


def file_result(path: pathlib.Path, content_type: str, inline: bool = False) -> Response:
    body = path.read_bytes()
    disposition = "inline" if inline else "attachment"
    return Response(body, media_type=content_type,
                    headers={"Content-Disposition": f'{disposition}; filename="{path.name}"',
                             "Cache-Control": "no-store"})


@app.get("/", include_in_schema=False)
@app.get("/index.html", include_in_schema=False)
def index() -> Response:
    return Response(legacy.UI.read_bytes(), media_type="text/html; charset=utf-8")


@app.get("/api/catalog")
def catalog() -> JSONResponse:
    data = legacy.read_json(legacy.CATALOG)
    data["pilot"]["spec_available"] = legacy.SPEC_PDF.is_file()
    data["pilot"]["spec_total_pages"] = legacy.SPEC_TOTAL_PAGES
    data["behavior_models"] = legacy.read_json(legacy.BEHAVIOR_MODELS)["models"]
    return json_result(data)


@app.get("/api/latest")
def latest() -> JSONResponse:
    return json_result(legacy.latest_bundle())


@app.get("/api/qa/history")
def qa_history(request: Request) -> JSONResponse:
    requirement_id = query_value(request, "requirement_id")
    valid = {item["id"] for item in legacy.read_json(legacy.CATALOG)["requirements"]}
    if requirement_id not in valid:
        raise ValueError("Requirement is outside the TX-credit pilot")
    limit = int(query_value(request, "limit", "5"))
    if not 1 <= limit <= 20:
        raise ValueError("History limit must be 1–20")
    try:
        items = list_answers(requirement_id, limit)
    except (sqlite3.Error, OSError, ValueError) as exc:
        raise ApiError(503, "HISTORY_UNAVAILABLE", "Q&A history is unavailable") from exc
    return json_result({"requirement_id": requirement_id, "items": items})


@app.get("/api/spec/search")
def spec_search(request: Request) -> JSONResponse:
    query = query_value(request, "q")
    limit = int(query_value(request, "limit", "20"))
    try:
        items = search_spec(query, legacy.read_json(legacy.CATALOG), limit)
    except (sqlite3.Error, OSError) as exc:
        raise ApiError(503, "SPEC_INDEX_UNAVAILABLE", "Spec search is unavailable") from exc
    return json_result({"query": query.strip(), "source": "manifests/catalog.json", "items": items})


@app.get("/api/spec/pdf")
def spec_pdf() -> Response:
    return file_result(legacy.SPEC_PDF, "application/pdf", inline=True)


@app.get("/api/spec/page")
def spec_page(request: Request) -> Response:
    if not legacy.SPEC_PDF.is_file():
        raise FileNotFoundError("Local ECSS PDF is not installed")
    page = int(query_value(request, "page", "0"))
    if not 1 <= page <= legacy.SPEC_TOTAL_PAGES:
        raise ValueError(f"PDF page must be in range 1..{legacy.SPEC_TOTAL_PAGES}")
    legacy.SPEC_PAGE_CACHE.mkdir(parents=True, exist_ok=True)
    image = legacy.SPEC_PAGE_CACHE / f"page-{page}.png"
    with legacy.SPEC_RENDER_LOCK:
        if not image.exists():
            prefix = legacy.SPEC_PAGE_CACHE / f"page-{page}"
            try:
                result = subprocess.run(
                    ["pdftoppm", "-f", str(page), "-l", str(page), "-png", "-r", "120",
                     "-singlefile", str(legacy.SPEC_PDF), str(prefix)],
                    text=True, capture_output=True, timeout=30, check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise ValueError(f"Unable to render PDF page: {exc}") from exc
            if result.returncode != 0 or not image.exists():
                raise ValueError(f"Unable to render PDF page: {result.stderr.strip()}")
    return file_result(image, "image/png", inline=True)


@app.get("/api/source")
def source(request: Request) -> JSONResponse:
    rel = query_value(request, "path")
    if not rel or pathlib.PurePosixPath(rel).is_absolute():
        raise ValueError("A repository-relative source path is required")
    path = (legacy.ROOT / rel).resolve()
    if not any(path.is_relative_to(root) for root in legacy.ALLOWED_SOURCE_ROOTS):
        raise ValueError("Source path is outside the approved roots")
    if path.suffix.lower() not in legacy.ALLOWED_SUFFIXES or not path.is_file():
        raise ValueError("Source type is not approved")
    focus_start = max(1, int(query_value(request, "focus_start", query_value(request, "start", "1"))))
    focus_end = max(focus_start, int(query_value(request, "focus_end", query_value(request, "end", str(focus_start)))))
    start = max(1, int(query_value(request, "start", str(max(1, focus_start - 5)))))
    end = max(start, int(query_value(request, "end", str(focus_end + 5))))
    end = min(end, start + 299)
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    excerpt = [{"line": n, "text": lines[n - 1]} for n in range(start, min(end, len(lines)) + 1)]
    return json_result({"path": rel, "start": start, "end": end,
                        "focus_start": focus_start, "focus_end": focus_end, "lines": excerpt})


@app.get("/api/artifact")
def artifact(request: Request) -> Response:
    allowed = {
        "junit": ("junit.xml", "application/xml"),
        "vcd": ("waveform.vcd", "text/plain; charset=utf-8"),
        "waveform": ("waveform.json", "application/json"),
        "log": ("stdout.log", "text/plain; charset=utf-8"),
    }
    name = query_value(request, "name")
    if name not in allowed:
        raise ValueError("Unknown or disallowed artifact")
    run_id = request.query_params.get("run_id")
    if run_id is None:
        _, run_dir = legacy.latest_run_dir()
    else:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+._-]{0,119}", run_id):
            raise ValueError("Invalid run ID")
        run_dir = (legacy.ROOT / "runs" / run_id).resolve()
        if not run_dir.is_relative_to((legacy.ROOT / "runs").resolve()):
            raise ValueError("Invalid run ID")
    filename, content_type = allowed[name]
    path = run_dir / filename
    if not path.is_file():
        raise FileNotFoundError(f"Artifact not found: {filename}")
    return file_result(path, content_type, inline=name in {"junit", "waveform", "log"})


@app.get("/api/health")
def health() -> JSONResponse:
    return json_result({"status": "ok", "run_locked": legacy.RUN_LOCK.locked()})


async def json_body(request: Request, *, qa: bool = False) -> dict:
    content_length = request.headers.get("content-length")
    if content_length is not None and int(content_length) > 4096:
        raise ApiError(400, "BAD_REQUEST", "Request body must be 1–4096 bytes" if qa else "Invalid JSON request")
    chunks = bytearray()
    async for chunk in request.stream():
        chunks.extend(chunk)
        if len(chunks) > 4096:
            raise ApiError(400, "BAD_REQUEST", "Request body must be 1–4096 bytes" if qa else "Invalid JSON request")
    body = bytes(chunks)
    if qa and not body:
        raise ApiError(400, "BAD_REQUEST", "Request body must be 1–4096 bytes")
    try:
        parsed = json.loads(body or b"{}")
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ApiError(400, "BAD_REQUEST", "Invalid JSON request") from exc
    if not isinstance(parsed, dict):
        raise ApiError(400, "BAD_REQUEST", "Invalid JSON request")
    return parsed


def answer_qa(body: dict) -> dict:
    if not isinstance(body.get("requirement_id"), str) or not isinstance(body.get("question"), str):
        raise ApiError(400, "BAD_REQUEST", "requirement_id and question are required")
    catalog = legacy.read_json(legacy.CATALOG)
    req = next((item for item in catalog["requirements"] if item["id"] == body["requirement_id"]), None)
    if req is None:
        raise ApiError(400, "UNKNOWN_REQUIREMENT", "Requirement is outside the TX-credit pilot")
    try:
        _, run_dir = legacy.latest_run_dir()
        run = legacy.read_json(run_dir / "run.json")
    except FileNotFoundError:
        run = None
    try:
        answer = answer_question(req, body["question"], run)
    except QAError as exc:
        raise ApiError(exc.status, exc.code, str(exc)) from exc
    linked_run = run["run_id"] if run and any(item["kind"] == "evidence" for item in answer["sources"]) else None
    try:
        saved = save_answer(req["id"], body["question"].strip(), answer, linked_run)
        answer["history_saved"] = True
        answer["history_id"] = saved["id"]
    except (sqlite3.Error, OSError, ValueError):
        answer["history_saved"] = False
    return answer


@app.post("/api/qa")
async def qa(request: Request) -> JSONResponse:
    body = await json_body(request, qa=True)
    return json_result(await run_in_threadpool(answer_qa, body))


def run_mvp(body: dict) -> JSONResponse:
    if not legacy.RUN_LOCK.acquire(blocking=False):
        raise ApiError(409, "RUN_IN_PROGRESS", "An MVP run is already in progress")
    try:
        fault = body.get("fault", "none")
        if fault != "none" and os.environ.get("SPEC2RTL_ENABLE_TEST_FAULTS") != "1":
            raise ApiError(403, "FAULT_DISABLED", "Fault injection is disabled")
        if fault not in {"none", "compile", "simulation"}:
            raise ApiError(400, "BAD_REQUEST", "Unsupported fault mode")
        argv = ["python3", str(legacy.RUNNER)]
        if fault != "none":
            argv += ["--fault", fault]
        try:
            result = subprocess.run(argv, cwd=legacy.ROOT, text=True, capture_output=True,
                                    timeout=120, check=False)
        except subprocess.TimeoutExpired as exc:
            raise ApiError(504, "RUN_TIMEOUT", "MVP runner exceeded 120 seconds") from exc
        bundle = legacy.latest_bundle()
        bundle["runner"] = {"exit_code": result.returncode, "stdout": result.stdout,
                            "stderr": result.stderr}
        return json_result(bundle, 200 if result.returncode == 0 else 422)
    finally:
        legacy.RUN_LOCK.release()


@app.post("/api/run")
async def run(request: Request) -> JSONResponse:
    # Acquire inside the worker so the event loop stays responsive during simulation.
    body = await json_body(request)
    return await run_in_threadpool(run_mvp, body)
