# Spec2RTL Copilot — ECSS 5.4 Encoding Layer Coverage Matrix

## 결론

5.4 후보 7개를 모두 실행 카드로 편입했다. 기존 4개에 First Null, 완전한
첫 Null 검출, parity gate 3개를 추가해 전체 실행 범위는 기존 11개에서
**18개**로 늘었다. 새 3개는 imported asset을 변경하지 않고 프로젝트 소유의
Golden oracle과 compliance RTL로 검증한다.

`5.4 전체 compliance`를 선언하지 않는다. 특히 5.4.2의 Enable/gotNull 전달 조건,
5.4.4의 순차적 Data/Strobe reset과 기존 `spw_top`에 대한 compliance guard
통합은 아직 완료되지 않았다.

표시:

- **완료**: 해당 동작의 RTL, Golden, 직접 Test가 존재한다.
- **부분**: 핵심 동작은 있으나 조항 전체나 enable/reset 조건이 부족하다.
- **1차 완료**: runner·catalog·waveform과 표준 실행 결과에 편입했다.
- **2차 완료**: 전용 bit-level Test와 project-owned compliance RTL로 편입했다.

## Coverage matrix

| No. | 후보 Trace 카드 | ECSS clause | RTL | Golden | 기존 Test | 편입 판단 | 남은 작업 |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1 | 직렬화 순서와 Data/Control character encoding | 5.4.2.a–b, 5.4.3.1–.2 | 완료 | 완료 | 완료 | **1차 완료** | `REQ-ENC-SYMBOL`로 편입. 전체 256 DATA sweep와 control-code 조합은 standalone 회귀로 보조 |
| 2 | Data-Strobe encoding/decoding core | 5.4.4.a–b | 완료 | 완료 | 완료 | **1차 완료, 범위 제한** | `REQ-ENC-DS-CORE`로 편입. 5.4.4.c–f는 카드 범위에서 제외 |
| 3 | First Null의 첫 parity와 최초 Strobe transition | 5.4.5 | 완료 | 완료 | 완료 | **2차 완료** | `REQ-ENC-FIRST-NULL`: 실제 encoder 출력에서 첫 D/S=`01` 직접 판정 |
| 4 | Null detection과 gotNull 유지/clear | 5.4.6 | 완료 | 완료 | 완료 | **2차 완료** | `REQ-ENC-NULL-DETECT`: `011101000`, hold, RX-disable clear 직접 판정 |
| 5 | Odd parity 오류 검출과 gotNull gate | 5.4.3.4, 5.4.7 | 완료 | 완료 | 완료 | **2차 완료** | `REQ-ENC-PARITY-GATE`: raw/valid error를 분리해 pre/post-gotNull gate 판정 |
| 6 | 최초 edge 이후 727 ns–1 µs Disconnect 검출 | 5.4.8 | 완료 | 완료 | 완료 | **1차 완료** | `REQ-ENC-DISCONNECT`로 850 ns check를 편입 |
| 7 | ESC+ESC/EOP/EEP 오류 검출 | 5.4.9 | 완료 | 완료 | 완료 | **1차 완료** | `REQ-ENC-ESC`로 세 invalid 조합과 gotNull gate를 편입 |

## 근거 파일

| No. | RTL 근거 | Golden 근거 | 기존 Test 근거 |
| ---: | --- | --- | --- |
| 1 | `assets/rtl/spw_enc.sv`의 `w_tx_load_bits`, TX shift, RX parser | `SpWEncoder.send_char()`, `SpWDecoder.feed_bit()` | `tb_spw_enc_standalone.sv`: control 왕복, DATA 256개, 혼합 순서 |
| 2 | `spw_enc.sv`의 `ow_tx_data_bit`, `ow_tx_strobe_bit`, `w_rx_changed` | `SpWEncoder.tick()`, `SpWDecoder.tick()` | `tb_spw_enc_standalone.sv` self-loopback와 recovered clock 관찰 |
| 3 | `spw_enc.sv`의 odd-parity 계산과 D/S 출력 | `golden/encoding_compliance.py`의 `ds_encode()` | `tb_credit_mvp.sv`: 첫 출력 D/S=`01` |
| 4 | `rtl/spw_encoding_compliance.sv`의 9-bit detector와 gotNull latch | `NullParityGuard` | 8 bit까지 억제, 9 bit에서 assert, hold와 RX-disable clear |
| 5 | compliance RTL의 `rx_enable && gotNull && raw_error` gate | `NullParityGuard.parity_error()` | gotNull 전/후와 RX disable 이후 직접 비교 |
| 6 | `spw_phy_v2.sv`의 `r_seen_any_transition`, `r_no_change_cnt` | `SpWDecoder.tick()`, `reset_framing()` | `tb_phy.sv`, Golden scenario 6 |
| 7 | `spw_datalink_v2.sv`의 `r_rx_pending_esc`, `w_esc_error` | `SpWLink.on_char()` | `tb_esc_rx.sv`, Golden scenario 25 |

