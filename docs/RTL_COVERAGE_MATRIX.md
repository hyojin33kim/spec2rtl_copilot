# Spec2RTL Copilot — RTL 기준 12개 Coverage Matrix

## 판정 기준

- **RTL**: 요구 동작을 구현하거나 직접 관측할 수 있는 RTL symbol이 존재한다.
- **Golden**: 같은 동작을 비교할 참조 모델 로직이 존재한다.
- **기존 Test**: 해당 동작을 직접 확인하는 기존 test가 있다. `부분`은 인접 동작만
  확인하거나 요구조건 전체를 직접 판정하지 않는 경우다.
- **MVP 편입**: 현재 catalog, trace, 전용 executable check, waveform 및 Q&A
  evidence가 모두 연결돼 있다.
- 이 표는 파일 존재 여부만 확인한 목록이 아니다. 현재 trace 카드와 같은 수준으로
  올리기 위해 남은 작업을 함께 표시한다.

표시: **완료** = 직접 근거 확보, **부분** = 조건부 또는 보강 필요,
**없음** = 직접 검증 없음, **미편입** = 구현·test는 있으나 현재 MVP에서 실행하지 않음.

## Coverage matrix

| No. | Trace 카드 | ECSS clause | RTL | Golden | 기존 Test | MVP 편입 | 판단 및 남은 작업 |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | FCT 수신 시 TX credit +8 | 5.5.4.e.1 | 완료 | 완료 | 완료 | 완료 | `REQ-FC-E1`; 현재 기준 카드 |
| 2 | N-Char 송신 시 TX credit −1 | 5.5.4.e.2 | 완료 | 완료 | 완료 | 완료 | `REQ-FC-E2`; 현재 기준 카드 |
| 3 | TX credit=0에서 N-Char 차단 | 5.5.4.f | 완료 | 완료 | 완료 | 완료 | `REQ-FC-F`; 현재 기준 카드 |
| 4 | TX credit 최대 56과 overflow | 5.5.4.h/j, 5.5.5.a.2 | 완료 | 완료 | 완료 | 완료 | `REQ-FC-HJ`; 현재 기준 카드 |
| 5 | Receive-credit 증가·감소 | 5.5.4.l.1/l.2 | 완료 | 완료 | 완료 | 완료 | `REQ-RC-ACCOUNT`; FCT +8과 N-Char −1 직접 판정 |
| 6 | 초기 FCT 발행량 | 5.5.4.k | 완료 | 완료 | 완료 | 완료 | `REQ-FCT-INIT`; `min(RX_FIFO_DEPTH/8, 7)` 직접 판정 |
| 7 | FIFO 여유 기반 FCT 발행 조건 | 5.5.4.n/o/p | 완료 | 완료 | 완료 | 완료 | `REQ-FCT-ELIGIBLE`; free-space와 receive-credit 상한 직접 판정 |
| 8 | Receive credit=0에서 N-Char 수신 오류 | 5.5.5.a.1 | 완료 | 완료 | 완료 | 완료 | `REQ-RC-ERR`; 신규 직접 오류 주입 test 추가 |
| 9 | Broadcast > FCT > N-Char > Null 우선순위 | 5.5.6 | 부분 | 부분 | 완료 | 미편입 | 정상 경로는 구현됨. Timecode starvation 완화가 절대 우선순위와 충돌하는지 규격 판정 필요 |
| 10 | ErrorReset → Run 링크 초기화 | 5.5.7.2–5.5.7.7 | 완료 | 완료 | 완료 | 완료 | `REQ-LINK-INIT`; 성공 경로를 직접 판정. PortReset FIFO semantics는 제외 |
| 11 | Disconnect·Parity·ESC·Credit 오류 처리 | 5.4.7–5.4.9, 5.5.7.7.b, 5.5.8.2–5.5.8.3 | 완료 | 완료 | 완료 | 완료 | `REQ-LINK-ERROR`; 3개 원인과 기존 credit check를 연결 |
| 12 | 미완성 packet EEP 삽입과 TX 잔여 폐기 | 5.5.8.4.a.1–a.4 | 완료 | 완료 | 완료 | 완료 | `REQ-PKT-RECOVERY`; RX EEP와 TX flush를 직접 판정 |

## 근거 파일

