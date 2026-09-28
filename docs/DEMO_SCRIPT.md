# Spec2RTL Copilot — 5분 시연 순서

## 발표 핵심 문장

“ECSS의 TX-credit 요구사항을 선택하면 대응하는 Golden Model, RTL, Test와
실행 증거가 한 화면에서 연결되고, LLM은 선택된 근거 안에서 그 trace를
설명합니다.”

2026-09-28 최종 리허설에서 실제 OpenAI Q&A 4개가 모두 응답·저장됐고,
25개 Spec/소스/JUnit 링크가 모두 열렸다. 사용 모델은 `gpt-5-mini`였으며
확장 후 Golden + RTL 실행은 22/22 PASS였다.

## 시연 전 준비

1. `spec2rtl_copilot`에서 `docker compose up --build -d`를 실행하고 `docker compose ps`의 `spec2rtl-app`이 healthy인지 확인한다. 8766 검증 서비스는 필요 없다.
2. `http://127.0.0.1:8765/api/health`가 `status: ok`를 반환하는지 확인한다. 사용자 제공 ECSS PDF가 `assets/spec/`에 있는지 확인한다.
3. 라이브 Q&A를 보일 경우에만 로컬 `.env`에 기존 `OPENAI_API_KEY`가 설정돼 있어야 한다. **키 값은 화면이나 터미널에 출력하지 않는다.** 브라우저는 `http://127.0.0.1:8765/`에서 연다.
4. 시연 범위는 ECSS 5.5 Data Link 11개와 5.4 Encoding 7개를 합친 실행 카드 18개다. 5.4 전체 적합성을 주장하지 않으며 top-level 통합과 controlled reset gap은 별도 matrix로 설명한다.

## 0:00–1:10 · Requirement에서 구현까지

1. **Trace Explorer**에서 TRACE NAVIGATOR의 `§5.5.4.f`를 선택한다. `REQ-FC-F`는 credit=0일 때 N-Char 전송을 막는 요구사항이다.
2. **SPEC**의 74쪽 원문 위치, **BEHAVIOR**의 EMPTY 상태, **GOLDEN**과 **RTL**의 강조 소스, **TRACE PROPERTIES**의 선택 trace ID를 차례로 짚는다.
3. 한 문장으로 설명한다: “한 Requirement를 선택하면 Spec, Golden, RTL, Test 근거의 대상 위치가 함께 바뀝니다.”

## 1:10–2:40 · 독립 검증 증거

1. 왼쪽 **Verification Run**으로 이동해 **Run Golden + RTL Test**를 누른다.
2. 성공 시 `22/22 PASS`를 확인한다. **Summary**에서 Golden regression → Encoding Golden → RTL compile → RTL simulation 단계를 보여준다.
3. **Simulation**, **WAVE**, **Test Evidence**에서 로그·파형·JUnit/VCD 링크를 보여준다. PASS는 이 실행의 Test 결과이며 Q&A가 새로 내린 판정이 아니다.
4. 새 실행의 run ID와 소요시간은 매번 바뀌므로 고정 숫자로 말하지 않는다. 실패 시 PASS라고 설명하지 않고 해당 단계 로그를 연다.

## 2:40–4:00 · 근거가 붙은 Q&A

1. **Back to Trace Explorer**로 돌아와 `§5.5.4.f` 선택을 확인한다. **TRACE PROPERTIES → Ask about this trace**를 연다.
2. 질문 예시: `credit이 0인데 N-Char가 대기 중이면 send_nchar와 nchar_ready는 어떻게 되나요?`
3. 답변에서 두 신호가 0이라는 주장과 **Sources**의 Spec·소스·Test·run 링크를 확인한다. 모델의 표현과 인용 개수는 달라질 수 있다.
4. **Previous questions**에서 방금 저장된 질문을 다시 연다. 이력 조회는 모델을 다시 호출하지 않는다. 질문 전송 시 선택한 근거 발췌가 외부 OpenAI API로 전달된다.
5. API 호출이 실패하면 빈 답변을 성공처럼 설명하지 않는다. [수동 검토 결과](QA_ACCEPTANCE_REPORT.md)로 10문항 표본과 한계를 설명한다.

## 4:00–5:00 · 기술 스택과 경계

1. [현재 구조도](SystemArchitecture-fastapi-current.png)에서 브라우저 → 단일 FastAPI 컨테이너 → SQLite/`runs/` → 외부 OpenAI API를 짚는다.
2. `manifests/catalog.json`은 trace 기준이고 SQLite는 **Q&A 이력과 18개 Spec 카드의 FTS5 검색 색인**이라는 점을 설명한다. ECSS PDF와 `.env`는 읽기 전용 mount이며 Docker 이미지에 포함되지 않는다.
3. 범위를 명확히 끝낸다: “이번 MVP는 ECSS 5.5의 11개와 5.4의 7개, 총 18개 trace를 실행합니다. 새 compliance guard의 imported top-level 통합과 controlled reset은 후속 범위입니다.”

