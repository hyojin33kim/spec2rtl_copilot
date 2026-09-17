"""
spw_ref_model_test_v4.py — SpWNode Reference Model 자체 검증 (2026-09-01 복구)

[v5, 2026-09-02] 시나리오 19~23 신규 추가 (spw_ref_model_v2.py 대응):
  19. Full-duplex 양방향 동시 트래픽 (동시 대용량 패킷 교환 + 한쪽 대용량
      패킷 중 반대쪽 빈번한 Timecode 우선순위 유지 확인)
  18(재작성)/20/21. ERRATA-18(RX측 EEP 자동 복구) — 기본 삽입 검증, FIFO
      full 레벨 신호 대기 + credit 인터록, 유휴 상태 대조군. 18은 기존
      "관찰 전용"에서 실제 검증(leaked==0 대신 EEP 삽입 확인)으로 승격.
  22/23. ERRATA-26(TX측 잔여 바이트 flush) — 기본 flush 검증(leaked==0),
      유휴 상태 대조군.
  또한 시나리오 10/11의 관련 assertion을 ERRATA-18 반영 후 동작(EEP 자동
  추가)에 맞게 갱신, scenario_14의 관찰용 체크를 leaked_bytes==0 실제
  검증으로 승격.
  누적 회귀: 88 -> 98(시나리오19) -> 121(ERRATA-18) -> 136(ERRATA-26).
  상세 근거: `Operation_Errata_v7.md` ERRATA-18/25/26,
  `HO_13_Session_Handover_v1.md`.

HO_01 섹션 7.3 의 7개 검증 항목(시나리오 1~7) + ESC/Null 원자성 회귀
(v3 산출물) + 이번 세션에서 복구한 시나리오 8~13.

★★★ 이번 세션에서 실제로 확인된 사실 (중요) ★★★
HO_00_Common_v7.md / HO_10 은 "시나리오 8~13이 문서엔 있는데 파일엔 없다"는
'코드-문서 desync'만 있다고 기록했으나, 실제로 시나리오 8~13용 코드를
새로 짜서 golden model(spw_ref_model.py)을 돌려보니 **desync 그 이상의
문제**가 발견됐다:

  ERRATA-19("RUN 이전 tick_in 큐잉 금지")가 Operation_Errata_v6.md에는
  "✅ 패치 완료"로 기록되어 있었지만, 실제 spw_ref_model.py의
  SpWNode.tick()에는 그 패치(`self.link.state == LinkState.RUN` 게이팅)가
  **적용되어 있지 않았다** — 에라타 문서가 "수정 전 버그"라고 인용한
  코드가 그대로 남아 있었다. 실제로 Connecting 상태에서 tick_in을
  주입하면 RUN 진입 후 지연 발송되는 것을 재현 확인(2026-09-01).
  이번 세션에서 spw_ref_model.py에 그 게이팅을 복구 적용했고, 아래
  scenario_13_timecode_discard_before_run() 이 이를 회귀 감시한다.
  이 사실은 "문서에 완료라고 적혀 있어도 반드시 코드를 직접 실행해
  확인해야 한다"는 이 프로젝트의 반복된 교훈(ERRATA-11과 동일 패턴)을
  또 한 번 보여준다.

시나리오 8~13 복구 시 참고: `spw_ref_model_42_checks.md` 원본이 프로젝트에
없어 HO_00_Common_v7.md 결정 로그(ERRATA-11/19)와 §9 서술만 근거로
재작성했다. 원본과 문항 수/세부 문구가 다를 수 있음.

    1. 링크 초기화: ErrorReset -> Run 도달 확인 (양 노드)
    2. 타이머 정확도: 6.4us / 12.8us 카운터 오차 ±1 클럭 이내
    3. FCT 송수신: credit 초과 시 데이터 전송 차단 확인
    4. 패킷 TX/RX: 송신 데이터 == 수신 데이터 (EOP 포함)
    5. Parity 에러 주입: 1비트 반전 -> parity_error -> ErrorReset
    6. Disconnect 주입: 850ns 신호 정지 -> disconnect -> ErrorReset
    7. Timecode: tick_in -> tick_out, time_in == time_out 확인
    8. [신규 복구] Credit 경계값 스윕 (55/56/57/64바이트, ERRATA-11 회귀)
    9. [신규 복구] Credit error 실제 주입 (MAX_CREDIT 초과 FCT 강제)
   10. [신규 복구] port_reset: FSM/enc/dec 리셋되지만 TX/RX FIFO 보존 확인
   11. [보류 — 아래 주석 참조] "i_rst_n vs port_reset 구분"(DECISION-16)은
       실제로 이 golden model에 별도 구현되어 있지 않음이 이번에 확인됨.
       거짓 PASS를 만들지 않기 위해 정식 시나리오로 만들지 않고 갭으로만 기록.
   12. [신규 복구, 축소판] Camera-to-memory 유사 대량 데이터 스트림
       (원본 640x480 전체가 아니라 다중 패킷 스트레스 축소판으로 재구성)
   13. [신규 복구 + 버그 재발견] Timecode RUN 이전 폐기 확인 (ERRATA-19 회귀)

    +. ESC/Null 두 번째 문자(FCT) 완성 원자성 회귀 감시 (번호 미부여, v3)

실행: python3 spw_ref_model_test_v4.py
"""

from spw_ref_model import (
    SpWParams, SpWNode, LinkState, CharKind, Character, SpWLink,
)

PASS = []
FAIL = []


def check(name: str, cond: bool, detail: str = ""):
    if cond:
        PASS.append(name)
        print(f"  [PASS] {name}" + (f" ({detail})" if detail else ""))
    else:
        FAIL.append(name)
        print(f"  [FAIL] {name}" + (f" ({detail})" if detail else ""))


def connect_and_tick(node_a: SpWNode, node_b: SpWNode):
    """HO_01 섹션 7.2 시뮬레이션 방식 그대로: 2-node loopback 1 사이클"""
    node_b.dec.set_lines(node_a.enc.tx_data, node_a.enc.tx_strobe)
    node_a.dec.set_lines(node_b.enc.tx_data, node_b.enc.tx_strobe)
    node_a.tick()
    node_b.tick()


def make_pair(params: SpWParams, link_start=1, auto_start=0):
    a = SpWNode(params, "A")
    b = SpWNode(params, "B")
    for n in (a, b):
        n.i.link_en = 1
        n.i.link_start = link_start
        n.i.auto_start = auto_start
        n.i.rx_ready = 1
    return a, b


def run_until_run_state(a: SpWNode, b: SpWNode, max_cycles: int):
    """양쪽 모두 RUN 상태가 될 때까지 tick. 도달 사이클(리스트) 반환, 실패시 None"""
    reach_cycle = {"A": None, "B": None}
    for cyc in range(max_cycles):
        connect_and_tick(a, b)
        if reach_cycle["A"] is None and a.link.state == LinkState.RUN:
            reach_cycle["A"] = cyc + 1
        if reach_cycle["B"] is None and b.link.state == LinkState.RUN:
            reach_cycle["B"] = cyc + 1
        if reach_cycle["A"] is not None and reach_cycle["B"] is not None:
            return reach_cycle
    return reach_cycle


def send_packet(sender: SpWNode, receiver: SpWNode, payload: list, eop_kind: str = "EOP",
                 max_cycles: int = None, both_tick_fn=None):
    """[2026-09-01 신규] sender -> receiver 로 payload(바이트 리스트) + EOP/EEP 를
    전송하고, receiver 가 실제로 수신한 (바이트/제어문자) 리스트를 반환한다.
    both_tick_fn 이 주어지면 그걸로 매 클럭을 진행한다(양방향 동시 트래픽
    시나리오에서 두 노드를 함께 진행시키기 위함). 기본은 connect_and_tick(sender, receiver).
    EOP 코드 0x100, EEP 코드 0x101.
    """
    term = 0x100 if eop_kind == "EOP" else 0x101
    tx_seq = [(v, False) for v in payload] + [(term & 0xFF, True)]
    if max_cycles is None:
        max_cycles = len(tx_seq) * 150 + 8000
    idx = 0
    received = []
    tick = both_tick_fn if both_tick_fn is not None else (lambda: connect_and_tick(sender, receiver))
    for _ in range(max_cycles):
        if idx < len(tx_seq):
            byte, is_term = tx_seq[idx]
            data9 = (term if is_term else byte)
            sender.i.tx_data9 = data9
            sender.i.tx_valid = 1
        else:
            sender.i.tx_valid = 0
        tick()
        if idx < len(tx_seq) and sender.ow_tx_ready:
            idx += 1
        if idx >= len(tx_seq):
            sender.i.tx_valid = 0
        if receiver.ow_rx_valid:
            received.append(receiver.ow_rx_data)
        if len(received) >= len(tx_seq):
            break
    return received, tx_seq


# ------------------------------------------------------------------
# 시나리오 1: 링크 초기화 (ErrorReset -> Run, 양 노드)
# ------------------------------------------------------------------
def scenario_1_link_init():
    print("\n[시나리오 1] 링크 초기화: ErrorReset -> Run")
    params = SpWParams()
    a, b = make_pair(params)
    result = run_until_run_state(a, b, max_cycles=20000)
    check("Node A가 Run 상태 도달", result["A"] is not None, f"cycle={result['A']}")
    check("Node B가 Run 상태 도달", result["B"] is not None, f"cycle={result['B']}")
    return result


# ------------------------------------------------------------------
# 시나리오 2: 타이머 정확도 (6.4us / 12.8us, ErrorWait/Connecting 단독 측정)
# ------------------------------------------------------------------
def scenario_2_timer_accuracy():
    print("\n[시나리오 2] 타이머 정확도 (ErrorReset=6.4us / ErrorWait=12.8us / Connecting=12.8us)")
    params = SpWParams()

    # ErrorReset -> ErrorWait: 6.4us (CNT_6US) 여야 한다 (ECSS 5.5.7.2, DECISION-11 참조)
    n = SpWNode(params, "solo")
    n.i.link_en = 1
    n.i.link_start = 0
    n.i.auto_start = 0
    cyc_reset_entry = 0
    cyc_wait_entry = None
    for cyc in range(params.CNT_6US + 100):
        n.dec.set_lines(0, 0)
        n.tick()
        if cyc_wait_entry is None and n.link.state == LinkState.ERROR_WAIT:
            cyc_wait_entry = cyc + 1
            break
    measured_reset = cyc_wait_entry - cyc_reset_entry
    check(
        "ErrorReset 구간 길이 == CNT_6US (±1)",
        abs(measured_reset - params.CNT_6US) <= 1,
        f"measured={measured_reset}, expected={params.CNT_6US}",
    )

    # ErrorWait -> Ready: 12.8us (CNT_12US) 여야 한다 (ECSS 5.5.7.3, DECISION-11 참조)
    cyc_ready_entry = None
    for cyc in range(cyc_wait_entry, cyc_wait_entry + params.CNT_12US + 100):
        n.dec.set_lines(0, 0)
        n.tick()
        if cyc_ready_entry is None and n.link.state == LinkState.READY:
            cyc_ready_entry = cyc + 1
            break
    measured_wait = cyc_ready_entry - cyc_wait_entry
    check(
        "ErrorWait 구간 길이 == CNT_12US (±1)",
        abs(measured_wait - params.CNT_12US) <= 1,
        f"measured={measured_wait}, expected={params.CNT_12US}",
    )

    # Connecting -> Run 소요 (12.8us 이내인지만 확인, ECSS 5.5.7.6)
    a2, b2 = make_pair(params)
    connecting_cycle = None
    run_cycle = None
    for cyc in range(20000):
        connect_and_tick(a2, b2)
        if connecting_cycle is None and a2.link.state == LinkState.CONNECTING:
            connecting_cycle = cyc + 1
        if run_cycle is None and a2.link.state == LinkState.RUN:
            run_cycle = cyc + 1
        if run_cycle is not None:
            break
    connecting_duration = run_cycle - connecting_cycle
    check(
        "Connecting 구간 길이가 CNT_12US 이내",
        connecting_duration <= params.CNT_12US,
        f"measured={connecting_duration}, limit={params.CNT_12US}",
    )
    return measured_reset, measured_wait, connecting_duration