| No. | RTL 근거 | Golden 근거 | 기존 Test 근거 |
| ---: | --- | --- | --- |
| 1 | `spw_datalink_v2.sv`: `r_tx_credit`, `w_got_fct` | `SpWLink.on_char()` | `tests/rtl/tb_credit_mvp.sv`, `scenario_3_flow_control()` |
| 2 | `spw_datalink_v2.sv`: `r_tx_credit`, `w_send_nchar` | `SpWLink.note_tx_char_sent()` | `tests/rtl/tb_credit_mvp.sv`, `tb_race_check.sv` |
| 3 | `spw_datalink_v2.sv`: `w_send_nchar`, `ow_nchar_ready` | `SpWNode._select_next_tx_char()` | `tests/rtl/tb_credit_mvp.sv`, `tb_priority.sv` |
| 4 | `spw_datalink_v2.sv`: `w_tx_credit_err`, `ow_err_credit` | `SpWLink.on_char()`, `MAX_CREDIT` | `tests/rtl/tb_credit_mvp.sv`, `tb_credit.sv`, credit-boundary tests |
| 5 | `spw_datalink_v2.sv`: `r_rx_credit` update | `SpWLink.on_char()`, `note_tx_char_sent()` | `tb_credit.sv`, `scenario_3_flow_control()` |
| 6 | `spw_datalink_v2.sv`: `r_req_initial_fct` | `SpWLink._enter(CONNECTING)` | `tb_credit.sv`, `scenario_1_link_init()` |
| 7 | `spw_datalink_v2.sv`: `w_fct_send_ok` | `SpWNode.tick()`: `req_fct` 계산 | `tb_credit.sv`, `tb_eep_recovery.sv`, `scenario_8_credit_boundary_sweep()` |
| 8 | `spw_datalink_v2.sv`: `w_rx_credit_err` | `SpWLink.on_char()`: `rx_credit_budget <= 0` | 직접 test 없음 |
| 9 | `spw_datalink_v2.sv`: 송신 priority comb | `SpWNode._select_next_tx_char()` | `tb_priority.sv`, `tb_decision17_tc_starvation.sv`, `scenario_24_decision17_timecode_starvation_worst_case()` |
| 10 | `spw_datalink_v2.sv`: `w_next_state`, timer | `SpWLink.tick()`, `_enter()` | `tb_fsm_smoke.sv`, `tb_esc_rx.sv`, `tb_spw_top_loopback.sv`, scenarios 1/2 |
| 11 | `spw_phy_v2.sv`, `spw_enc.sv`, `spw_datalink_v2.sv`: error path | `SpWDecoder`, `SpWLink.tick()` | `tb_phy.sv`, `tb_spw_enc_standalone.sv`, `tb_err_reset.sv`, `tb_esc_rx.sv`, scenarios 5/6/14/25 |
| 12 | `spw_datalink_v2.sv`: `r_eep_pending`, `r_tx_flushing` | `SpWLink._enter()`, `SpWNode.tick()` recovery path | `tb_eep_recovery.sv`, `tb_tx_flush_recovery.sv`, scenarios 18/20/22 |

주요 파일 위치:

- RTL: `assets/rtl/spw_datalink_v2.sv`, `spw_enc.sv`, `spw_phy_v2.sv`
- Golden: `assets/golden/spw_ref_model.py`
- Golden scenarios: `assets/golden/spw_ref_model_test_v5.py`
- 기존 RTL tests: `assets/tb/`
- 현재 MVP test: `tests/rtl/tb_credit_mvp.sv`

## 정량 요약

| 항목 | 결과 |
| --- | ---: |
| 현재 MVP에 완전 편입 | 11 / 12 |
| RTL 구현 존재 | 11 완료 + 1 조건부 / 12 |
| Golden 구현 존재 | 11 완료 + 1 조건부 / 12 |
| 직접 Test 존재 | 11 완료 + 1 조건부 / 12 |
| 새 RTL 구현 없이 편입 완료 | 7 / 7 후보 |

`No. 8`에는 직접 오류 주입 test를 새로 추가했다. 남은 `No. 9`는 test 추가보다
먼저 DECISION-17의 starvation 완화 정책을 ECSS 5.5.6의 절대 우선순위와 어떻게
설명할지 결정해야 한다.

## 편입 우선순위

1. **No. 6 초기 FCT**, **No. 7 FCT 발행 조건**: 현재 TX-credit 화면과 신호를
   재사용할 수 있어 추가 비용이 가장 작다.
2. **No. 5 receive-credit**와 **No. 8 zero receive-credit error**: 전용 RTL test를
   보강하면 Flow Control 범위를 닫을 수 있다.
3. **No. 10 링크 초기화**, **No. 11 오류 처리**: 상태·오류별 check와 waveform
   preset이 필요하지만 기존 test 자산이 충분하다.
4. **No. 12 recovery**: RX EEP와 TX flush를 하나의 UI 카드, 두 개의 executable
   check로 구성한다.
5. **No. 9 송신 우선순위**: DECISION-17 규격 판정 후 편입한다.

## Chapter 경계와 제외 사항

- 이 matrix는 **ECSS 5.5 Data Link Layer 핵심 subset**의 확장 계획이다. 5.5 전체
  compliance 선언이 아니다.
- ECSS 5.5.7.1.e는 PortReset 시 TX/RX FIFO clear를 요구하지만 현재 RTL은
  PortReset에서 FIFO를 보존한다. 이 차이를 해결하기 전까지 PortReset FIFO 동작은
  No. 10의 검증 범위에서 제외한다.
- Physical electrical/cable 특성, distributed interrupt와 routing은 현재 RTL과
  test 범위 밖이므로 12개 matrix에 포함하지 않는다.
- 후보를 MVP에 편입하려면 각 카드마다 catalog/trace metadata, 전용 실행 check,
  JUnit result, waveform preset, Q&A acceptance case를 모두 추가해야 한다.
