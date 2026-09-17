# Trace Explorer 화면 구성 및 용어 가이드

이 문서는 현재 `spec2rtl_harness_demo_v1_7_4.html`의 **Trace Explorer 화면**을 기준으로 작성한 UI 구성 설명서다. 화면 수정 요청 시 위치만 설명하지 않고, 아래의 **표준 용어와 코드 이름**을 함께 사용하기 위한 문서다.

## 1. 전체 화면 구조

```text
┌──────┬──────────────────┬─────────────────────────────────────────────┐
│ Nav  │ TRACE NAVIGATOR  │ SPEC        │ BEHAVIOR    │ TRACE PROPERTIES│
│ Rail │                  ├──────────────┴─────────────┴─────────────────┤
│      │                  │ GOLDEN              │ RTL                   │
│      │                  ├─────────────────────┴───────────────────────┤
│      │                  │ WAVE                                        │
└──────┴──────────────────┴─────────────────────────────────────────────┘
```

- **Navigation Rail**: 화면 가장 왼쪽의 아이콘 전용 세로 메뉴다. 평소 48px이고, 마우스를 올리면 224px로 펼쳐진다.
- **Trace Navigator**: clause와 requirement를 선택하는 왼쪽 탐색 패널이다. 기본 폭은 216px이다.
- **Trace Workspace**: 오른쪽의 6개 패널이 배치되는 작업영역이다.
- Workspace는 상단 3개, 중단 2개, 하단 1개의 **3-2-1 레이아웃**이다.
- 상단 폭 비율은 `38 : 32 : 30`, 행 높이 비율은 `40 : 32 : 28`이다.
- Workspace 패널 사이 간격은 2px이다.
- GOLDEN과 RTL의 기본 폭은 `50 : 50`이며 두 패널 사이 간격도 2px이다.

## 2. 공통 패널 구조

화면의 박스 하나를 사용자 관점에서는 **패널(panel)**, 코드에서는 **dock pane**이라고 부른다.

| 화면 요소 | 권장 용어 | 코드 이름 | 현재 규칙 |
|---|---|---|---|
| 패널 전체 박스 | 패널 / Dock pane | `.dockPane` | 흰색 배경, 외곽선 1px `#aebdcd` |
| 패널 제목 영역 | 패널 헤더 | `.dockHead` | 높이 34px, 제목 12px bold |
| 제목 옆 상세 문자열 | 헤더 상세정보 | `.dockDetail` | 12px regular |
| 실제 내용 영역 | 패널 본문 | `.dockBody` | 패널별 내용과 scroll 포함 |
| 우측 상단 버튼 | 패널 도구 | `.dockTools` | collapse, maximize |
| 선택된 패널 | Active/selected panel | `.contextSelected` | 두께는 1px 유지, 청색 외곽선과 연청색 헤더 |
| 패널 사이 여백 | Gap / gutter | `.traceWorkspace`의 `gap` | 2px |

### 패널 선택 강조와 resize 강조의 차이

- **패널 선택 강조**: 패널을 선택했을 때 박스 전체 외곽선과 헤더가 강조된다.
- **Resize handle 강조**: 패널 경계에 마우스를 올렸을 때만 중앙의 2px 청색선이 나타난다.
- Resize 조작 영역(hit-area)은 8px이지만, 평소에는 보이지 않는다.
- 따라서 “패널 테두리를 바꿔라”와 “resize handle을 바꿔라”는 서로 다른 요청이다.

## 3. Resize 관련 용어

| 위치 | 권장 용어 | 코드 이름 | 동작 |
|---|---|---|---|
| Trace Navigator 오른쪽 | Navigator resize handle | `.navWidthHandle` | Navigator 폭 변경 |
| 상단 패널 사이 | Column splitter | `.gridSplitter.vertical` | SPEC/BEHAVIOR/PROPERTIES 폭 변경 |
| 상·중·하단 사이 | Row splitter | `.gridSplitter.horizontal` | 세 행 높이 변경 |
| GOLDEN과 RTL 사이 | Code splitter | `.codeSplitter` | 두 source 패널 폭 변경 |

수정 요청 예:

- “Navigator resize handle의 hit-area는 유지하고 hover 선만 1px로 변경.”
- “상단 첫 번째 column splitter를 오른쪽으로 이동하여 SPEC 폭을 키움.”
- “중단 code splitter의 기본 위치를 50%로 유지.”
- “GOLDEN/WAVE 사이 row splitter를 아래로 이동.”

## 4. TRACE NAVIGATOR

Trace 탐색을 위한 **tree navigator**다.

| 요소 | 용어 | 코드 이름 |
|---|---|---|
| clause 한 줄 | Tree row | `.treeRow` |
| 현재 선택된 줄 | Selected tree row | `.treeRow.selected` |
| 파란 문서 모양 | Document icon | `.docIcon` |
| clause 제목 | Primary label | `.treeText b` |
| 보조 설명 | Secondary label | `.treeText small` |

요청 예: “TRACE NAVIGATOR의 secondary label을 11px에서 12px로 변경.”

## 5. SPEC 패널

PDF 원문과 trace 대상 위치를 보여주는 패널이다.

| 요소 | 용어 | 코드 이름/함수 |
|---|---|---|
| 상단 PDF 조작줄 | PDF toolbar | `.specToolbar` |
| `− / ＋` | Zoom controls | `adjustSpecZoom()` |
| 현재 확대율 | Zoom indicator | `.specZoom` |
| `‹ / ›` | Page navigation | `changeSpecPage()` |
| 페이지 숫자 | Page counter | `.specPageCount` |
| PDF 표시 영역 | PDF viewport | `.specViewport` |
| PDF 한 페이지 | PDF page canvas | `.specPage` |
| clause 강조 상자 | Spec highlight overlay | `.specHighlight` |