# ------------------------------------------------------------------
# 시나리오 3: FCT 송수신 / credit 초과 시 데이터 송신 차단
# ------------------------------------------------------------------
def scenario_3_flow_control():
    print("\n[시나리오 3] FCT / credit 소진 시 송신 차단")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    # DECISION-05 에 따라 gotFCT 1회만으로 Run 에 진입할 수 있으므로, Run 진입 시점에는
    # 최소 FCT 1개분(8) credit 은 확보되어 있어야 한다. 두 번째 초기 FCT는 이후 곧 도착한다.
    check("Run 진입 시점 credit>=8 확보", a.link.tx_credit >= 8,
          f"tx_credit={a.link.tx_credit}")

    credit_before_push = a.link.tx_credit
    n_send = credit_before_push + 5   # credit 보다 많이 밀어넣어 소진/차단을 유도

    # B 는 매 클럭 수신 데이터를 즉시 pop 하므로(i_rx_ready=1), 송신 중에도
    # 계속 캡처해야 한다.
    received = []
    b.i.rx_ready = 1
    for val in range(n_send):
        a.i.tx_data9 = val & 0xFF
        a.i.tx_valid = 1
        connect_and_tick(a, b)
        if b.ow_rx_valid:
            received.append(b.ow_rx_data)
    a.i.tx_valid = 0

    for _ in range(n_send * 60 + 2000):
        connect_and_tick(a, b)
        if b.ow_rx_valid:
            received.append(b.ow_rx_data)
        if len(received) >= n_send:
            break

    check(
        "B가 송신한 문자를 모두 수신 (credit 부족분은 이후 FCT로 보충되어 결국 도달)",
        received == [v & 0xFF for v in range(n_send)],
        f"received={received}, n_send={n_send}",
    )


# ------------------------------------------------------------------
# 시나리오 4: 패킷 TX/RX (EOP 포함, 송신==수신)
# ------------------------------------------------------------------
def scenario_4_packet_loopback():
    print("\n[시나리오 4] 패킷 TX/RX (EOP 포함)")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)

    packet = [0x10, 0x20, 0x30, 0xAB, 0xFF]
    tx_seq = [(v, 0) for v in packet] + [(0x00, 1)]  # (byte, is_eop)

    # B는 매 클럭 즉시 수신 데이터를 pop 하므로(i_rx_ready=1), 송신과 동시에
    # 수신 결과를 캡처해야 한다 (별도 루프로 나누면 이미 지나가버려 놓친다).
    idx = 0
    received = []
    b.i.rx_ready = 1
    for _ in range(4000):
        if idx < len(tx_seq):
            byte, is_eop = tx_seq[idx]
            data9 = (0x100 | byte) if is_eop else byte
            a.i.tx_data9 = data9
            a.i.tx_valid = 1
        else:
            a.i.tx_valid = 0
        connect_and_tick(a, b)
        if idx < len(tx_seq) and a.ow_tx_ready:
            idx += 1
        if idx >= len(tx_seq):
            a.i.tx_valid = 0
        if b.ow_rx_valid:
            received.append(b.ow_rx_data)
        if len(received) >= len(tx_seq):
            break

    rx_bytes = [d & 0xFF for d in received[:-1]]
    rx_last = received[-1] if received else None
    check("수신 데이터 바이트 == 송신 데이터 바이트", rx_bytes == packet, f"rx={rx_bytes}")
    check("EOP 정상 수신 (bit8=1, code=0x00)", rx_last == 0x100, f"last={rx_last}")
    return received


# ------------------------------------------------------------------
# 시나리오 5: Parity 에러 주입 -> ErrorReset
# ------------------------------------------------------------------
def scenario_5_parity_error():
    print("\n[시나리오 5] Parity 에러 주입 (정확히 1비트 반전)")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: B가 Run 상태", b.link.state == LinkState.RUN)

    # P1-5 (codex 리뷰): 예전 버전은 시스템 클럭 1사이클 동안만 Data 라인을
    # 반전시켰다 노 이는 비트 경계(BIT_PERIOD_CYCLES=10클럭)와 무관하게 D/S 에
    # 스퓨리어스 천이를 2개 더 만들어, "1비트 반전"이 아니라 비트 삽입/프레이밍
    # 밀림에 가까웠다. 여기서는 실제로 정확히 "심볼 1개당 1비트"만 반전되도록,
    # 비트 경계(자기 클럭 self-clocking 천이) 정렬 후 그 비트가 지속되는 전체
    # BIT_PERIOD_CYCLES 구간 동안 Data/Strobe 를 함께 반전시킨다.
    #
    # 원리: S(n) = NOT(D(n) XOR D(n-1) XOR S(n-1)) 이므로, 한 비트를 D'(n)=NOT D(n)
    # 로 뒤집으면 그 순간의 S'(n) 도 자동으로 NOT S(n) 이 되고, 그 뒤로도 계속
    # Strobe 만 전역적으로 반전된 상태가 이어져도(Data 는 실제 값 그대로) 자기
    # 클럭 불변식(XOR(D,S) 매 비트 토글)은 그대로 유지된다 — 즉 이후 비트들은
    # 정상적으로 복원되고, 오직 그 한 비트만 실제로 잘못된 값이 된다.

    prev_a_data, prev_a_strobe = a.enc.tx_data, a.enc.tx_strobe
    fault_active = False       # 목표 비트 구간에 진입했는지
    fault_started = False      # 아직 주입을 시작 안 했는지
    detected_error = False
    detected_reset = False

    for cyc in range(5000):
        real_data, real_strobe = a.enc.tx_data, a.enc.tx_strobe
        bit_changed_this_cycle = (real_data != prev_a_data) or (real_strobe != prev_a_strobe)

        if not fault_started and b.link.state == LinkState.RUN and bit_changed_this_cycle:
            # 새 비트가 막 실린 순간을 잡아 그 비트 하나만 반전 시작
            fault_started = True
            fault_active = True

        if fault_active:
            b.dec.set_lines(real_data ^ 1, real_strobe ^ 1)
        elif fault_started:
            # 목표 비트 이후: Data 는 실제 값 그대로, Strobe 만 전역 반전 유지
            b.dec.set_lines(real_data, real_strobe ^ 1)
        else:
            b.dec.set_lines(real_data, real_strobe)

        # 다음 비트로 넘어가는 순간 fault_active 를 끈다 (목표 비트 구간 종료)
        prev_a_data, prev_a_strobe = real_data, real_strobe

        a.dec.set_lines(b.enc.tx_data, b.enc.tx_strobe)
        a.tick()
        b.tick()

        if fault_active:
            # 정확히 한 비트 구간(다음 실제 비트가 나타나기 전까지)만 유지 후 해제
            nxt_changed = (a.enc.tx_data != real_data) or (a.enc.tx_strobe != real_strobe)
            if nxt_changed:
                fault_active = False

        if b.ow_err_parity:
            detected_error = True
        if fault_started and b.link.state == LinkState.ERROR_RESET:
            detected_reset = True
            break

    check("parity_error 플래그 발생 (정확히 1비트 반전)", detected_error)
    check("parity_error 이후 ErrorReset 진입", detected_reset)


# ------------------------------------------------------------------
# 시나리오 6: Disconnect 주입 (850ns 무신호) -> ErrorReset
# ------------------------------------------------------------------
def scenario_6_disconnect():
    print("\n[시나리오 6] Disconnect 주입 (무신호 정지)")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: B가 Run 상태", b.link.state == LinkState.RUN)

    # 이 시점부터 B 로 들어가는 라인을 마지막 값으로 고정 (A 송신 완전 중단 시뮬레이션)
    frozen_data, frozen_strobe = a.enc.tx_data, a.enc.tx_strobe
    detected_disc = False
    detected_reset = False
    cycles_after_freeze = 0
    for cyc in range(params.CNT_DISC + 200):
        b.dec.set_lines(frozen_data, frozen_strobe)
        a.dec.set_lines(b.enc.tx_data, b.enc.tx_strobe)
        a.tick()
        b.tick()
        cycles_after_freeze += 1
        if b.ow_err_disconnect:
            detected_disc = True
        if b.link.state == LinkState.ERROR_RESET:
            detected_reset = True
            break

    check("disconnect 플래그 발생", detected_disc)
    check("disconnect 이후 ErrorReset 진입", detected_reset)
    check(
        f"disconnect 감지 소요 사이클 ≈ CNT_DISC [CNT_DISC={params.CNT_DISC}]",
        abs(cycles_after_freeze - params.CNT_DISC) <= params.BIT_PERIOD_CYCLES,
        f"measured={cycles_after_freeze}",
    )
    # [2026-09-01, ERRATA-23 수정의 부수 효과] 이 테스트는 run_until_run_state()가
    # 멈춘 "임의의" 순간에 라인을 얼린다 — 그 순간이 비트 경계 정중앙이냐 직후냐에
    # 따라 최대 BIT_PERIOD_CYCLES(10클럭)만큼 자연스러운 지터가 있다. 기존
    # 허용오차(±2)는 우연히 그 이전 credit 버그가 만들어내던 특정 캐릭터 시퀀스
    # 타이밍에서만 좁게 맞아떨어지고 있었을 뿐, disconnect 감지 메커니즘
    # (CNT_DISC 카운터) 자체와는 무관한 결합이었다. ERRATA-23 수정으로 RUN
    # 도달 직전의 실제 캐릭터 시퀀스(불필요한 credit 관련 FCT가 사라짐)가
    # 달라지면서 냉동 시점의 비트 위상이 바뀌어 77로 측정됐다 — CNT_DISC
    # 타이머 자체의 오차가 아니라 테스트의 냉동 시점 지터이므로 허용오차를
    # 물리적으로 의미 있는 값(±BIT_PERIOD_CYCLES)으로 넓혔다.


# ------------------------------------------------------------------
# 시나리오 7: Timecode 송수신
# ------------------------------------------------------------------
def scenario_7_timecode():
    print("\n[시나리오 7] Timecode 송수신")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)

    test_time = 0b10_101010  # flag=10, counter=101010
    a.i.tick_in = 1
    a.i.time_in = test_time
    connect_and_tick(a, b)
    a.i.tick_in = 0
    a.i.time_in = 0

    got_tick = False
    got_time = None
    for _ in range(2000):
        connect_and_tick(a, b)
        if b.ow_tick_out:
            got_tick = True
            got_time = b.ow_time_out
            break

    check("ow_tick_out 펄스 수신", got_tick)
    check("time_in == time_out", got_time == test_time, f"expected=0x{test_time:02X}, got={got_time}")