## 예상 질문과 답변

### 1. LLM이 RTL의 PASS/FAIL을 판정합니까?

아니다. PASS/FAIL은 Golden regression 2개와 Icarus RTL compile/simulation의 20개
RTL check가 생성한다. LLM은 선택한 Requirement에 연결된 Spec·Golden·RTL·Test와
기존 실행 결과를 설명하고 출처를 붙이는 역할이다.

### 2. 왜 SQLite를 사용했습니까?

현재 단일 사용자·18개 Requirement MVP에서는 배포가 간단하고 별도 DB 서버가
필요 없는 SQLite가 적합하다. Q&A 이력과 Spec FTS5 검색 색인을 저장한다.
다중 사용자와 동시 쓰기, 대규모 문서·trace 관리가 필요해지는 시점에는
PostgreSQL과 별도 검색 계층으로 전환한다.

### 3. Docker에는 무엇이 들어 있습니까?

기본 구성은 FastAPI, 정적 UI, Golden Model, Icarus Verilog runner를 담은
컨테이너 1개다. SQLite와 run evidence는 호스트에 bind mount하며, ECSS PDF와
`.env`는 읽기 전용으로 연결한다. OpenAI API는 컨테이너 밖의 외부 서비스다.

### 4. OpenAI로 어떤 데이터가 전달됩니까?

선택한 Requirement의 제한된 Spec 발췌와 연결된 Golden·RTL·Test 발췌만
전달한다. 전체 PDF와 전체 VCD는 전송하지 않는다. API 키도 backend에서만
읽으며 브라우저로 전달하지 않는다.

### 5. Chapter 5.4는 어디까지 확장했습니까?

7개 후보를 모두 편입해 전체 18개가 됐다. First Null은 실제 encoder D/S 출력,
Null detection과 parity gate는 project-owned compliance RTL로 직접 검증한다.
다만 imported `spw_top`에 이 guard를 연결하는 제품 RTL 통합은 별도다.

### 6. 결과 재현성은 어떻게 확인했습니까?

새 Git checkout에서 Docker 이미지를 다시 만들고 FastAPI·SQLite 검색·소스
조회·JUnit 조회·Golden/RTL 실행을 확인했다. 그 과정에서 빈 checkout의
SQLite 디렉터리 권한 문제를 발견해 수정했으며, 확장 후 22/22 PASS와 FastAPI
계약 테스트 5/5 통과를 확인했다.

### 7. 규모가 커지면 가장 먼저 무엇을 분리합니까?

simulation worker를 API 서버에서 분리하고 작업 queue를 둔다. 이어서 SQLite를
PostgreSQL로 바꾸고 run artifact를 별도 저장소로 옮긴다. 현재 구조도에는 이
확장 경계를 표시했지만 MVP에는 아직 구현하지 않았다.

## 실패 시 대응

- Q&A가 지연되면 저장된 **Previous questions**를 열고, 라이브 호출 실패임을
  밝힌 뒤 기존 답변의 출처 링크를 시연한다.
- Run이 실패하면 PASS라고 설명하지 않고 실패 단계의 로그를 연다. 시간이
  부족하면 기존 PASS run의 JUnit과 waveform을 보여준다.
- PDF 페이지가 열리지 않으면 재배포가 제한된 사용자 제공 파일임을 설명하고,
  catalog에 저장된 clause·page·excerpt와 연결 소스를 보여준다.
- Docker 상태가 비정상이면 `docker compose ps`와 `/api/health`까지만 확인하고
  현장에서 재빌드를 반복하지 않는다.

SQLite 상태를 숫자로 보여줄 필요가 있을 때만 다음 명령을 사용한다. 이력 건수는 시연 질문을 보낸 뒤 증가할 수 있다.
새 DB에서는 첫 검색 시 Spec 색인이 만들어지므로, 아래 검색 API를 먼저 호출한다.

```bash
curl -fsS 'http://127.0.0.1:8765/api/spec/search?q=zero%20credit' >/dev/null
docker compose exec -T spec2rtl-app python3 -c \
  "import sqlite3; c=sqlite3.connect('/app/app/backend/.runtime/qa-history.sqlite3'); print('qa_history', c.execute('SELECT count(*) FROM qa_history').fetchone()[0]); print('spec_requirements', c.execute('SELECT count(*) FROM spec_requirements').fetchone()[0])"
```

## 시연 판정 기준

- 선택 Requirement가 Spec·Golden·RTL·WAVE에 일관되게 반영된다.
- 검증 실행의 실제 상태와 7개 Test 결과, JUnit/VCD가 열람된다.
- Q&A가 선택 Requirement의 출처를 제시하고, 저장된 답변을 다시 열 수 있다.
- 시연자가 실행 Test의 PASS와 LLM 설명을 구분한다.