## 이번 확인 결과

2026-09-28에 기존 자산을 독립 실행했다.

| Test | 결과 | 의미 |
| --- | ---: | --- |
| `tb_spw_enc_standalone.sv` | **14/14 PASS** | control code, Null/BC pair, DATA 256개, 혼합 순서, parity 오류와 reset 복구 |
| `tb_phy.sv` | **PASS** | 첫 edge 이전 억제, 850 ns disconnect, reconnect reset과 재활성화 |
| `tb_esc_rx.sv` | **PASS** | Null 수신, 상태별 protocol violation, invalid ESC pair |

이 독립 Test 결과와 7개 Encoding 카드를 `scripts/run_mvp.py`의 표준
JUnit/result ID와 UI waveform preset에 편입했다. 공식 실행
`20260928T233433+0900-3998fb00`은 Golden 2개와 RTL 20개, 총 **22/22 PASS**다.

## 확인된 gap

### 1. 5.4.2 전체는 현재 카드로 선언할 수 없음

`spw_enc`는 문자 순서와 parity를 처리하지만 표준의 Transmit Enable/Receive
Enable 레벨 인터페이스 대신 `i_enc_reset` pulse를 사용한다. 또한 gotNull 이전
문자를 data link layer로 전달하지 않는 조건은 encoding module 내부가 아니라
data-link FSM에서 처리된다. 외부 동작 등가성을 입증하기 전에는 5.4.2 전체
compliance로 표시하지 않는다.

### 2. 5.4.4의 controlled reset이 부족함

정상 D/S encoding 식과 power-up reset은 구현돼 있다. 그러나 ErrorReset에서
Data와 Strobe를 500 ns 이상의 간격으로 순차 reset하는 5.4.4.c–e는 현재
`spw_enc`에서 직접 구현·검증되지 않았다. 1차 카드는 5.4.4.a–b만 다룬다.

### 3. Compliance guard의 top-level 통합은 별도임

새 compliance RTL은 실제 encoder D/S 출력과 함께 runner에서 검증되지만 imported
`assets/rtl/spw_top.sv`에는 인스턴스되지 않는다. 제품 RTL 통합을 주장하려면
top-level의 RX Enable, raw parity error, gotNull 경계를 이 모듈에 연결해야 한다.

### 4. 기존 raw parity 출력은 그대로 유지됨

imported decoder의 raw `parity_err`는 진단 신호로 유지했다. 새 compliance RTL의
`ow_parity_error`를 ECSS가 정의한 유효 error로 사용한다. 기존 top 출력은 아직
이 유효 error로 교체되지 않았다.

## 편입 순서

1. **ENC-1 Character/Control encoding**: 기존 14-check standalone Test를 표준
   `MVP_RESULT`로 변환한다.
2. **ENC-6 Disconnect**: 850 ns와 first-edge/reconnect 조건을 result로 분리한다.
3. **ENC-7 ESC error**: ESC+ESC/EOP/EEP를 직접 주입한다.
4. **ENC-2 D/S core**: 정상 식과 power-up 0만 명시적으로 범위 제한한다.
5. **ENC-3/4 First Null·Null detection**: bit-level Test와 compliance RTL 편입 완료.
6. **ENC-5 Parity gate**: raw/valid error 분리와 직접 Test 편입 완료.

## 정량 결론

| 단계 | 총 카드 수 | 조건 |
| --- | ---: | --- |
| 현재 | **18** | ECSS 5.5 subset 11개 + 5.4 실행 카드 7개 |
| 이후 5.6 일부 | **20~22** | Packet, EOP/EEP, Time-code만 추가 |

5.3 cable/LVDS 전기 특성, 5.6 distributed interrupt·routing, 5.7 전체 MIB는
현재 RTL로 검증할 수 없으므로 이 수치에 포함하지 않는다.