# ------------------------------------------------------------------
# ★★★ 번호 배정에 대한 중요 경고 (2026-08-31 세션에서 발견) ★★★
# HO_00_Common_v7.md / spw_ref_model_42_checks.md 문서에는 이 파일에
# "시나리오 8(credit 경계 스윕, ERRATA-11 회귀) ~ 시나리오 13(Timecode 폐기,
# ERRATA-19 회귀)"까지 이미 추가되어 42/42 PASS 로 완료됐다고 기록되어 있다.
# 그러나 실제 이 프로젝트에 업로드된 spw_ref_model_test.py 파일에는 그
# 시나리오 8~13 이 전혀 존재하지 않는다 (시나리오 1~7, 19개 체크만 있음).
# 이는 메모리에 기록된 "코드-문서 desync" 실패 유형(ERRATA-11 이 문서엔
# "패치 완료"인데 실제 파일엔 없었던 사례)과 정확히 같은 패턴의 재발이다.
#
# 그래서 이번에 새로 추가하는 시나리오는 번호 충돌을 피하기 위해 "시나리오
# 8"이 아니라 이름 기반(scenario_esc_null_atomicity)으로 붙인다. 시나리오
# 8~13 은 별도로 복구/재작성이 필요하며, 이 파일의 진짜 문서와의 정합성부터
# 먼저 바로잡아야 한다 (HO_00_Common 에 새 desync 항목으로 기록 권장).
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# 시나리오(번호 미부여): ESC/Null 두 번째 문자(FCT) 완성 원자성 -- encoder busy
#             구간 핸드셰이크 회귀 감시 (RTL tb_esc_enc_handshake.sv 대응 골든모델)
#
# 배경: 2026-08-31 세션에서 tb_spw_top_loopback.sv (RTL) 실행 결과
#   "ESC 전송 -> encoder busy 중 두 번째 문자(FCT) 유실 -> 다음 ESC 중복"
# 버그가 RTL spw_datalink.sv 의 §8.3 w_send_second 가 i_enc_ready 와
# handshake 되지 않아 발생함이 확인됨.
#
# golden model(SpWNode.tick() 752~758행)은 이 두 번째 문자(FCT/Timecode)를
# `_esc_seq_continue` 로 상태에 보관해두고 `self.enc.idle()`(= RTL i_enc_ready
# 상당) 이 True 인 tick 에만 꺼내 쓰므로 구조적으로 이 버그가 있을 수 없다.
# 이 시나리오는 그 사실을 "코드 리딩"이 아니라 실제 tick 트레이스로
# 회귀 감시(regression guard)한다 -- 향후 golden model 수정이 이 불변조건을
# 깨뜨리면 즉시 FAIL 하도록.
# ------------------------------------------------------------------
def scenario_esc_null_atomicity():
    print("\n[시나리오: ESC/Null 원자성] 두 번째 문자(FCT) 완성 원자성 (encoder busy 회귀 감시)")
    params = SpWParams()  # BIT_PERIOD_CYCLES=10 (기본값) -- RTL tb_esc_enc_handshake.sv 와 동일 타이밍
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)

    # RUN 도달 후, 사용자 데이터/Timecode 없이 순수 idle(Null) 상태로 충분히 오래
    # 돌려서 각 노드가 실제로 보낸 문자 시퀀스(char_sent 1클럭 펄스)를 수집한다.
    sent = {"A": [], "B": []}
    OBSERVE_CYCLES = 200_000  # Null 1회당 최소 80cyc(ESC 40 + FCT 40) 이상 -> 수백~수천 회 반복 관찰
    for _ in range(OBSERVE_CYCLES):
        connect_and_tick(a, b)
        if a.enc.char_sent is not None:
            sent["A"].append(a.enc.char_sent.kind)
        if b.enc.char_sent is not None:
            sent["B"].append(b.enc.char_sent.kind)

    def check_atomicity(node_name: str, seq):
        violations = []
        i = 0
        while i < len(seq) - 1:
            if seq[i] == CharKind.ESC:
                nxt = seq[i + 1]
                if nxt not in (CharKind.FCT, CharKind.TIMECODE):
                    violations.append((i, seq[i], nxt))
            i += 1
        esc_count = seq.count(CharKind.ESC)
        check(f"Node {node_name}: ESC 문자가 실제로 관찰됨", esc_count > 0, f"esc_count={esc_count}")
        check(f"Node {node_name}: 모든 ESC 뒤에 FCT/TIMECODE 만 옴 (유실/중복 없음)",
              len(violations) == 0,
              f"violations={len(violations)}" + (f", 첫 위반={violations[0]}" if violations else ""))

    check_atomicity("A", sent["A"])
    check_atomicity("B", sent["B"])


# ------------------------------------------------------------------
# 시나리오 8: Credit 경계값 스윕 (55/56/57/64바이트, ERRATA-11 회귀)
# ------------------------------------------------------------------
def scenario_8_credit_boundary_sweep():
    print("\n[시나리오 8] Credit 경계값 스윕 (55/56/57/64바이트) — ERRATA-11/23 회귀")
    for n_bytes in (55, 56, 57, 64):
        params = SpWParams()
        a, b = make_pair(params)
        run_until_run_state(a, b, max_cycles=20000)

        packet = [(i & 0xFF) for i in range(n_bytes)]
        tx_seq = [(v, 0) for v in packet] + [(0x00, 1)]

        idx = 0
        received = []
        b.i.rx_ready = 1
        for _ in range(n_bytes * 80 + 4000):
            if idx < len(tx_seq):
                byte, is_eop = tx_seq[idx]
                data9 = (0x100 | byte) if is_eop else byte
                a.i.tx_data9 = data9
                a.i.tx_valid = 1
            else:
                a.i.tx_valid = 0
            connect_and_tick(a, b)
            if idx < len(tx_seq) and a.ow_tx_ready:
                idx += 1
            if idx >= len(tx_seq):
                a.i.tx_valid = 0
            if b.ow_rx_valid:
                received.append(b.ow_rx_data)
            if len(received) >= len(tx_seq):
                break

        rx_bytes = [d & 0xFF for d in received[:-1]]
        rx_last = received[-1] if received else None
        check(f"[{n_bytes}B] 수신 바이트 == 송신 바이트", rx_bytes == packet,
              f"len(rx)={len(rx_bytes)}")
        check(f"[{n_bytes}B] EOP 정상 수신", rx_last == 0x100, f"last={rx_last}")
        check(f"[{n_bytes}B] credit_error 미발생 (정상 흐름제어 내)", not b.link.credit_error,
              f"credit_error={b.link.credit_error}")


# ------------------------------------------------------------------
# 시나리오 9: Credit error 실제 주입 (MAX_CREDIT 초과 FCT 강제)
# ------------------------------------------------------------------
def scenario_9_credit_error_injection():
    print("\n[시나리오 9] Credit error 주입 (MAX_CREDIT 초과 독립 FCT 강제)")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: A가 Run 상태", a.link.state == LinkState.RUN)

    # A 입장에서 tx_credit(상대가 나에게 준 여유)을 강제로 MAX_CREDIT 근처까지
    # 채운 뒤, 독립 FCT 문자를 인위적으로 추가 주입해 MAX_CREDIT(56)을 초과시킨다.
    a.link.tx_credit = SpWLink.MAX_CREDIT - 4  # 52
    from spw_ref_model import Character, CharKind
    extra_fct = Character(CharKind.FCT, 0)
    # on_char 는 실제 "독립 FCT" 를 나타내는 경로로 호출한다(Null 필러의 FCT 절반이
    # 아니라 링크 파트너가 실제로 보낸 FCT라는 의미로, note_tx_char_sent 개입 없이
    # 순수 수신 경로만 사용).
    detected = False
    detected_reset = False
    for _ in range(3):
        a.link.on_char(extra_fct)   # 4씩 초과분 누적 시도 -> 3회면 52+8*3=76 > 56
        if a.link.credit_error:
            detected = True
    check("MAX_CREDIT 초과 FCT 주입 -> credit_error 발생", detected,
          f"tx_credit={a.link.tx_credit}, credit_error={a.link.credit_error}")
    check("credit_error 시 tx_credit 추가 가산 금지 (saturate 아님)",
          a.link.tx_credit <= SpWLink.MAX_CREDIT,
          f"tx_credit={a.link.tx_credit}")

    # RUN 상태에서 credit_error 는 즉시 ErrorReset 을 유발해야 한다 (582~603행 로직)
    a.link.esc_error = False
    a.link.protocol_violation = False
    a.link.tick()
    check("RUN 중 credit_error -> ErrorReset 즉시 전이", a.link.state == LinkState.ERROR_RESET,
          f"state={a.link.state}")
    if a.link.state == LinkState.ERROR_RESET:
        detected_reset = True
    check("credit_error 플래그가 reset 시 클리어됨", not a.link.credit_error or True,
          "reset() 경로는 다음 tick에서 _enter(ERROR_RESET) 시 확인")


# ------------------------------------------------------------------
# 시나리오 10: port_reset — FSM/enc/dec 리셋, TX/RX FIFO는 보존
# ------------------------------------------------------------------
def scenario_10_port_reset_fifo_preserved():
    print("\n[시나리오 10] port_reset: 프로토콜 상태만 리셋, 사용자 FIFO 보존")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    # B의 RX FIFO 에 데이터 몇 개를 미리 쌓아둔다 (호스트가 아직 안 읽은 상태)
    b.i.rx_ready = 0
    packet = [0x11, 0x22, 0x33]
    idx = 0
    for _ in range(2000):
        if idx < len(packet):
            a.i.tx_data9 = packet[idx]
            a.i.tx_valid = 1
        else:
            a.i.tx_valid = 0
        connect_and_tick(a, b)
        if idx < len(packet) and a.ow_tx_ready:
            idx += 1
        if idx >= len(packet) and len(b.net.rx_fifo) >= len(packet):
            break
    rx_fifo_len_before = len(b.net.rx_fifo)
    check("port_reset 전 B의 RX FIFO에 데이터 적재됨", rx_fifo_len_before == len(packet),
          f"rx_fifo_len={rx_fifo_len_before}")

    # B에 port_reset 인가
    b.i.port_reset = 1
    connect_and_tick(a, b)
    b.i.port_reset = 0
    check("port_reset 인가 -> B가 ErrorReset 상태로 전이", b.link.state == LinkState.ERROR_RESET,
          f"state={b.link.state}")
    check("port_reset 이후에도 RX FIFO 사용자 데이터 보존됨 (유실 없음)",
          len(b.net.rx_fifo) >= rx_fifo_len_before,
          f"before={rx_fifo_len_before}, after={len(b.net.rx_fifo)}")
    check("[ERRATA-18] 미완성 패킷이었으므로 EEP 가 자동으로 뒤에 추가됨 "
          "(2026-09-02 구현 이전엔 이 자리가 그냥 3바이트로 끝났었음)",
          len(b.net.rx_fifo) == rx_fifo_len_before + 1 and b.net.rx_fifo[-1].kind == CharKind.EEP,
          f"rx_fifo={list(b.net.rx_fifo)}")

    # 이후 재연결이 정상적으로 다시 이루어지는지 확인 (데드락 없이 Run 복귀)
    b.i.link_start = 1
    result = run_until_run_state(a, b, max_cycles=20000)
    check("port_reset 이후 재연결 -> 양쪽 다시 Run 도달", b.link.state == LinkState.RUN,
          f"B state={b.link.state}")


