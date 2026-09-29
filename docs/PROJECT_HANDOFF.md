# Spec2RTL Copilot — 현재 인수인계

## 기준과 목표

- 기준일: 2026-09-29. 현재 `main`은 ECSS 목차순 Navigator, 5.4.2 최초 선택,
  `Ask AI` 강조, 최신 UI screenshot과 인증된 ngrok 데모 절차를 포함한다.
- 목표: ECSS-E-ST-50-12C Rev.1 Encoding/Data Link 핵심 subset 18개 Requirement에 대해 **Spec → Golden → RTL → Test → Evidence**를 탐색하고 재실행하며, 선택한 근거에 한정된 Q&A를 제공한다.
- 범위: Data Link 11개와 Encoding 7개 카드. First Null·Null detection·Parity gate는 project-owned compliance RTL로 검증하며, imported top-level 통합과 controlled D/S reset은 범위 밖이다.
- 다른 UI 페이지의 생성·분석·판정 기능은 목업 또는 정적 미리보기다. 시연 경로는 **Trace Explorer**와 **Verification Run**이다.

## 현재 구현

| 계층 | 구현 | 기준 파일 |
| --- | --- | --- |
| UI | 단일 HTML/JavaScript, Trace Navigator와 소스·파형·Q&A 화면 | `app/ui/spec2rtl_harness_demo_v1_7_4.html` |
| API | Uvicorn + FastAPI, 기본 `127.0.0.1:8765` | `app/backend/fastapi_server.py` |
| 기존 서버 | 공유 helper와 로컬 실행용 `http.server`; Docker 기본 서버가 아님 | `app/backend/server.py` |
| Trace 데이터 | `manifests/catalog.json`이 UI 기준; SQLite 색인은 변경 시 재구축되는 투영본 | `app/backend/spec_index.py` |
| Q&A | 선택 Requirement 근거만 OpenAI Responses API에 전달, 기본 `gpt-5-mini`; 답변·출처·연결 run을 SQLite에 저장 | `app/backend/qa.py`, `history.py` |
| 검증 | Python Golden regression, Icarus RTL compile/simulation, JUnit·VCD·waveform·로그 생성 | `scripts/run_mvp.py` |

Q&A는 기존 테스트의 결과를 설명하지만 독립적인 RTL PASS/FAIL 판정을 생성하지 않는다. 전체 PDF나 VCD는 OpenAI API로 보내지 않는다. 현재 SQLite 파일은 `app/backend/.runtime/qa-history.sqlite3`이며 schema version 2에 Q&A 이력과 Spec FTS5 색인이 함께 있다.

## 배포와 데이터 경계

- 기본 Compose 서비스는 `spec2rtl-app` **1개 컨테이너**다. 8766의 `spec2rtl-fastapi`는 격리된 검증용 profile이며 현재 기본 실행에 포함되지 않는다.
- `runs/`와 `app/backend/.runtime/`은 호스트에서 읽기/쓰기 bind mount한다. `assets/spec/`와 `.env`는 읽기 전용 mount한다.
- UI, catalog, Golden/RTL/Test 스냅샷은 이미지에 들어간다. ECSS PDF와 `.env`는 이미지에서 제외한다.
- OpenAI API는 외부 서비스다. API 키는 backend가 읽고 브라우저에 전달하지 않는다. PostgreSQL, 별도 simulation worker, React/Nginx frontend는 현재 배포에 없다.
- 현재 구조도: [SystemArchitecture-fastapi-current.png](SystemArchitecture-fastapi-current.png).

시작 및 상태 확인:

```bash
cd /home/hyojinkim/work/3_Company_PJT/spec2rtl_copilot
docker compose up --build -d
docker compose ps
curl -fsS http://127.0.0.1:8765/api/health
```

브라우저 주소는 `http://127.0.0.1:8765/`이며 OpenAPI 문서는 `/docs`다. 사용자 제공 ECSS PDF가 없으면 PDF 페이지 기능은 사용할 수 없지만 trace metadata와 나머지 API는 동작한다. `.env`의 키가 없으면 Q&A의 외부 호출은 실패한다.

## 검증 상태

- 2026-09-29 작업 트리 기준 `python3 -m unittest discover -s tests -v`: 기능 테스트
  **48개 통과**, 로컬에 FastAPI 패키지가 없어 FastAPI 전용 **5개 skip**.
- 동일 코드의 격리 Docker 이미지에서 `test_fastapi_contract.py`: **5개 통과**. 네트워크와 운영 볼륨 없이 모의 Q&A·runner와 임시 SQLite를 사용했다.
- `sha256sum --check manifests/SHA256SUMS`: 전체 통과.
- 현재 `runs/latest.json`은 `20260928T233433+0900-3998fb00`의 **22/22 PASS**를 가리킨다. 실행을 다시 하면 run ID는 달라질 수 있다.
- [Q&A acceptance report](QA_ACCEPTANCE_REPORT.md): 2026-09-28 표본 10/10 적합. 이는 반복 정확도 보증이 아닌 수동 표본 검토다.
- SQLite Q&A 이력 건수는 runtime-local 상태이므로 재현 기준으로 사용하지 않는다.

전체 검증 명령과 격리 FastAPI 테스트 명령은 [README](../README.md)에 있다. 시연 순서는 [DEMO_SCRIPT.md](DEMO_SCRIPT.md)에 정리했다.

## 운영상 주의와 남은 일

- imported `assets/`는 불변 스냅샷이다. 실행 증거는 `scripts/run_mvp.py`를 통해 생성하고 `runs/` 파일을 수동 수정하지 않는다.
- `manifests/catalog.json`이 trace의 기준이다. SQLite Spec index는 검색용 복제본이다.
- Q&A의 범위 판정과 질문 유형 판정은 일부 키워드 규칙을 사용한다. 출처 ID가 존재해도 답변 문장과 출처의 의미 일치까지 자동 판정하지는 않는다.
- ECSS 5.4 확장 분석은 [ENCODING_COVERAGE_MATRIX.md](ENCODING_COVERAGE_MATRIX.md)에 있다. 후보 7개를 모두 실행 카드로 편입했다. 새 3개는 project-owned compliance RTL과 실제 encoder D/S 연결로 검증하며 imported `spw_top` 통합은 별도 작업이다.
- 새 체크아웃 Docker 재현 검증과 실제 OpenAI Q&A 4개를 포함한 시연 리허설을 완료했다. 발표 동선과 예상 질문은 [DEMO_SCRIPT.md](DEMO_SCRIPT.md)에 있다. `.env`, 로컬 SQLite, 사용자 제공 PDF, editor swap 파일은 Git에 넣지 않았다. 참조하지 않는 과거 구조도와 개인 작업용 그림은 로컬 미추적 파일로 남아 있다.
- FastAPI 전환 전 SQLite와 `runs/latest.json` 백업은 `app/backend/.runtime/backups/pre-fastapi-8765-20260928T062116Z/`에 있다. 이 디렉터리는 Git에서 제외된다.

## 다음 세션 시작

```bash
cd /home/hyojinkim/work/3_Company_PJT/spec2rtl_copilot
git status --short --branch
docker compose ps
sed -n '1,220p' docs/PROJECT_HANDOFF.md
```
