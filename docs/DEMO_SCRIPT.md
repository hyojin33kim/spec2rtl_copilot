# Spec2RTL Copilot — 5분 시연 순서

## 시연 전 준비

1. `spec2rtl_copilot`에서 `docker compose up --build -d`를 실행하고 `docker compose ps`의 `spec2rtl-app`이 healthy인지 확인한다. 8766 검증 서비스는 필요 없다.
2. `http://127.0.0.1:8765/api/health`가 `status: ok`를 반환하는지 확인한다. 사용자 제공 ECSS PDF가 `assets/spec/`에 있는지 확인한다.
3. 라이브 Q&A를 보일 경우에만 로컬 `.env`에 기존 `OPENAI_API_KEY`가 설정돼 있어야 한다. **키 값은 화면이나 터미널에 출력하지 않는다.** 브라우저는 `http://127.0.0.1:8765/`에서 연다.
4. 시연 범위는 TX-credit Requirement 4개다. 좌측의 다른 목업 페이지와 TRACE NAVIGATOR의 `Filter clause…` 입력란을 기능 시연에 사용하지 않는다.

## 0:00–1:10 · Requirement에서 구현까지

1. **Trace Explorer**에서 TRACE NAVIGATOR의 `§5.5.4.f`를 선택한다. `REQ-FC-F`는 credit=0일 때 N-Char 전송을 막는 요구사항이다.
2. **SPEC**의 74쪽 원문 위치, **BEHAVIOR**의 EMPTY 상태, **GOLDEN**과 **RTL**의 강조 소스, **TRACE PROPERTIES**의 선택 trace ID를 차례로 짚는다.
3. 한 문장으로 설명한다: “한 Requirement를 선택하면 Spec, Golden, RTL, Test 근거의 대상 위치가 함께 바뀝니다.”

## 1:10–2:40 · 독립 검증 증거

1. 왼쪽 **Verification Run**으로 이동해 **Run Golden + RTL Test**를 누른다.
2. 성공 시 `7/7 PASS`를 확인한다. **Summary**에서 Golden regression → RTL compile → RTL simulation 단계를 보여준다.
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
2. `manifests/catalog.json`은 trace 기준이고 SQLite는 **Q&A 이력과 4개 Spec clause의 FTS5 검색 색인**이라는 점을 설명한다. ECSS PDF와 `.env`는 읽기 전용 mount이며 Docker 이미지에 포함되지 않는다.
3. 범위를 명확히 끝낸다: “이번 MVP는 4개 TX-credit 요구사항과 실행 가능한 trace에 한정합니다. 다른 화면의 설계 생성·원인 분석은 목업입니다.”

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