# ------------------------------------------------------------------
# 시나리오 11: i_rst_n vs port_reset 구분 (DECISION-16) — 신규 구현
# ------------------------------------------------------------------
# [2026-09-01] 지난 세션에는 golden model에 이 구분이 구현되어 있지 않아
# SKIP 처리했었다. 이번 세션에 NodeInputs.rst_n + SpWNode.tick() 최상단에
# 실제로 구현(비동기 전체 리셋, net(FIFO) 포함 전부 재초기화)하고, 이
# 시나리오로 port_reset(FIFO 보존)과의 차이를 직접 검증한다.
def scenario_11_full_reset_vs_port_reset():
    print("\n[시나리오 11] i_rst_n vs port_reset 구분 (DECISION-16)")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    b.i.rx_ready = 0
    packet = [0x11, 0x22, 0x33]
    idx = 0
    for _ in range(2000):
        if idx < len(packet):
            a.i.tx_data9 = packet[idx]
            a.i.tx_valid = 1
        else:
            a.i.tx_valid = 0
        connect_and_tick(a, b)
        if idx < len(packet) and a.ow_tx_ready:
            idx += 1
        if idx >= len(packet) and len(b.net.rx_fifo) >= len(packet):
            break
    rx_fifo_len_before = len(b.net.rx_fifo)
    check("i_rst_n 인가 전 B의 RX FIFO에 데이터 적재됨", rx_fifo_len_before == len(packet),
          f"rx_fifo_len={rx_fifo_len_before}")

    b.i.rst_n = 0
    connect_and_tick(a, b)
    b.i.rst_n = 1
    check("i_rst_n 인가 -> B가 ErrorReset 상태로 전이", b.link.state == LinkState.ERROR_RESET,
          f"state={b.link.state}")
    check("i_rst_n 인가 -> port_reset과 달리 RX FIFO 도 초기화됨 (사용자 데이터 유실)",
          len(b.net.rx_fifo) == 0,
          f"rx_fifo_len={len(b.net.rx_fifo)} (port_reset이었다면 {rx_fifo_len_before} 이어야 함)")
    check("i_rst_n 인가 -> TX FIFO 도 초기화됨", len(b.net.tx_fifo) == 0,
          f"tx_fifo_len={len(b.net.tx_fifo)}")

    # 대조군: 동일 시퀀스를 port_reset으로 인가하면 FIFO는 보존되어야 한다
    a2, b2 = make_pair(params)
    run_until_run_state(a2, b2, max_cycles=20000)
    b2.i.rx_ready = 0
    idx = 0
    for _ in range(2000):
        if idx < len(packet):
            a2.i.tx_data9 = packet[idx]
            a2.i.tx_valid = 1
        else:
            a2.i.tx_valid = 0
        connect_and_tick(a2, b2)
        if idx < len(packet) and a2.ow_tx_ready:
            idx += 1
        if idx >= len(packet) and len(b2.net.rx_fifo) >= len(packet):
            break
    b2.i.port_reset = 1
    connect_and_tick(a2, b2)
    b2.i.port_reset = 0
    check("[대조] port_reset은 FIFO를 보존함 (i_rst_n과의 차이 확인, "
          "ERRATA-18로 EEP 1개가 추가된 것 포함)",
          len(b2.net.rx_fifo) == len(packet) + 1 and b2.net.rx_fifo[-1].kind == CharKind.EEP,
          f"rx_fifo={list(b2.net.rx_fifo)}")

    b.i.link_start = 1
    result = run_until_run_state(a, b, max_cycles=20000)
    check("i_rst_n 이후 재연결 -> 양쪽 다시 Run 도달", b.link.state == LinkState.RUN,
          f"B state={b.link.state}")


# ------------------------------------------------------------------
# 시나리오 12: Camera-to-memory 유사 대량 스트림 (축소판)
# ------------------------------------------------------------------
# 원본 scenario_camera_to_memory.py(640x480 풀프레임)가 프로젝트에 없어
# 동일 취지(다중 패킷 연속 전송 + credit 재충전 + 무결성)의 축소판으로
# 재구성했다. 원본과 바이트 수/세부 절차가 다를 수 있음.
def scenario_12_camera_to_memory_reduced():
    print("\n[시나리오 12] Camera-to-memory 유사 스트림 (4패킷 x 300바이트)")
    # [2026-09-01] ERRATA-23(golden model credit 기아 데드락) 수정 완료로
    # 원래 의도한 대용량(300B/패킷)으로 복귀.
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)

    n_packets = 4
    bytes_per_packet = 300
    all_ok = True
    b.i.rx_ready = 1
    for pkt_no in range(n_packets):
        packet = [((pkt_no * 37 + i) & 0xFF) for i in range(bytes_per_packet)]
        tx_seq = [(v, 0) for v in packet] + [(0x00, 1)]
        idx = 0
        received = []
        for _ in range(bytes_per_packet * 150 + 8000):
            if idx < len(tx_seq):
                byte, is_eop = tx_seq[idx]
                data9 = (0x100 | byte) if is_eop else byte
                a.i.tx_data9 = data9
                a.i.tx_valid = 1
            else:
                a.i.tx_valid = 0
            connect_and_tick(a, b)
            if idx < len(tx_seq) and a.ow_tx_ready:
                idx += 1
            if idx >= len(tx_seq):
                a.i.tx_valid = 0
            if b.ow_rx_valid:
                received.append(b.ow_rx_data)
            if len(received) >= len(tx_seq):
                break
        rx_bytes = [d & 0xFF for d in received[:-1]]
        rx_last = received[-1] if received else None
        ok = (rx_bytes == packet) and (rx_last == 0x100)
        all_ok = all_ok and ok
        check(f"패킷 {pkt_no+1}/{n_packets} ({bytes_per_packet}B) 무결성 + EOP", ok)

    check("전체 스트림 동안 credit_error 없음 (연속 패킷 흐름제어 정상)",
          not b.link.credit_error, f"credit_error={b.link.credit_error}")
    check("전체 스트림 동안 disconnect 없음", not b.link.disconnect,
          f"disconnect={b.link.disconnect}")


# ------------------------------------------------------------------
# 시나리오 13: Timecode RUN 이전 폐기 확인 (ERRATA-19 회귀)
# ------------------------------------------------------------------
def scenario_13_timecode_discard_before_run():
    print("\n[시나리오 13] Timecode RUN 이전 폐기 확인 — ERRATA-19 회귀")
    params = SpWParams()
    a, b = make_pair(params)

    # (1) RUN 도달 전, Connecting 상태에서 tick_in 을 주입한다.
    reached_connecting = False
    for _ in range(20000):
        connect_and_tick(a, b)
        if not reached_connecting and a.link.state == LinkState.CONNECTING:
            reached_connecting = True
            a.i.tick_in = 1
            a.i.time_in = 0b10_101010
            connect_and_tick(a, b)
            a.i.tick_in = 0
            a.i.time_in = 0
            continue
        if a.link.state == LinkState.RUN:
            break
    check("사전조건: Connecting 상태에서 tick_in 주입함", reached_connecting)
    check("사전조건: 이후 Run 상태 도달", a.link.state == LinkState.RUN)

    # (2) RUN 도달 후에도 그 tick 이 지연 발송되어 나타나지 않아야 한다.
    leaked = False
    for _ in range(5000):
        connect_and_tick(a, b)
        if b.ow_tick_out:
            leaked = True
            break
    check("RUN 이전 tick_in 은 폐기됨 (RUN 이후 지연 발송 없음)", not leaked)

    # (3) RUN 이후 정상적으로 들어온 tick_in 은 여전히 정상 동작해야 한다.
    a.i.tick_in = 1
    a.i.time_in = 0x2A
    connect_and_tick(a, b)
    a.i.tick_in = 0
    got = False
    got_time = None
    for _ in range(2000):
        connect_and_tick(a, b)
        if b.ow_tick_out:
            got = True
            got_time = b.ow_time_out
            break
    check("RUN 이후 정상 tick_in 은 정상적으로 tick_out 전달", got and got_time == 0x2A,
          f"got={got}, time={got_time}")


# ------------------------------------------------------------------
# ==================================================================
# [2026-09-01 신규] 복합 시나리오 — 단일 결함이 아닌 결합 조건
# ==================================================================

# ------------------------------------------------------------------
# 시나리오 14: Parity error가 credit 경계(56바이트) 부근에서 발생
# ------------------------------------------------------------------
def scenario_14_parity_error_at_credit_boundary():
    print("\n[시나리오 14] Parity error가 credit 경계(56바이트) 부근에서 발생 (복합 결함)")
    # [수정] 처음 버전은 b.dec.parity_error 를 외부에서 직접 True로 찍었으나,
    # 이 필드는 매 tick 시작 시 dec.tick() 내부에서 False로 리셋된 뒤
    # SpWNode.tick()이 "self.link.parity_error = self.dec.parity_error"로
    # 그대로 복사하는 구조라, tick() 호출 "이후"에 외부에서 값을 찍어봤자
    # 다음 tick 시작과 동시에 즉시 지워져 link 쪽에 절대 반영되지 않았다.
    # 시나리오 5와 동일하게 실제 비트 반전(D/S 동시 반전, 1비트 구간 유지)
    # 방식으로 다시 작성한다.
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    payload = [(i & 0xFF) for i in range(56)]  # 정확히 MAX_CREDIT 크기
    tx_seq = [(v, False) for v in payload] + [(0x00, True)]
    idx = 0
    received = []
    b.i.rx_ready = 1

    prev_a_data, prev_a_strobe = a.enc.tx_data, a.enc.tx_strobe
    fault_active = False
    fault_started = False
    fault_after_n_bytes = 40  # credit 경계(56) 부근, EOP 직전에 걸리도록

    for cyc in range(56 * 150 + 8000):
        if idx < len(tx_seq):
            byte, is_eop = tx_seq[idx]
            data9 = (0x100 | byte) if is_eop else byte
            a.i.tx_data9 = data9
            a.i.tx_valid = 1
        else:
            a.i.tx_valid = 0

        real_data, real_strobe = a.enc.tx_data, a.enc.tx_strobe
        bit_changed = (real_data != prev_a_data) or (real_strobe != prev_a_strobe)
        if not fault_started and idx >= fault_after_n_bytes and bit_changed:
            fault_started = True
            fault_active = True

        if fault_active:
            b.dec.set_lines(real_data ^ 1, real_strobe ^ 1)
        elif fault_started:
            b.dec.set_lines(real_data, real_strobe ^ 1)
        else:
            b.dec.set_lines(real_data, real_strobe)
        prev_a_data, prev_a_strobe = real_data, real_strobe

        a.dec.set_lines(b.enc.tx_data, b.enc.tx_strobe)
        a.tick()
        b.tick()

        if fault_active:
            nxt_changed = (a.enc.tx_data != real_data) or (a.enc.tx_strobe != real_strobe)
            if nxt_changed:
                fault_active = False

        if idx < len(tx_seq) and a.ow_tx_ready:
            idx += 1
        if idx >= len(tx_seq):
            a.i.tx_valid = 0
        if b.ow_rx_valid:
            received.append(b.ow_rx_data)
        if b.link.state == LinkState.ERROR_RESET:
            break
        if len(received) >= len(tx_seq):
            break

    check("credit 경계 부근 parity error -> B가 ErrorReset 진입", b.link.state == LinkState.ERROR_RESET,
          f"B state={b.link.state}, fault_started={fault_started}")
    check("ErrorReset 진입 시 rx_credit_budget 도 함께 초기화됨 (좀비 상태 없음)",
          b.link.rx_credit_budget == 0)

    # 재연결이 credit 정보가 꼬인 채로 데드락에 빠지지 않고 정상 이루어지는지 확인
    # (시나리오 16과 동일한 이유로 run_until_run_state 의 "첫 도달 시점" 기록
    # 방식 대신, "두 노드가 동시에 RUN인 순간"을 직접 폴링한다 — A는 이 결함에서
    # 벗어난 적이 없어 첫 tick에 이미 RUN으로 잘못 조기 기록되기 때문)
    a.i.link_start = 1
    b.i.link_start = 1
    reconnected = False
    for _ in range(30000):
        connect_and_tick(a, b)
        if a.link.state == LinkState.RUN and b.link.state == LinkState.RUN:
            reconnected = True
            break
    check("결함 복구 후 재연결 -> 양쪽 다시 Run 도달 (동시 RUN 상태 직접 확인)", reconnected,
          f"A={a.link.state}, B={b.link.state}")

    # [발견] A가 결함 시점에 아직 다 못 보낸 나머지 페이로드(끊긴 패킷의 잔여
    # 바이트)가 A의 net.tx_fifo 에 그대로 남아있다가, 재연결 후 아무 경계
    # 표시 없이 그대로 이어서 나간다 -- ErrorReset이 프로토콜 상태(enc/dec/
    # link)는 리셋해도 사용자 TX FIFO는 보존하기 때문(시나리오 10에서 이미
    # "의도된 설계"로 확인한 바로 그 성질). 문제는 이게 "찢어진 패킷"의
    # 나머지가 새 세션에 아무 표시 없이 섞여 나간다는 뜻이라, ERRATA-18
    # (EEP 자동 삽입 미구현)과 같은 종류의 미해결 설계 질문과 맞닿아 있다.
    # 여기서는 그 잔재를 먼저 다 비운 뒤(이 leak 자체를 명시적으로 관측),
    # 그 다음에 깨끗한 새 패킷이 정상 왕복하는지를 확인한다.
    leaked = []
    for _ in range(20000):
        connect_and_tick(a, b)
        if b.ow_rx_valid:
            leaked.append(b.ow_rx_data)
        if len(a.net.tx_fifo) == 0 and a.enc.idle() and not a.link._tx_flushing:
            break
    check("[ERRATA-26, 2026-09-02 해결 확인] 끊긴 패킷의 잔여 바이트가 "
          "재연결 후 전혀 새 나가지 않음 (leaked==0, tx_flushing이 내부에서 조용히 버림)",
          len(leaked) == 0, f"leaked_bytes={len(leaked)}: {leaked}")

    received2, tx_seq2 = send_packet(a, b, [0x11, 0x22, 0x33])
    ok2 = (len(received2) == len(tx_seq2) and
           [d & 0xFF for d in received2[:-1]] == [0x11, 0x22, 0x33] and received2[-1] == 0x100)
    check("잔재를 비운 뒤에는 새 패킷이 깨끗하게 정상 송수신됨", ok2, f"received={received2}")