PDF 본문의 글자는 이미지(raster)이므로 일반 CSS 폰트 크기로 변경할 수 없다. `＋/−`는 PDF 페이지가 아니라 화면상의 확대율을 변경한다.

## 6. BEHAVIOR 패널

프로토콜 동작을 상태와 전이로 표현한 **FSM view**다. RTL control FSM이 아니라 counter-state abstraction이다.

| 요소 | 용어 | 표현 |
|---|---|---|
| 원형 노드 | State node | EMPTY, AVAILABLE, MAX |
| 원 안의 큰 글자 | State label | 12px bold |
| 원 안의 작은 조건 | State invariant | 8px |
| 상태 사이 선 | Transition path | 직선 또는 quadratic curve |
| 자기 상태로 돌아오는 선 | Self-loop | cubic curve |
| 전이 이름 | Transition label | 8.5px |
| 화살표 끝 | Arrow marker | `fsmArrow`, `fsmArrowActive` |
| 하단 조건 목록 | FSM legend | `.fsmLegend` |

현재 Requirement에 연결된 **active transition**은 검정색/opacity 1로, 그 밖의 transition은 회색/opacity 0.38로 표시한다. State 사이 active transition label은 bold이며 inactive label은 regular다. Self-loop label의 굵기 규칙은 현재 별도로 적용되지 않는다.

요청 예:

- “AVAILABLE self-loop의 `send_nchar` transition label만 10px 위로 이동.”
- “곡선 geometry는 유지하고 active transition의 선 색상만 변경.”
- “State label이 아니라 invariant 글자 크기를 9px로 변경.”

## 7. TRACE PROPERTIES 패널

현재 selection context와 실행 가능한 동작을 key/value 형식으로 보여준다.

| 요소 | 용어 | 크기/굵기 |
|---|---|---|
| `trace_id`, `clause` 등 왼쪽 열 | Property key (`dt`) | 11px regular |
| 값이 표시되는 오른쪽 열 | Property value (`dd`) | 11px, weight 750 |
| PASS/FAIL | Status badge | 10px, weight 800 |
| Executable behavior | Section heading (`h4`) | 12px bold |
| Trigger/Expected 박스 | Behavior callout | 11px, line-height 1.55 |
| Trigger/Expected 제목 | Callout label (`b`) | 11px bold |

현재 모든 글자는 Arial/Segoe UI 계열의 비례폭 폰트다. `trace_id`도 monospace가 아니다.

## 8. GOLDEN / RTL 패널

실제 trace source를 보여주는 두 개의 **source viewer**다.

| 요소 | 용어 | 코드 이름 |
|---|---|---|
| 파일명 선택 영역 | Source tab bar | `.sourceTabs` |
| 개별 파일명 | Source tab | `.sourceTab` |
| 코드 표시 영역 | Inline source viewer | `.inlineSource` |
| 왼쪽 회색 숫자 영역 | Line-number gutter | `.sourceLine .ln` |
| 코드 본문 | Source text | `.sourceLine .src` |
| 노란색 대상 행 | Focused source line | `.sourceLine.focus` |
| 키워드 색상 구분 | Syntax highlighting | `.synKw`, `.synNum`, `.synStr`, `.synCom`, `.synMacro` |

Source viewer는 11px monospace, line-height 1.55를 사용한다. GOLDEN과 RTL은 동일한 viewer 구조를 공유하며 데이터와 syntax 종류만 다르다.

요청 예: “RTL source viewer의 line-number gutter 폭만 42px에서 36px로 축소.”

## 9. WAVE 패널

실제 실행에서 생성된 VCD 변환 데이터를 SVG 파형으로 표시한다.

| 요소 | 용어 | 설명 |
|---|---|---|
| 상단 정보줄 | Wave toolbar | VCD 파일, timescale, window, cursor |
| 왼쪽 신호 목록 | Signal-name column | signal name과 cursor value |
| 0/1 파형 | Binary trace | 수평선과 수직 edge |
| 다중 비트 파형 | Bus trace | 마름모형 경계와 값 문자열 |
| 세로 점선 | Event cursor / marker | 판정 시점 표시 |
| 가로 시간 숫자 | Time ticks | ns 단위 시간축 |

`waveform.vcd` 링크는 실제 run artifact를 연다. 화면의 SVG는 VCD를 직접 편집하는 곳이 아니라 파형 확인용 renderer다.

## 10. 수정 요청을 명확히 쓰는 형식

다음 네 항목을 함께 쓰면 수정 범위를 오해하기 어렵다.

```text
[대상] BEHAVIOR panel의 AVAILABLE self-loop
[요소] send_nchar transition label
[변경] 현재 위치보다 12px 위로 이동
[유지] curve geometry, arrow marker, active color는 유지
```

다른 예:

```text
[대상] GOLDEN/RTL code row
[요소] code splitter와 panel gap
[변경] 기본 폭 50:50, gap 2px
[유지] drag resize와 keyboard resize
```

## 11. 구현 파일 위치

- UI와 interaction: `app/ui/spec2rtl_harness_demo_v1_7_4.html`
- Backend/API: `app/backend/server.py`
- Trace catalog: `manifests/catalog.json`
- Behavior/FSM data: `manifests/behavior-models.json`
- Selection event 계약: `manifests/selection-context.json`
- UI 회귀 테스트: `tests/test_p0_p2_trace_ui.py`

UI를 수정할 때는 원본 trace source를 복제하지 않고, manifest 데이터와 renderer를 연결하는 현재 구조를 유지한다.