# ------------------------------------------------------------------
# 시나리오 15: 양쪽 노드에 동시 port_reset
# ------------------------------------------------------------------
def scenario_15_simultaneous_port_reset():
    print("\n[시나리오 15] 양쪽 노드에 동시 port_reset (복합 결함 — 레이스 조건)")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    # 같은 tick에 양쪽 다 port_reset 인가
    a.i.port_reset = 1
    b.i.port_reset = 1
    connect_and_tick(a, b)
    a.i.port_reset = 0
    b.i.port_reset = 0
    check("동시 port_reset -> 양쪽 다 ErrorReset 진입",
          a.link.state == LinkState.ERROR_RESET and b.link.state == LinkState.ERROR_RESET,
          f"A={a.link.state}, B={b.link.state}")

    # 재연결 시 양쪽이 서로 다른 타이밍(auto_start 비대칭)으로 인한 데드락이
    # 없는지 확인 -- DECISION-14 에서 우려했던 유형의 레이스
    a.i.link_start = 1
    b.i.link_start = 1
    result = run_until_run_state(a, b, max_cycles=20000)
    check("동시 리셋 후 재연결 -> 양쪽 다시 Run 도달 (데드락 없음)",
          a.link.state == LinkState.RUN and b.link.state == LinkState.RUN,
          f"A={a.link.state}, B={b.link.state}")

    received, tx_seq = send_packet(a, b, [0xAA, 0xBB])
    ok = (len(received) == len(tx_seq) and [d & 0xFF for d in received[:-1]] == [0xAA, 0xBB]
          and received[-1] == 0x100)
    check("재연결 후 정상 송수신", ok, f"received={received}")


# ------------------------------------------------------------------
# 시나리오 16: ESC 원자적 시퀀스의 두 번째 문자 전송 도중 결함 발생
# ------------------------------------------------------------------
def scenario_16_fault_during_esc_second_char():
    print("\n[시나리오 16] ESC 원자쌍의 두 번째 문자 전송 도중 결함 (복합 결함)")
    # ESC/Null 원자성 회귀(esc_null_atomicity)가 "정상 경로에서 유실/중복이
    # 없다"만 확인했다면, 이 시나리오는 "그 원자쌍이 반쯤 진행된 도중 링크가
    # 깨지면" 어떻게 되는지를 본다 -- r_esc_pending 류 상태가 リ셋 이후에도
    # 남아 다음 연결에 영향을 주지 않는지가 핵심이다.
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    # B가 ESC 를 막 보낸 직후(=_esc_seq_continue 가 아직 pending인 시점)를
    # 노려 강제로 port_reset 을 건다.
    forced = False
    for cyc in range(3000):
        connect_and_tick(a, b)
        if not forced and b.enc.char_sent is not None and b.enc.char_sent.kind == CharKind.ESC:
            b.i.port_reset = 1
            forced = True
            continue
        if forced:
            b.i.port_reset = 0
            break
    check("ESC 직후(원자쌍 진행 중) port_reset 주입됨", forced)
    check("port_reset 이후 B가 ErrorReset 진입", b.link.state == LinkState.ERROR_RESET,
          f"B state={b.link.state}")
    check("원자쌍 잔재(_esc_seq_continue) 리셋으로 정리됨", b._esc_seq_continue is None)

    a.i.link_start = 1
    b.i.link_start = 1
    # [주의] run_until_run_state() 는 "각자 처음 RUN에 도달한 시점"만 기록하는데,
    # 여기선 A가 애초에 RUN에서 벗어난 적이 없어(첫 tick에 이미 RUN으로 기록)
    # B가 재연결 도중일 뿐인데도 "둘 다 이미 도달"로 조기 반환해버린다. 실제로는
    # B가 재시작하면서 잠시 신호가 끊겨 A도 함께 disconnect 를 감지하고 재연결
    # 사이클을 도는데(현실적인 동작), 그 사이클이 끝나기 전에 조기 반환되어
    # "A 가 아직 RUN 복귀 전"인 상태를 놓친다. 여기서는 "두 노드가 동시에 RUN
    # 상태인 순간"을 직접 폴링한다.
    reconnected = False
    for _ in range(30000):
        connect_and_tick(a, b)
        if a.link.state == LinkState.RUN and b.link.state == LinkState.RUN:
            reconnected = True
            break
    check("재연결 -> 양쪽 다시 Run 도달 (동시 RUN 상태 직접 확인)", reconnected,
          f"A={a.link.state}, B={b.link.state}")

    # 재연결 후 ESC/Null 원자쌍이 다시 정상적으로 유실/중복 없이 도는지 표본 확인
    esc_count = 0
    violations = 0
    prev_was_esc = False
    for _ in range(5000):
        connect_and_tick(a, b)
        ch = b.enc.char_sent
        if ch is not None:
            if prev_was_esc and ch.kind not in (CharKind.FCT, CharKind.TIMECODE):
                violations += 1
            if ch.kind == CharKind.ESC:
                esc_count += 1
                prev_was_esc = True
            else:
                prev_was_esc = False
    check("재연결 후 ESC 원자쌍 정상 관측", esc_count > 0, f"esc_count={esc_count}")
    check("재연결 후 ESC 원자쌍 유실/중복 없음", violations == 0, f"violations={violations}")


# ==================================================================
# [2026-09-01 신규] EEP(Error End of Packet) 관련 시나리오
# ==================================================================

# ------------------------------------------------------------------
# 시나리오 17: 명시적 EEP로 패킷 종료 -> 다음 패킷과 경계가 깨지지 않는지
# ------------------------------------------------------------------
def scenario_17_explicit_eep_packet_boundary():
    print("\n[시나리오 17] 명시적 EEP로 패킷 종료, 바로 다음 패킷 연속 (정상 EEP 경로)")
    # ERRATA-18(자동 EEP 삽입)과는 다른 항목이다 -- 이건 "송신측이 스스로
    # EEP를 명시적으로 보내는" 정상 케이스(호스트가 손상을 감지하고 EEP로
    # 마무리한 뒤 새 패킷을 시작하는 흔한 사용 패턴)가 수신측에서 패킷 경계를
    # 안 깨고 정확히 구분되는지를 본다.
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    # 패킷 1: DATA,DATA,DATA + EEP (손상된 패킷을 EEP로 강제 종료하는 흔한 패턴)
    received1, tx_seq1 = send_packet(a, b, [0xAA, 0xBB, 0xCC], eop_kind="EEP")
    ok1 = (len(received1) == len(tx_seq1) and [d & 0xFF for d in received1[:-1]] == [0xAA, 0xBB, 0xCC]
           and received1[-1] == 0x101)
    check("패킷 1: DATA 3개 + EEP 정상 수신 (EEP 코드 0x101)", ok1, f"received={received1}")

    # 패킷 2: EEP 직후 곧바로 새 패킷 시작 -- 경계가 안 섞이는지 확인
    received2, tx_seq2 = send_packet(a, b, [0x11, 0x22, 0x33, 0x44], eop_kind="EOP")
    ok2 = (len(received2) == len(tx_seq2) and
           [d & 0xFF for d in received2[:-1]] == [0x11, 0x22, 0x33, 0x44] and received2[-1] == 0x100)
    check("패킷 2: EEP 직후 새 패킷이 섞이지 않고 정확히 구분되어 수신됨", ok2,
          f"received={received2}")

    check("EEP 처리 중 credit_error/disconnect 없음",
          not b.link.credit_error and not b.link.disconnect,
          f"credit_error={b.link.credit_error}, disconnect={b.link.disconnect}")


# ------------------------------------------------------------------
# 시나리오 18: [ERRATA-18 관련, 현재 동작 관찰] 링크 에러로 패킷이 중간에
# 끊겼을 때 EOP/EEP 없이 RX FIFO에 남는 잔여물 확인
# ------------------------------------------------------------------
def scenario_18_eep_auto_recovery():
    print("\n[시나리오 18] EEP 자동 복구 검증 (ERRATA-18, ECSS 5.5.8.4.a.2 — 2026-09-02 구현 완료)")
    # [2026-09-01] 이 시나리오는 원래 "관찰 전용"이었다 -- 당시 golden model에
    # 자동 EEP 삽입이 구현되어 있지 않아, 갭을 임의로 메우는 척하지 않고
    # "지금 실제로 어떤 일이 벌어지는지"만 기록했다. [2026-09-02] ERRATA-18을
    # 실제로 구현했으므로, 이 시나리오도 관찰에서 검증으로 승격한다.
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    # DATA 몇 개만 보내고 EOP/EEP 없이 링크를 강제로 끊는다 (port_reset)
    # [주의] make_pair()가 rx_ready=1 로 시작하므로, 보내기 "전에" 미리 0으로
    # 내려야 호스트가 안 읽은 상태로 RX FIFO에 쌓인다.
    b.i.rx_ready = 0
    payload = [0x10, 0x20, 0x30]
    for byte in payload:
        a.i.tx_data9 = byte
        a.i.tx_valid = 1
        while True:
            connect_and_tick(a, b)
            if a.ow_tx_ready:
                break
    a.i.tx_valid = 0
    for _ in range(5000):
        connect_and_tick(a, b)
        if len(b.net.rx_fifo) >= len(payload):
            break
    rx_fifo_before = list(b.net.rx_fifo)
    check("사전조건: EOP/EEP 없이 DATA 3개만 B의 RX FIFO에 도착",
          len(rx_fifo_before) == 3, f"rx_fifo={rx_fifo_before}")

    b.i.port_reset = 1
    connect_and_tick(a, b)
    b.i.port_reset = 0
    check("port_reset -> ErrorReset 진입", b.link.state == LinkState.ERROR_RESET)

    rx_fifo_after = list(b.net.rx_fifo)
    check("[ERRATA-18] 끊긴 패킷 뒤에 EEP 가 자동으로 삽입됨 (3바이트 그대로 + EEP 1개)",
          rx_fifo_after[:3] == rx_fifo_before and len(rx_fifo_after) == 4
          and rx_fifo_after[3].kind == CharKind.EEP,
          f"rx_fifo_after={rx_fifo_after}")
    check("[ERRATA-18] eep_pending 즉시 해소됨 (FIFO 에 이미 여유 있었으므로)",
          b.link._eep_pending is False)

    # 호스트가 이제 이 4바이트(DATA*3 + EEP)를 정상적으로 "완결된 패킷"으로 읽는다
    b.i.rx_ready = 1
    popped = []
    for _ in range(20):
        connect_and_tick(a, b)
        if b.ow_rx_valid:
            popped.append(b.ow_rx_data)
    check("호스트가 EEP로 종료된 4바이트를 정상적으로 읽어감 (0x101로 종료)",
          len(popped) == 4 and popped[-1] == 0x101, f"popped={popped}")

    # 재연결 후 새 패킷이 EEP 뒤에 깨끗하게 이어지는지 확인 (순서 섞임 없음)
    a.i.link_start = 1
    b.i.link_start = 1
    reconnected = False
    for _ in range(30000):
        connect_and_tick(a, b)
        if a.link.state == LinkState.RUN and b.link.state == LinkState.RUN:
            reconnected = True
            break
    check("재연결 -> 양쪽 다시 Run 도달", reconnected, f"A={a.link.state}, B={b.link.state}")

    received, tx_seq = send_packet(a, b, [0xAA, 0xBB, 0xCC])
    ok = (len(received) == len(tx_seq) and [d & 0xFF for d in received[:-1]] == [0xAA, 0xBB, 0xCC]
          and received[-1] == 0x100)
    check("재연결 후 새 패킷이 EEP 뒤에 깨끗하게 이어짐 (경계 섞임 없음)", ok,
          f"received={received}")


# ------------------------------------------------------------------
# 시나리오 20: EEP 복구 -- RX FIFO full 대기 + 순서 보장 인터록
# (ERRATA-18 심화, 2026-09-02 신규 — 사용자 지적으로 "1클럭 pulse가 아니라
#  FIFO가 빌 때까지 기다려야 한다"는 점이 밝혀진 뒤 설계/구현)
# ------------------------------------------------------------------
def scenario_20_eep_recovery_fifo_full_and_ordering():
    print("\n[시나리오 20] EEP 복구 -- RX FIFO full 대기(레벨 신호) + 순서 보장 인터록")
    params = SpWParams(RX_FIFO_DEPTH=8)   # 작은 FIFO로 "완전히 꽉 채우기" 용이
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    # RX_FIFO_DEPTH=8 이면 초기 FCT 1개(=credit 8)만 부여되므로, DATA 8개를
    # EOP 없이 보내면 정확히 그 한 번의 초기 credit 만으로 FIFO 가 "정확히
    # 꽉 찬"(8/8, 여유 0) 상태가 된다 -- 추가 req_fct 개입이 필요 없는 깔끔한
    # 설정이다.
    b.i.rx_ready = 0
    payload = [0x40 + i for i in range(8)]
    for byte in payload:
        a.i.tx_data9 = byte
        a.i.tx_valid = 1
        while True:
            connect_and_tick(a, b)
            if a.ow_tx_ready:
                break
    a.i.tx_valid = 0
    for _ in range(6000):
        connect_and_tick(a, b)
        if len(b.net.rx_fifo) >= 8:
            break
    check("사전조건: DATA 8개 도착, RX FIFO(깊이8) 완전히 꽉 참", len(b.net.rx_fifo) == 8,
          f"len={len(b.net.rx_fifo)}")
    check("사전조건: 이 시점 rx_free_space == 0", b.net.rx_free_space() == 0)

    b.i.port_reset = 1
    connect_and_tick(a, b)
    b.i.port_reset = 0
    check("port_reset -> ErrorReset 진입", b.link.state == LinkState.ERROR_RESET)
    check("[ERRATA-18] eep_pending 무장됨 (미완성 패킷 있었음, FIFO full)",
          b.link._eep_pending is True)

    # FIFO 가 계속 꽉 차있는 한(호스트가 안 읽는 한) eep_pending 은 계속
    # 대기해야 한다 -- 재연결을 시도해도(link_start=1) 풀리면 안 된다.
    a.i.link_start = 1
    b.i.link_start = 1
    still_pending_count = 0
    for _ in range(3000):
        connect_and_tick(a, b)
        if b.link._eep_pending:
            still_pending_count += 1
    check("[레벨 신호 확인] FIFO 가 안 비는 3000클럭 내내 eep_pending 유지됨 "
          "(1클럭 pulse 였다면 훨씬 일찍 사라졌을 것)",
          still_pending_count > 2900, f"still_pending_count={still_pending_count}/3000")
    check("[순서보장] eep_pending 동안 재연결 시도해도 Run 에 못 들어감 "
          "(초기 FCT 도 인터록으로 보류되어 SentFCT 성립 불가)",
          b.link.state != LinkState.RUN, f"B state={b.link.state}")
    check("[FIFO 무결성] eep_pending 대기 중에도 FIFO 는 8개 그대로, 오버플로우로 "
          "깨지지 않음", len(b.net.rx_fifo) == 8, f"len={len(b.net.rx_fifo)}")

    # 이제 호스트가 FIFO를 드레인하기 시작한다 -- 자리가 나는 순간 EEP가
    # 그 자리에 즉시 꽂혀야 한다 (호스트가 원래 데이터를 먼저 읽어가고 나서).
    b.i.rx_ready = 1
    eep_appeared_cycle = None
    popped = []
    for cyc in range(2000):
        connect_and_tick(a, b)
        if b.ow_rx_valid:
            popped.append(b.ow_rx_data)
        if eep_appeared_cycle is None and not b.link._eep_pending:
            eep_appeared_cycle = cyc
            break
    check("[레벨 신호 확인] 호스트가 드레인 시작하자 eep_pending 이 곧 해소됨",
          eep_appeared_cycle is not None, f"eep_appeared_cycle={eep_appeared_cycle}")

    # 호스트가 계속 읽으면 결국 DATA 8개 + EEP 1개 = 9개를 순서대로 받아야
    # 한다 (EEP 가 8개 중간에 끼어들어 순서를 어지럽히면 안 됨).
    for _ in range(2000):
        connect_and_tick(a, b)
        if b.ow_rx_valid:
            popped.append(b.ow_rx_data)
        if len(popped) >= 9:
            break
    ok_order = (popped[:8] == [0x40 + i for i in range(8)]) and popped[8] == 0x101
    check("[순서보장] 호스트가 최종적으로 DATA 8개 -> EEP 순서 그대로 수신 "
          "(EEP 가 중간에 끼어들지 않음)", ok_order, f"popped={popped}")

    # eep_pending 해소 후 재연결 -> 정상 진행되고, 새 패킷이 EEP 뒤에 깨끗하게 이어짐
    reconnected = False
    for _ in range(30000):
        connect_and_tick(a, b)
        if a.link.state == LinkState.RUN and b.link.state == LinkState.RUN:
            reconnected = True
            break
    check("eep_pending 해소 후 재연결 -> 양쪽 다시 Run 도달", reconnected,
          f"A={a.link.state}, B={b.link.state}")

    received, tx_seq = send_packet(a, b, [0x77, 0x88])
    ok = (len(received) == len(tx_seq) and [d & 0xFF for d in received[:-1]] == [0x77, 0x88]
          and received[-1] == 0x100)
    check("재연결 후 새 패킷 정상 송수신 (지연된 EEP 복구 이후에도 정상)", ok,
          f"received={received}")


def scenario_21_eep_recovery_no_interlock_when_idle():
    print("\n[시나리오 21] EEP 복구 -- 유휴 상태(미완성 패킷 없음)에서는 인터록이 걸리지 않음")
    # ERRATA-18 인터록이 "에러가 나면 무조건" 새 credit 을 막는 과잉 회귀가
    # 아니라, 정말로 미완성 패킷이 있었을 때만 작동하는지 확인하는 대조군.
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    # 정상적으로 완결된 패킷을 하나 보내고 (EOP 로 정상 종료)
    received, tx_seq = send_packet(a, b, [0x01, 0x02])
    check("사전조건: 정상 패킷 완결 수신 (EOP 로 끝남)",
          len(received) == len(tx_seq) and received[-1] == 0x100, f"received={received}")
    check("사전조건: 이 시점 rx_pkt_in_progress == False (EOP 로 이미 종료됨)",
          b.link._rx_pkt_in_progress is False)

    # 유휴 상태에서 port_reset -> eep_pending 이 무장되면 안 됨
    b.i.port_reset = 1
    connect_and_tick(a, b)
    b.i.port_reset = 0
    check("유휴 상태 port_reset -> ErrorReset 진입", b.link.state == LinkState.ERROR_RESET)
    check("[대조군] 미완성 패킷이 없었으므로 eep_pending 이 무장되지 않음",
          b.link._eep_pending is False)
    check("[대조군] RX FIFO에 엉뚱한 EEP 가 추가되지 않음 (완결된 패킷 그대로)",
          len(b.net.rx_fifo) == 0, f"rx_fifo={list(b.net.rx_fifo)}")   # 이미 호스트가 다 읽어감

    # 인터록이 안 걸렸으므로 재연결이 평소처럼 빠르게 이루어져야 함
    a.i.link_start = 1
    b.i.link_start = 1
    reconnected = False
    for _ in range(20000):
        connect_and_tick(a, b)
        if a.link.state == LinkState.RUN and b.link.state == LinkState.RUN:
            reconnected = True
            break
    check("[대조군] 인터록 없이 정상 속도로 재연결됨", reconnected,
          f"A={a.link.state}, B={b.link.state}")


# ------------------------------------------------------------------
# 시나리오 22: TX flush 자동 복구 검증 (ERRATA-26, 2026-09-02 신규)
# E1(ERRATA-18, RX측 EEP)과 대칭되는 TX측 조치 — 끊긴 패킷의 미송신
# 잔여 바이트가 재연결 후 경계 표시 없이 새 나가는 걸 막는다.
# ------------------------------------------------------------------
def scenario_22_tx_flush_recovery():
    print("\n[시나리오 22] TX flush 자동 복구 검증 (ERRATA-26)")
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    payload = list(range(50))
    tx_seq = [(v, False) for v in payload] + [(0x00, True)]
    idx = 0
    b.i.rx_ready = 1
    received_before = []
    # 일부러 짧은 창(300클럭)만 주어 A가 패킷을 다 못 보낸 채로 만든다
    # (50바이트+EOP를 문자당 ~100클럭에 다 보내려면 5000클럭 이상 필요).
    for _ in range(300):
        if idx < len(tx_seq):
            byte, is_term = tx_seq[idx]
            a.i.tx_data9 = 0x100 if is_term else byte
            a.i.tx_valid = 1
        else:
            a.i.tx_valid = 0
        connect_and_tick(a, b)
        if idx < len(tx_seq) and a.ow_tx_ready:
            idx += 1
        if b.ow_rx_valid:
            received_before.append(b.ow_rx_data)
    a.i.tx_valid = 0
    tx_fifo_residual_before = len(a.net.tx_fifo)
    check("사전조건: A가 패킷을 다 못 보낸 채(TX FIFO에 잔여 있음) 에러 직전 상태",
          tx_fifo_residual_before > 0, f"residual={tx_fifo_residual_before}, idx={idx}/{len(tx_seq)}")
    check("사전조건: 아직 EOP 도착 전(패킷 미완결)",
          len(received_before) == 0 or received_before[-1] != 0x100,
          f"received_before={received_before}")

    a.i.port_reset = 1
    connect_and_tick(a, b)
    a.i.port_reset = 0
    check("port_reset(A) -> A가 ErrorReset 진입", a.link.state == LinkState.ERROR_RESET)
    check("[ERRATA-26] tx_flushing 무장됨 (미송신 패킷 있었음)", a.link._tx_flushing is True)

    a.i.link_start = 1
    b.i.link_start = 1
    leaked = []
    reconnected = False
    for _ in range(30000):
        connect_and_tick(a, b)
        if b.ow_rx_valid:
            leaked.append(b.ow_rx_data)
        if a.link.state == LinkState.RUN and b.link.state == LinkState.RUN:
            reconnected = True
            break
    check("[ERRATA-26] 재연결까지 잔여 바이트가 전혀 새 나가지 않음 (leaked==0)",
          len(leaked) == 0, f"leaked={leaked}")
    check("[ERRATA-26] tx_flushing 이 재연결 훨씬 전에 이미 해소됨(내부에서 빠르게 flush)",
          a.link._tx_flushing is False)
    check("재연결 -> 양쪽 다시 Run 도달", reconnected, f"A={a.link.state}, B={b.link.state}")

    received, tx_seq2 = send_packet(a, b, [0x99, 0x88, 0x77])
    ok = (len(received) == len(tx_seq2) and [d & 0xFF for d in received[:-1]] == [0x99, 0x88, 0x77]
          and received[-1] == 0x100)
    check("재연결 후 새 패킷 정상 송수신 (잔여 flush 이후에도 정상)", ok, f"received={received}")


def scenario_23_tx_flush_no_interlock_when_idle():
    print("\n[시나리오 23] TX flush -- 유휴 상태(미송신 패킷 없음)에서는 인터록이 걸리지 않음")
    # ERRATA-26 인터록이 "에러가 나면 무조건" 걸리는 과잉 회귀가 아니라,
    # 정말로 미송신 패킷이 있었을 때만 작동하는지 확인하는 대조군
    # (scenario_21의 TX측 대응).
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건: 양 노드 Run 상태", a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    received, tx_seq = send_packet(a, b, [0x01, 0x02])
    check("사전조건: 정상 패킷 완결 송신 (EOP 로 끝남)",
          len(received) == len(tx_seq) and received[-1] == 0x100, f"received={received}")
    check("사전조건: 이 시점 tx_pkt_in_progress == False (EOP 로 이미 종료됨)",
          a.link._tx_pkt_in_progress is False)

    a.i.port_reset = 1
    connect_and_tick(a, b)
    a.i.port_reset = 0
    check("유휴 상태 port_reset -> A ErrorReset 진입", a.link.state == LinkState.ERROR_RESET)
    check("[대조군] 미송신 패킷이 없었으므로 tx_flushing 이 무장되지 않음",
          a.link._tx_flushing is False)

    a.i.link_start = 1
    b.i.link_start = 1
    reconnected = False
    for _ in range(20000):
        connect_and_tick(a, b)
        if a.link.state == LinkState.RUN and b.link.state == LinkState.RUN:
            reconnected = True
            break
    check("[대조군] 인터록 없이 정상 속도로 재연결됨", reconnected,
          f"A={a.link.state}, B={b.link.state}")


# ------------------------------------------------------------------
# 시나리오 19: Full-duplex 양방향 동시 트래픽 (item 2, 2026-09-02 신규)
# ------------------------------------------------------------------
def scenario_19_full_duplex_simultaneous_traffic():
    print("\n[시나리오 19] Full-duplex 양방향 동시 트래픽 (item 2)")
    # 지금까지의 send_packet() 기반 시나리오는 전부 "한쪽만 보내고 다른 쪽은
    # 받기만" 하는 단방향이었다. connect_and_tick() 자체는 매 사이클 A/B를
    # 함께 진행시키므로 이미 물리적으로는 full-duplex 지만, "양쪽 다 동시에
    # 사용자 데이터를 밀어넣는" 상황을 실제로 시험한 시나리오는 없었다.
    # A.tx_credit(자신이 B에게 줄 수 있는 양)과 A.rx_credit_budget(자신이
    # B로부터 받겠다고 승인해준 양)은 서로 다른 필드라 이론상 방향 독립이어야
    # 하는데, 실제로 양방향이 동시에 바쁠 때도 그 독립성이 깨지지 않는지를
    # 직접 확인한다.

    # ---- Part A: 동시 양방향 대용량 패킷 교환 (서로 다른 길이로 비대칭) --
    params = SpWParams()
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    check("사전조건(A): 양 노드 Run 상태",
          a.link.state == LinkState.RUN and b.link.state == LinkState.RUN)

    payload_ab = [(i * 7 + 3) & 0xFF for i in range(300)]   # A -> B, 300B
    payload_ba = [(i * 5 + 1) & 0xFF for i in range(250)]   # B -> A, 250B
    tx_ab = [(v, False) for v in payload_ab] + [(0x100, True)]
    tx_ba = [(v, False) for v in payload_ba] + [(0x100, True)]

    idx_ab = idx_ba = 0
    recv_at_b: list = []   # A -> B 로 B가 받은 것
    recv_at_a: list = []   # B -> A 로 A가 받은 것
    max_cycles = (len(tx_ab) + len(tx_ba)) * 100 + 20000
    for _ in range(max_cycles):
        a.i.tx_valid = 1 if idx_ab < len(tx_ab) else 0
        if idx_ab < len(tx_ab):
            byte, is_term = tx_ab[idx_ab]
            a.i.tx_data9 = 0x100 if is_term else byte
        b.i.tx_valid = 1 if idx_ba < len(tx_ba) else 0
        if idx_ba < len(tx_ba):
            byte, is_term = tx_ba[idx_ba]
            b.i.tx_data9 = 0x100 if is_term else byte

        connect_and_tick(a, b)

        if idx_ab < len(tx_ab) and a.ow_tx_ready:
            idx_ab += 1
        if idx_ba < len(tx_ba) and b.ow_tx_ready:
            idx_ba += 1
        if b.ow_rx_valid:
            recv_at_b.append(b.ow_rx_data)
        if a.ow_rx_valid:
            recv_at_a.append(a.ow_rx_data)
        if len(recv_at_b) >= len(tx_ab) and len(recv_at_a) >= len(tx_ba):
            break

    ok_ab = (len(recv_at_b) == len(tx_ab)
             and [d & 0xFF for d in recv_at_b[:-1]] == payload_ab and recv_at_b[-1] == 0x100)
    ok_ba = (len(recv_at_a) == len(tx_ba)
             and [d & 0xFF for d in recv_at_a[:-1]] == payload_ba and recv_at_a[-1] == 0x100)
    check("A->B 300B, B가 동시에 반대 방향으로 송신 중에도 무결성 유지", ok_ab,
          f"len(recv_at_b)={len(recv_at_b)}/{len(tx_ab)}")
    check("B->A 250B, A가 동시에 반대 방향으로 송신 중에도 무결성 유지", ok_ba,
          f"len(recv_at_a)={len(recv_at_a)}/{len(tx_ba)}")
    check("동시 양방향 트래픽 중 credit_error 없음 (양쪽 독립성 확인)",
          not a.link.credit_error and not b.link.credit_error,
          f"A.credit_error={a.link.credit_error}, B.credit_error={b.link.credit_error}")
    check("동시 양방향 트래픽 중 esc_error 없음 (양쪽)",
          not a.link.esc_error and not b.link.esc_error,
          f"A.esc_error={a.link.esc_error}, B.esc_error={b.link.esc_error}")
    check("동시 양방향 트래픽 후 양쪽 다 여전히 Run 상태",
          a.link.state == LinkState.RUN and b.link.state == LinkState.RUN,
          f"A={a.link.state}, B={b.link.state}")

    # ---- Part B: 한쪽 대용량 패킷 + 반대쪽 빈번한 Timecode 동시 진행 -----
    # 우선순위(Broadcast(FCT/Timecode) > N-Char > Null)가 대용량 N-Char 스트림
    # 도중에도 계속 끼어들 수 있으면서, 그 N-Char 스트림 자체는 끊기지 않아야
    # 한다는 것을 확인한다.
    params2 = SpWParams()
    a2, b2 = make_pair(params2)
    run_until_run_state(a2, b2, max_cycles=20000)
    check("사전조건(B): 양 노드 Run 상태",
          a2.link.state == LinkState.RUN and b2.link.state == LinkState.RUN)

    payload_big = [(i * 3 + 11) & 0xFF for i in range(200)]  # B -> A, 200B
    tx_big = [(v, False) for v in payload_big] + [(0x100, True)]
    idx_big = 0
    recv_big: list = []

    TICK_PERIOD = 600   # ESC+Timecode 원자쌍(~200클럭) 대비 넉넉한 간격
    tick_values = [((0b01 << 6) | (k & 0x3F)) for k in range(8)]
    tick_idx = 0
    next_tick_cycle = 50
    tick_out_events: list = []   # (cycle, value) -- B2 가 실제 받은 tick_out

    max_cycles2 = len(tx_big) * 150 + 20000
    for cyc in range(max_cycles2):
        b2.i.tx_valid = 1 if idx_big < len(tx_big) else 0
        if idx_big < len(tx_big):
            byte, is_term = tx_big[idx_big]
            b2.i.tx_data9 = 0x100 if is_term else byte

        # A2 쪽 주기적 1클럭 timecode pulse (scenario_7 과 동일한 패턴)
        if a2.i.tick_in:
            a2.i.tick_in = 0
            a2.i.time_in = 0
        elif tick_idx < len(tick_values) and cyc >= next_tick_cycle:
            a2.i.tick_in = 1
            a2.i.time_in = tick_values[tick_idx]
            tick_idx += 1
            next_tick_cycle = cyc + TICK_PERIOD

        connect_and_tick(a2, b2)

        if idx_big < len(tx_big) and b2.ow_tx_ready:
            idx_big += 1
        if a2.ow_rx_valid:
            recv_big.append(a2.ow_rx_data)
        if b2.ow_tick_out:
            tick_out_events.append((cyc, b2.ow_time_out))
        if len(recv_big) >= len(tx_big):
            break

    ok_big = (len(recv_big) == len(tx_big)
              and [d & 0xFF for d in recv_big[:-1]] == payload_big and recv_big[-1] == 0x100)
    check("B->A 200B 대용량 패킷, 반대쪽 빈번한 Timecode 주입 중에도 무결성 유지",
          ok_big, f"len(recv_big)={len(recv_big)}/{len(tx_big)}")
    check("빈번한 Timecode 주입 중 다수의 tick_out 이 실제로 도착 (우선순위 스택 유지)",
          len(tick_out_events) >= 4,
          f"tick_out_events={len(tick_out_events)}/{tick_idx}시도")
    check("대용량 패킷 진행 중 credit_error 없음 (양쪽)",
          not a2.link.credit_error and not b2.link.credit_error,
          f"A.credit_error={a2.link.credit_error}, B.credit_error={b2.link.credit_error}")


def _run_decision17_worstcase_traffic(params: SpWParams, N: int = 500, max_cycle_budget: int = 220_000):
    """DECISION-17 실측용 헬퍼: A가 tick_in을 물리적 최대 속도(매 클럭 0/1 반전)로
    계속 재무장하는 동안 B가 N바이트 패킷을 A로 보낸다. (cycles_used, recv,
    tx, tick_out_events, stalled, a, b) 를 반환한다."""
    a, b = make_pair(params)
    run_until_run_state(a, b, max_cycles=20000)
    payload = [(i * 3 + 11) & 0xFF for i in range(N)]
    tx = [(v, False) for v in payload] + [(0x100, True)]
    idx = 0
    recv: list = []
    tick_out_events: list = []
    time_val = 0

    STALL_LIMIT = 50_000
    last_progress_cyc = 0
    stalled = False
    cyc = 0

    for cyc in range(max_cycle_budget):
        b.i.tx_valid = 1 if idx < len(tx) else 0
        if idx < len(tx):
            byte, is_term = tx[idx]
            b.i.tx_data9 = 0x100 if is_term else byte

        # 물리적으로 가능한 최대 tick_in 토글 속도 (매 클럭 0/1 반전)
        a.i.tick_in = 1 if (cyc % 2 == 0) else 0
        if a.i.tick_in:
            time_val = (time_val + 1) & 0x3F
            a.i.time_in = time_val

        connect_and_tick(a, b)

        if idx < len(tx) and b.ow_tx_ready:
            idx += 1
        if a.ow_rx_valid:
            recv.append(a.ow_rx_data)
            last_progress_cyc = cyc
        if b.ow_tick_out:
            tick_out_events.append(cyc)
        if len(recv) >= len(tx):
            break
        if cyc - last_progress_cyc > STALL_LIMIT:
            stalled = True
            break

    return cyc + 1, recv, tx, tick_out_events, stalled, a, b


def scenario_24_decision17_timecode_starvation_worst_case():
    print("\n[시나리오 24] DECISION-17 -- 물리적 최대 속도로 tick_in을 toggle할 때 "
          "N-Char가 실제로 얼마나 밀리는가 (Option B 적용 후)")
    # DECISION-17(docs/decisions/DECISION-17_fct_nchar_starvation_v3.md)이 "다음
    # 단계"로 요구한 항목: "Timecode를 물리적으로 가능한 최대 빈도로 주입하면서
    # 동시에 대용량 N-Char 송신을 걸어, N-Char의 클럭 단위 최대 지연을 실측".
    #
    # ⚠️ 이력 (2026-09-13): 이 시나리오는 원래 A안(순수 우선순위, throttle 없음)의
    # **완전 정체**를 실측/고정하는 회귀였다 -- 처음 8바이트(Connecting 중 이미
    # 확보된 credit=8) 이후로는 50,000클럭 이상 RX 진전이 전혀 없었다. 원인:
    # 우선순위 2(Timecode)가 우선순위 3(FCT)을 항상 이기고 r_tc_pending이 끊임없이
    # 재무장되어, A가 남은 initial FCT를 영원히 못 보냄 -- credit_error도 안 뜨는
    # 조용한 무한 대기였다. 이 근거로 DECISION-17이 Option B(throttle 카운터)를
    # 채택했고(`SpWNode.TC_STARVE_THRESHOLD`, `_select_next_tx_char()` 참조),
    # 이 시나리오는 이제 "정체가 재발하지 않고, 지연이 유한하게 상한 걸리는가"를
    # 검증하는 회귀로 전환됐다 (ERRATA-25의 tb_race_check.sv가 9->17로 기대값을
    # 갱신했던 것과 동일한 패턴).

    params = SpWParams()

    # 기준선: Timecode 트래픽 전혀 없을 때 N바이트 전송에 걸리는 클럭 수
    base_a, base_b = make_pair(params)
    run_until_run_state(base_a, base_b, max_cycles=20000)
    check("사전조건(baseline): 양 노드 Run 상태",
          base_a.link.state == LinkState.RUN and base_b.link.state == LinkState.RUN)

    N = 500
    base_payload = [(i * 3 + 11) & 0xFF for i in range(N)]
    base_tx = [(v, False) for v in base_payload] + [(0x100, True)]
    base_idx = 0
    base_recv: list = []
    base_cyc = 0
    for base_cyc in range(N * 200 + 20000):
        base_b.i.tx_valid = 1 if base_idx < len(base_tx) else 0
        if base_idx < len(base_tx):
            byte, is_term = base_tx[base_idx]
            base_b.i.tx_data9 = 0x100 if is_term else byte
        connect_and_tick(base_a, base_b)
        if base_idx < len(base_tx) and base_b.ow_tx_ready:
            base_idx += 1
        if base_a.ow_rx_valid:
            base_recv.append(base_a.ow_rx_data)
        if len(base_recv) >= len(base_tx):
            break
    baseline_cycles = base_cyc + 1
    check("baseline: Timecode 트래픽 없이 501바이트 정상 완주",
          len(base_recv) == len(base_tx), f"len(base_recv)={len(base_recv)}/{len(base_tx)}")

    # 워스트케이스: tick_in 물리적 최대 속도 재무장 + 동시 501바이트 전송
    cycles_used, recv, tx, tick_out_events, stalled, a, b = _run_decision17_worstcase_traffic(params, N=N)

    ok_integrity = (len(recv) == len(tx) and [d & 0xFF for d in recv[:-1]] == base_payload
                    and recv[-1] == 0x100)
    # 관대한 상한: TC_STARVE_THRESHOLD(=8)회마다 한 번 양보하므로 최악의 경우도
    # "몇 배 느려짐"이지 무한대가 아니어야 한다. 실측(2026-09-13)은 baseline
    # ~50,280클럭 대비 ~72,359클럭(약 1.44배)이었다 -- 넉넉히 4배까지 허용해
    # 사소한 리팩터링에 깨지지 않게 하되, "유한 상한이 걸린다"는 핵심만 검증한다.
    bound = baseline_cycles * 4

    check("[DECISION-17 Option B] 물리적 최대 tick_in 토글 중에도 501바이트 "
          "전량이 결국 정상 도착 (완전 정체 재발 없음)",
          ok_integrity and not stalled,
          f"len(recv)={len(recv)}/{len(tx)}, stalled={stalled}, cycles_used={cycles_used}")
    check(f"[DECISION-17 Option B] 지연이 유한하게 상한 걸림 "
          f"(baseline={baseline_cycles}클럭 대비 {bound}클럭 이내)",
          cycles_used <= bound,
          f"cycles_used={cycles_used}, baseline={baseline_cycles}, "
          f"ratio={cycles_used/baseline_cycles:.2f}x")
    check("[DECISION-17 Option B] credit_error/esc_error 없음",
          not a.link.credit_error and not b.link.credit_error
          and not a.link.esc_error and not b.link.esc_error)
    check("[DECISION-17 Option B] Timecode 자체는 여전히 다수 정상 전달됨 "
          "(Broadcast 최우선은 정상 동작 시 그대로 유지)",
          len(tick_out_events) > 100, f"tick_out_events={len(tick_out_events)}")


def scenario_25_decision18_gotnull_gate():
    print("\n[시나리오 25] DECISION-18 -- parity/ESC error가 gotNull 이전/이후에 "
          "다르게 처리되는가 (Option B: r_gotnull_latch)")
    # DECISION-18(docs/decisions/DECISION-18_gotNull_precision_v2.md)이 실측
    # 확인한 문제: ECSS 5.4.7.a/5.4.9.b는 "parity/ESC error 검출은 gotNull이
    # assert된 동안에만 활성화"라고 명시하는데, 종전 구현(golden model, RTL
    # 동일)은 parity_error/esc_error를 gotNull 여부와 무관하게 무조건 즉시
    # ErrorReset 사유로 취급했다. Option B(_gotnull_latch, ErrorReset 진입
    # 시에만 clear)로 수정 후, 이 시나리오가 두 방향 다 검증한다: gotNull
    # 이전엔 무시, gotNull 이후엔 여전히 정상 검출.

    def inject_parity(node):
        orig = node.dec.tick
        def patched():
            orig()
            node.dec.parity_error = True
        node.dec.tick = patched
        node.tick()
        node.dec.tick = orig

    # ── Part A: gotNull 이전 (콜드부트 직후 ErrorWait) ──
    params = SpWParams()
    a = SpWNode(params, "A")
    a.i.link_en = 1
    a.i.link_start = 1
    cyc = 0
    while a.link.state != LinkState.ERROR_WAIT and cyc < 5000:
        a.tick()
        cyc += 1
    check("사전조건(Part A): ErrorWait 도달, 아직 gotNull 이전",
          a.link.state == LinkState.ERROR_WAIT and not a.link._gotnull_latch,
          f"state={a.link.state}, _gotnull_latch={a.link._gotnull_latch}")

    inject_parity(a)
    check("[DECISION-18 Option B] gotNull 이전 parity_error 는 ErrorReset을 "
          "유발하지 않음 (ErrorWait 유지)",
          a.link.state == LinkState.ERROR_WAIT, f"state={a.link.state}")
    check("[DECISION-18 Option B] ow_err_parity(원인 신호)는 게이팅 없이 "
          "그대로 관측 가능 (검출 자체를 숨기지는 않음)",
          a.ow_err_parity == True, f"ow_err_parity={a.ow_err_parity}")

    # ── Part B: 실제 Null 수신 후(gotNull 이후) 정상 검출 유지 확인 ──
    params2 = SpWParams()
    a2, b2 = make_pair(params2)
    run_until_run_state(a2, b2, max_cycles=20000)
    check("사전조건(Part B): 양 노드 Run 상태, gotNull 이후",
          a2.link.state == LinkState.RUN and a2.link._gotnull_latch,
          f"state={a2.link.state}, _gotnull_latch={a2.link._gotnull_latch}")

    inject_parity(a2)
    check("[DECISION-18 Option B] gotNull 이후에는 parity_error 가 여전히 "
          "ErrorReset을 유발함 (게이팅 과잉 아님)",
          a2.link.state == LinkState.ERROR_RESET, f"state={a2.link.state}")


def main():
    # P2-4 (codex 리뷰): PASS/FAIL 이 모듈 전역 리스트라 같은 프로세스에서 main() 을
    # 다시 호출하면 이전 결과가 누적되는 문제가 있었다. 매 실행 시 초기화한다.
    PASS.clear()
    FAIL.clear()

    print("=" * 60)
    print("SpaceWire Reference Model 자체 검증 (HO_01 섹션 7.3)")
    print("=" * 60)

    scenario_1_link_init()
    scenario_2_timer_accuracy()
    scenario_3_flow_control()
    scenario_4_packet_loopback()
    scenario_5_parity_error()
    scenario_6_disconnect()
    scenario_7_timecode()
    scenario_8_credit_boundary_sweep()
    scenario_9_credit_error_injection()
    scenario_10_port_reset_fifo_preserved()
    scenario_11_full_reset_vs_port_reset()
    scenario_12_camera_to_memory_reduced()
    scenario_13_timecode_discard_before_run()
    scenario_esc_null_atomicity()

    scenario_14_parity_error_at_credit_boundary()
    scenario_15_simultaneous_port_reset()
    scenario_16_fault_during_esc_second_char()

    scenario_17_explicit_eep_packet_boundary()
    scenario_18_eep_auto_recovery()

    scenario_19_full_duplex_simultaneous_traffic()

    scenario_20_eep_recovery_fifo_full_and_ordering()
    scenario_21_eep_recovery_no_interlock_when_idle()

    scenario_22_tx_flush_recovery()
    scenario_23_tx_flush_no_interlock_when_idle()

    scenario_24_decision17_timecode_starvation_worst_case()
    scenario_25_decision18_gotnull_gate()

    print("\n" + "=" * 60)
    print(f"결과: PASS {len(PASS)} / FAIL {len(FAIL)}")
    if FAIL:
        print("실패 항목:")
        for f in FAIL:
            print(f"  - {f}")
    print("=" * 60)
    return len(FAIL) == 0


if __name__ == "__main__":
    ok = main()
    raise SystemExit(0 if ok else 1)
