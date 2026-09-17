"""
spw_ref_model.py — SpaceWire Reference Model (HO_01 세션 산출물)

[v2, 2026-09-02] ERRATA-18(RX측 EEP 자동 복구, ECSS 5.5.8.4.a.2)과
ERRATA-26(TX측 잔여 바이트 flush) 신규 구현 반영:
  - SpWLink: _rx_pkt_in_progress/_eep_pending, _tx_pkt_in_progress/
    _tx_flushing 4개 플래그 신설. 전자는 RUN 중 진행 중이던 수신 패킷이
    EOP/EEP 없이 끊기면 RX FIFO에 EEP를 자동 삽입(FIFO가 꽉 찼으면 빌
    때까지 레벨 신호로 계속 대기, credit 신규 부여도 그동안 인터록으로
    차단). 후자는 진행 중이던 송신 패킷의 미송신 잔여가 재연결 후 경계
    없이 새 나가는 걸 막는다(에러 시점에 이미 큐에 있던 것만 다음
    EOP/EEP까지 pop-and-discard, FIFO 바닥나면 더 기다리지 않고 종료 —
    초안의 "무한 대기" 설계는 다음 패킷까지 삼켜버리는 회귀가 있어 폐기).
  - `_enter(ERROR_RESET)`에서 두 쌍 모두 승계 처리, `i_rst_n`(전체 리셋)
    경로에서는 대응 pending/flushing 플래그도 함께 클리어.
  - 상세 근거: `Operation_Errata_v7.md` ERRATA-18/ERRATA-26,
    `spw_ref_model_test_v5.py` 시나리오 18/20/21(RX)·22/23(TX).

기준 표준: ECSS-E-ST-50-12C Rev.1 (15 May 2019)
목적:      RTL 구현 전 표준 동작을 Python 으로 완전히 구현하여
           표준 해석 오류를 사전에 제거하고, RTL 검증 Scoreboard 의
           정답(golden reference) 으로 사용한다.

구조 (HO_01 섹션 7.1 그대로):
    SpWNode
      ├── SpWLink     Link State Machine + Flow Control + 타이머
      ├── SpWEncoder  D-S 인코딩, 문자 조립, 패리티 생성, 직렬화
      ├── SpWDecoder  D-S 디코딩, 문자 파싱, 패리티 검사, 역직렬화
      └── SpWNetwork  패킷 조립/분해, Timecode

이 모델은 시스템 클럭 사이클 단위(tick)로 동작하며, D-S 라인은
실제 배선처럼 비트 단위로 직렬화된다 (자기 클럭 방식/self-clocking).
따라서 여기서 검증한 사이클 카운트/타이밍은 RTL 스코어보드에
그대로 사용할 수 있다.

※ 표준 해석 관련 결정 사항은 파일 하단 DECISION_LOG 주석 및
   HO_00_Common.md 섹션 9 에 반영한다.
"""

from __future__ import annotations
from enum import IntEnum
from dataclasses import dataclass, field
from typing import Optional, List, Deque
from collections import deque


# ============================================================
# 0. 파라미터 (HO_00_Common.md 섹션 5 / HO_01 섹션 4 동일)
# ============================================================
@dataclass
class SpWParams:
    CLK_FREQ_HZ: int = 100_000_000
    TX_RATE_MBPS: int = 10
    TX_FIFO_DEPTH: int = 128
    RX_FIFO_DEPTH: int = 128
    ENABLE_TIMECODE: int = 1
    ENABLE_AUTOSTART: int = 1
    DISCONNECT_TIMEOUT_NS: int = 850

    def __post_init__(self):
        bit_rate_hz = self.TX_RATE_MBPS * 1_000_000
        assert self.CLK_FREQ_HZ % bit_rate_hz == 0, \
            f"CLK/TX 분주비가 정수가 아님: {self.CLK_FREQ_HZ} / {bit_rate_hz}"
        assert self.TX_RATE_MBPS <= self.CLK_FREQ_HZ / 2_000_000, \
            "TX_RATE_MBPS 가 CLK_FREQ_HZ/2,000,000 제약 초과"
        # P1-4 (codex 리뷰) 최종 수정: 초기 FCT 개수를 RX_FIFO_DEPTH 기반으로
        # 동적 계산하도록 SpWLink._enter(CONNECTING) 에서 고쳤으므로(ERRATA-9),
        # 최소값은 FCT 최소 단위(8)로 되돌린다.
        assert self.RX_FIFO_DEPTH >= 8, "RX_FIFO_DEPTH 는 FCT 최소 단위(8) 이상이어야 함"
        assert 500 <= self.DISCONNECT_TIMEOUT_NS <= 1600, \
            "DISCONNECT_TIMEOUT_NS 는 500~1600ns 범위"

        self.BIT_PERIOD_CYCLES = self.CLK_FREQ_HZ // bit_rate_hz
        # P2-2 (codex 리뷰): 부동소수점 연산 후 int() 로 절삭하면 CLK_FREQ_HZ 조합에
        # 따라 부동소수점 오차로 요구 시간보다 짧게 계산될 수 있다. 정수 나눗셈으로
        # 교체했다 (6.4us = 64/10,000,000 초, 850ns = DISCONNECT_TIMEOUT_NS/1e9 초).
        self.CNT_6US  = (self.CLK_FREQ_HZ * 64) // 10_000_000
        self.CNT_12US = self.CNT_6US * 2
        self.CNT_DISC = (self.CLK_FREQ_HZ * self.DISCONNECT_TIMEOUT_NS) // 1_000_000_000


# ============================================================
# 1. Link State (HO_00_Common.md 섹션 7.2)
# ============================================================
class LinkState(IntEnum):
    ERROR_RESET = 0
    ERROR_WAIT  = 1
    READY       = 2
    STARTED     = 3
    CONNECTING  = 4
    RUN         = 5


# ============================================================
# 2. Character 정의 (ECSS 5.4)
# ============================================================
class CharKind(IntEnum):
    DATA      = 0
    FCT       = 1
    EOP       = 2
    EEP       = 3
    ESC       = 4
    TIMECODE  = 5   # ESC 다음에 오는 Data 형태 문자 (flag[2]+counter[6])


@dataclass
class Character:
    kind: CharKind
    value: int = 0   # DATA: 0~255 데이터바이트 / TIMECODE: flag(2)<<6 | counter(6)

    def __repr__(self):
        if self.kind == CharKind.DATA:
            return f"DATA(0x{self.value:02X})"
        if self.kind == CharKind.TIMECODE:
            return f"TIMECODE(0x{self.value:02X})"
        return self.kind.name


# 제어문자 2비트 코드 — ECSS 5.4.3.2 원문 확정값: FCT=0b00, EOP=0b10, EEP=0b01, ESC=0b11
# ※ ERRATA-7 (원문 재확인): 이전 버전은 EOP/EEP 코드가 서로 바뀌어 있었다
#   (EOP=01, EEP=10 로 잘못 기재). ECSS 5.4.3.2.d/e 원문과, Figure 5-15의
#   "0x5C 데이터 뒤에 Null" 예제 비트열을 직접 복호해 교차 검증한 값이다.
CONTROL_CODE = {
    CharKind.FCT: 0b00,
    CharKind.EOP: 0b10,
    CharKind.EEP: 0b01,
    CharKind.ESC: 0b11,
}
CODE_TO_CONTROL = {v: k for k, v in CONTROL_CODE.items()}


def char_to_flag_payload(ch: Character):
    """Character -> (control_flag_bit, payload_bits(list, LSB first))

    ERRATA-7 (원문 재확인): ECSS 5.4.3.1.c "The eight-bit data value shall be
    transmitted least significant bit first." 에 따라 데이터/제어 payload
    비트는 모두 LSB 먼저 전송한다 (이전 버전은 MSB 먼저였음 — Figure 5-15 예제
    비트열로 교차 검증).
    """
    if ch.kind in (CharKind.DATA, CharKind.TIMECODE):
        payload = [(ch.value >> i) & 1 for i in range(8)]   # LSB(bit0) 부터
        return 0, payload
    code = CONTROL_CODE[ch.kind]
    payload = [code & 1, (code >> 1) & 1]                    # LSB(bit0) 부터
    return 1, payload


# ============================================================
# 3. Data-Strobe 인코딩/디코딩 (ECSS 5.4.3)
# ============================================================
class DSEncoder:
    def __init__(self):
        self.data = 0
        self.strobe = 0

    def encode_bit(self, bit: int):
        # DECISION-09 (아래 파일 하단 결정 로그 참조): Data 라인이 원본 비트값을 그대로
        # 나르고, Strobe 는 "Data XOR Strobe 가 매 비트마다 반드시 토글" 되도록 만드는
        # 보조 클럭 신호다. 이 자기 클럭(self-clocking) 불변식이 성립해야 수신측이
        # 별도의 비트레이트 정보 없이 D/S 라인 천이만으로 비트 경계를 검출할 수 있다.
        #   S(n) = NOT( D(n) XOR D(n-1) XOR S(n-1) )
        new_strobe = 1 ^ bit ^ self.data ^ self.strobe
        self.data = bit
        self.strobe = new_strobe
        return self.data, self.strobe


# ============================================================
# 4. SpWEncoder — 문자 조립 + 패리티 + 직렬화 (ECSS 5.4.3/5.4.4)
# ============================================================
class SpWEncoder:
    """
    문자 단위 입력(send_char)을 받아 시스템 클럭 tick() 마다
    1/BIT_PERIOD_CYCLES 확률로 한 비트씩 D-S 라인에 실어 보낸다.
    """

    def __init__(self, params: SpWParams):
        self.params = params
        self.ds = DSEncoder()
        # ERRATA-8: parity 는 심볼마다 자기완결적으로 계산되므로 누적 상태가
        # 더 이상 필요 없다 (이전 버전의 self.parity 필드 제거).
        self._bitq: Deque[int] = deque()
        self._bit_cycle_cnt = 0

        self.tx_data = 0
        self.tx_strobe = 0
        self.busy = False               # 현재 문자 송신 중 (idle 이 아니면 새 문자 큐잉 금지 아님, FIFO 로 관리하는 상위 레이어가 판단)
        self.char_sent: Optional[Character] = None   # 이번 tick 에 새 문자 전송을 "시작"했는지 알림 (1클럭 pulse)
        self._just_started: Optional[Character] = None

    def idle(self) -> bool:
        """현재 전송 중인 비트가 없으면 True (다음 문자를 바로 실어 보낼 수 있음)"""
        return not self._bitq and self._bit_cycle_cnt == 0

    def reset(self):
        """P0-3 (codex 리뷰): 링크 ERROR_RESET 진입 시 호출.
        진행 중이던 부분 문자(비트 큐)를 모두 버리고 다음 재연결이 정상적인
        문자 경계에서 시작하도록 한다. D/S 라인 자체는 물리적으로 마지막
        값을 유지한다(급격한 라인 변화로 상대측에 잘못된 비트를 주지 않기 위함)."""
        self._bitq.clear()
        self._bit_cycle_cnt = 0
        self.busy = False
        self.char_sent = None
        self._just_started = None

    def send_char(self, ch: Character):
        """새 문자 전송 시작. idle() 인 상태에서만 호출해야 함.

        ERRATA-8 (원문 재확인, codex 리뷰 P0-6/P1-5 대응): ECSS 5.4.3.4 및
        Figure 5-15 의 "0x5C 데이터 뒤에 Null" 예제 비트열을 직접 복호해 검증한
        결과, parity 는 "이전 문자에 걸친 누적 XOR" 이 아니라 "이번 심볼 자신의
        [parity 비트, flag, payload] 전체에서 1의 개수가 홀수(ODD)가 되도록"
        정하는 완전히 자기완결적(self-contained) 값이다. 이전 버전은
        HO_00_Common.md 의 "짝수(Even) parity + 이전 parity 누적" 서술을 그대로
        구현했으나 원문과 다르다."""
        flag, payload = char_to_flag_payload(ch)
        ones = flag + sum(payload)
        p = 0 if ones % 2 == 1 else 1   # 전체(P 포함) 1의 개수가 홀수가 되도록 P 선택
        bits = [p, flag] + payload
        self._bitq.extend(bits)
        self.busy = True
        # P2-3 (codex 리뷰): char_sent 가 정의만 되고 실제 값이 설정되지 않던 것을
        # 수정. 다음 tick() 호출 시 1클럭 pulse 로 노출된다.
        self._just_started = ch

    def tick(self):
        self.char_sent = self._just_started
        self._just_started = None
        if self._bit_cycle_cnt == 0:
            if self._bitq:
                bit = self._bitq.popleft()
                self.tx_data, self.tx_strobe = self.ds.encode_bit(bit)
            else:
                self.busy = False
        self._bit_cycle_cnt = (self._bit_cycle_cnt + 1) % self.params.BIT_PERIOD_CYCLES


# ============================================================
# 5. SpWDecoder — D-S 수신 + 패리티 검사 + 문자 파싱 (ECSS 5.4.3/5.4.4)
# ============================================================
class SpWDecoder:
    class _St(IntEnum):
        WAIT_PARITY = 0
        WAIT_FLAG   = 1
        WAIT_BITS   = 2

    def __init__(self, params: SpWParams):
        self.params = params
        self.rx_data = 0
        self.rx_strobe = 0
        self.prev_data = 0
        self.prev_strobe = 0
        # ERRATA-8: parity 는 심볼마다 자기완결적으로 계산되므로 누적 상태가
        # 더 이상 필요 없다 (이전 버전의 self.parity 필드 제거).

        self._state = self._St.WAIT_PARITY
        self._rx_parity_bit = 0
        self._flag = 0
        self._need = 0
        self._acc_bits: List[int] = []

        self.no_change_cnt = 0
        # ERRATA-5 / codex 리뷰 재현 버그 (신규 발견): ECSS Figure 5-19 NOTE 1은
        # "Disconnect Error is only enabled after the first transition on the
        # data or strobe line" 이라고 명시한다. 이는 상태(state) 기반이 아니라
        # "이번 세션에서 상대로부터 아직 한 번도 신호를 받은 적이 없다면"
        # disconnect 판정 자체를 비활성화해야 한다는 뜻이다.
        # 이 가드가 없으면: 한쪽만 에러로 재시작(reset)된 뒤 두 노드의 재시작
        # 타이밍이 어긋나 상대가 Started 응답을 850ns(85클럭) 이상 늦게
        # 시작하면, 아직 아무 신호도 못 받았을 뿐인데 "무신호 disconnect" 로
        # 오판해 다시 리셋되고, 이 어긋남이 반복되며 두 노드가 영원히 Run 에
        # 도달하지 못하는 것을 시뮬레이션으로 실제 확인했다 (편측 credit_error
        # 주입 후 재연결 테스트).
        self.seen_any_transition = False

        # 이번 tick 결과 (1클럭 pulse)
        self.char_ready: Optional[Character] = None
        self.parity_error = False
        self.disconnect = False

    def set_lines(self, data: int, strobe: int):
        self.rx_data = data
        self.rx_strobe = strobe

    def tick(self):
        self.char_ready = None
        self.parity_error = False

        changed = (self.rx_data != self.prev_data) or (self.rx_strobe != self.prev_strobe)
        if changed:
            # DECISION-09: Data 라인이 원본 비트값을 그대로 나르므로, 천이가 검출된
            # 시점의 rx_data 값이 곧 수신 비트다 (별도 XOR 복호 불필요).
            bit = self.rx_data
            self.no_change_cnt = 0
            self.seen_any_transition = True
            self.disconnect = False
            self._consume_bit(bit)
        else:
            self.no_change_cnt += 1
            # ECSS Figure 5-19 NOTE 1: 첫 천이가 있기 전까지는 disconnect 판정 자체가
            # 비활성화된다.
            self.disconnect = self.seen_any_transition and (self.no_change_cnt >= self.params.CNT_DISC)

        self.prev_data = self.rx_data
        self.prev_strobe = self.rx_strobe

    def reset_framing(self):
        """P0-3 (codex 리뷰) + 신규 발견 재연결 데드락 수정: 링크 ERROR_RESET 진입 시
        호출. 문자 조립 상태와 parity 를 초기화해, 재연결 시 이전 문자의 나머지
        비트가 다음 문자의 일부로 잘못 해석되지 않도록 한다.
        또한 seen_any_transition/no_change_cnt 를 초기화해, 이번 재시작
        세션에서 상대가 응답하기 전까지는 disconnect 판정이 다시 비활성화되도록
        한다 (ECSS Figure 5-19 NOTE 1). 이걸 유지하지 않으면 한쪽만 리셋된 뒤
        재시작 타이밍이 어긋난 상대를 기다리는 동안 무신호 disconnect 오탐이
        반복되어 두 노드가 영원히 Run 에 도달하지 못하는 것을 확인했다."""
        self._state = self._St.WAIT_PARITY
        self._rx_parity_bit = 0
        self._flag = 0
        self._need = 0
        self._acc_bits = []
        self.no_change_cnt = 0
        self.seen_any_transition = False
        self.disconnect = False
        self.char_ready = None
        self.parity_error = False

    def _consume_bit(self, bit: int):
        if self._state == self._St.WAIT_PARITY:
            self._rx_parity_bit = bit
            self._state = self._St.WAIT_FLAG
        elif self._state == self._St.WAIT_FLAG:
            self._flag = bit
            self._need = 2 if bit == 1 else 8
            self._acc_bits = []
            self._state = self._St.WAIT_BITS
        else:  # WAIT_BITS
            self._acc_bits.append(bit)
            if len(self._acc_bits) == self._need:
                self._finish_char()
                self._state = self._St.WAIT_PARITY

    def _finish_char(self):
        # ERRATA-8: 자기완결적 ODD parity 검사 (원문 근거는 send_char 주석 참조).
        ones = self._rx_parity_bit + self._flag + sum(self._acc_bits)
        if ones % 2 == 0:   # 홀수(ODD)여야 정상 — 짝수면 parity 오류
            self.parity_error = True

        if self._flag == 1:
            # ERRATA-7: 제어 코드 2비트도 LSB 먼저 수신됨
            code = self._acc_bits[0] | (self._acc_bits[1] << 1)
            self.char_ready = Character(CODE_TO_CONTROL[code])
        else:
            # ERRATA-7: 데이터 8비트는 LSB 먼저 수신됨
            val = 0
            for i, b in enumerate(self._acc_bits):
                val |= (b << i)
            self.char_ready = Character(CharKind.DATA, val)


# ============================================================
# 6. SpWNetwork — 패킷 조립/분해 + Timecode (사용자 핀 인터페이스)
# ============================================================
class SpWNetwork:
    """
    사용자 TX/RX 핀 (9비트 통합 포맷, HO_01 섹션 5) <-> 문자 스트림 변환.
    Null / FCT / Timecode 는 SpWLink 가 처리하고, 여기서는
    DATA / EOP / EEP 문자(N-Char 스트림)만 다룬다.
    """

    def __init__(self, params: SpWParams):
        self.params = params
        self.tx_fifo: Deque[Character] = deque()
        self.rx_fifo: Deque[Character] = deque()

        self.rx_pin_valid = False
        self.rx_pin_data9 = 0

        self.tick_out = False
        self.time_out = 0
        self._prev_tick_in = 0

        # P1-7 (codex 리뷰, 사용자 결정 반영): 9비트 TX 인터페이스에서
        # bit[8]=1(제어) 인데 하위 8비트가 0x00(EOP)/0x01(EEP) 이 아닌 값은
        # 전부 잘못된 입력으로 간주해 큐잉하지 않고 버린다. bit[7:2] 를 예약
        # (reserved=0) 으로 두고 그 외 조합(0x102~0x1FF)은 상위 로직의 버그
        # 신호일 수 있으므로 조용히 흡수(EEP로 변환)하지 않는다.
        self.invalid_tx_ctrl = False   # 1클럭 pulse

    # ---- 사용자 TX 입력 핀 ----
    def push_tx(self, data9: int, valid: bool) -> bool:
        """반환값 = ow_tx_ready (이번 클럭 기준, 다음 클럭에 실제로 들어감)"""
        ready = len(self.tx_fifo) < self.params.TX_FIFO_DEPTH
        self.invalid_tx_ctrl = False
        if valid and ready:
            if data9 & 0x100:
                if data9 == 0x100:
                    self.tx_fifo.append(Character(CharKind.EOP))
                elif data9 == 0x101:
                    self.tx_fifo.append(Character(CharKind.EEP))
                else:
                    # 정의되지 않은 제어 코드 (0x102~0x1FF) — 큐잉하지 않고
                    # 에러 플래그만 세운다 (DECISION-13 참조).
                    self.invalid_tx_ctrl = True
            else:
                ch = Character(CharKind.DATA, data9 & 0xFF)
                self.tx_fifo.append(ch)
        return ready

    def peek_tx(self) -> Optional[Character]:
        return self.tx_fifo[0] if self.tx_fifo else None

    def pop_tx(self) -> Optional[Character]:
        return self.tx_fifo.popleft() if self.tx_fifo else None

    def rx_free_space(self) -> int:
        return self.params.RX_FIFO_DEPTH - len(self.rx_fifo)

    # ---- 수신 문자 저장 (Link 계층이 Data/EOP/EEP 만 넘겨줌) ----
    def on_rx_char(self, ch: Character):
        if len(self.rx_fifo) < self.params.RX_FIFO_DEPTH:
            self.rx_fifo.append(ch)
        # 오버플로우는 RX FIFO 크레딧 관리(FCT)로 원천 방지되어야 하므로
        # 여기서는 방어적으로 드롭만 한다.

    # ---- 사용자 RX 출력 핀 ----
    def tick_rx_pin(self, rx_ready: bool):
        self.rx_pin_valid = len(self.rx_fifo) > 0
        if self.rx_pin_valid:
            ch = self.rx_fifo[0]
            if ch.kind == CharKind.EOP:
                self.rx_pin_data9 = 0x100 | 0x00
            elif ch.kind == CharKind.EEP:
                self.rx_pin_data9 = 0x100 | 0x01
            else:
                self.rx_pin_data9 = ch.value & 0xFF
            if rx_ready:
                self.rx_fifo.popleft()
        else:
            self.rx_pin_data9 = 0

    # ---- Timecode ----
    def sample_tick_in(self, tick_in: int, time_in: int) -> Optional[int]:
        rising = (tick_in == 1) and (self._prev_tick_in == 0)
        self._prev_tick_in = tick_in
        if rising and self.params.ENABLE_TIMECODE:
            flag = (time_in >> 6) & 0x3
            counter = time_in & 0x3F
            return (flag << 6) | counter
        return None

    def on_timecode_rx(self, value: int):
        self.time_out = value
        self.tick_out = True


# ============================================================
# 7. SpWLink — Link State Machine + Flow Control + 타이머 (ECSS 5.5)
# ============================================================
class SpWLink:
    MAX_CREDIT = 56   # 7 x FCT(8) — 표준상 outstanding credit 상한 (DECISION-06)

    def __init__(self, params: SpWParams):
        self.params = params
        self.state = LinkState.ERROR_RESET
        self.timer = 0

        # 입력 핀
        self.link_en = 0
        self.link_start = 0
        self.auto_start = 0
        self.port_reset = 0

        # 상태 진입 후 누적 래치 (gotNull/gotFCT/gotNChar)
        self._null_seen = False
        self._fct_seen = False
        self._nchar_seen = False

        # [DECISION-18 Option B, 2026-09-14] ECSS 5.4.6.b/d + 5.5.7.2.a.2/NOTE:
        # gotNull은 "Receive Enable이 de-assert될 때만" 클리어된다 -- 이건
        # ErrorReset 진입 시점(RX Enable de-assert)에만 일어나고, 그 외 모든
        # 상태 전이에서는 유지된다. `_null_seen`은 Started->Connecting 전이용
        # 좁은 목적의 플래그라 Connecting이 아닌 모든 전이(RUN 포함!)에서
        # 리셋되므로 이 용도로 재사용할 수 없다 -- 별도 latch가 필요하다.
        self._gotnull_latch = False

        # 에러 입력 (SpWNode 가 매 tick 채움)
        self.disconnect = False
        self.parity_error = False
        self.esc_error = False
        self.credit_error = False

        # ESC 시퀀스 처리 상태 (수신)
        self._pending_esc = False

        # ECSS 5.5.7.1 Figure 5-19: "Sent FCT" 래치 (Connecting 상태에서 최소 1개의
        # 독립 FCT 를 실제로 송신했는지)
        self._fct_sent_in_connecting = False

        # 프로토콜 위반 (ErrorWait/Ready/Started 에서 순수 FCT/N-Char 수신,
        # Connecting 에서 N-Char 수신 — ECSS 5.5.7.3~5.5.7.6 각 상태의 leave 조건 참조)
        self.protocol_violation = False

        # Flow control
        self.tx_credit = 0            # 내가 상대에게 보낼 수 있는 남은 크레딧
        self.rx_credit_budget = 0     # 내가 상대에게 부여한(FCT 로 알려준) 수신 여유 크레딧

        # 요청/제어 플래그
        self.req_initial_fct = 0      # Connecting 진입 시 2 로 세팅
        self.req_fct = False          # RX 여유공간 기반 FCT 요청 (SpWNode 가 세팅)

        # ERRATA-18 (EEP 자동 복구, ECSS 5.5.8.4.a.2):
        self._rx_pkt_in_progress = False  # RUN 중 DATA 수신 시작~EOP/EEP 이전까지 True
        self._eep_pending = False         # 에러 진입 시 미완성 패킷이 있었으면 True.
                                           # 레벨 신호 — RX FIFO 에 실제로 EEP 를
                                           # 써넣을 때까지(SpWNode.tick() 참조) 유지.

        # ERRATA-26 (TX FIFO 잔여 바이트 leak 방지, E1/EEP과 대칭되는 TX측):
        self._tx_pkt_in_progress = False  # RUN 중 DATA 송신 시작~EOP/EEP 이전까지 True
        self._tx_flushing = False         # 에러 진입 시 미송신 패킷이 있었으면 True.
                                           # 레벨 신호 — TX FIFO에서 다음 EOP/EEP를
                                           # 만나 그것까지 버릴 때까지(SpWNode.tick()
                                           # 참조) 유지. eep_pending과 달리 "공간을
                                           # 기다리는" 게 아니라 "그냥 계속 버리는"
                                           # 것이라 보통 훨씬 빨리 끝난다.

        # 출력 상태 (핀)
        self.link_state_out = LinkState.ERROR_RESET
        self.err_disconnect = False
        self.err_parity = False
        self.err_esc = False
        self.err_credit = False

    def _enter(self, new_state: LinkState):
        self.state = new_state
        self.timer = 0
        # gotNull 은 Started 상태에서 이미 달성된 마일스톤이므로 Connecting 진입 시에는
        # 유지한다 (Connecting 안에서 Null 을 다시 받을 필요는 없음). 그 외 전이에서는
        # 래치를 초기화한다.
        if new_state != LinkState.CONNECTING:
            self._null_seen = False
        self._fct_seen = False
        self._nchar_seen = False
        if new_state == LinkState.ERROR_RESET:
            # [DECISION-18 Option B] ECSS 5.5.7.2.a.2 + NOTE: ErrorReset 진입이
            # Receive Enable을 de-assert하고, 그게 gotNull을 클리어시킨다.
            self._gotnull_latch = False
        if new_state == LinkState.CONNECTING:
            # ERRATA-9 (원문 재확인, codex 리뷰 P1-4 대응): ECSS 5.5.4.k
            # "one FCT shall be sent for every eight N-Chars that can be held
            # in the receive FIFO up to the maximum of seven FCTs." 이전
            # 버전은 FIFO 크기와 무관하게 무조건 2개(16 credit)를 고정 부여해,
            # RX_FIFO_DEPTH 가 작은 설정에서는 실제 저장 공간보다 큰 credit을
            # 상대에게 주는 모순이 있었다. FIFO 크기 기반으로 계산한다.
            self.req_initial_fct = min(self.params.RX_FIFO_DEPTH // 8, 7)
            self._fct_sent_in_connecting = False   # ECSS 5.5.7.1: "Sent FCT" 래치
        if new_state == LinkState.ERROR_RESET:
            self.tx_credit = 0
            self.rx_credit_budget = 0
            self._pending_esc = False
            # P0-2 (codex 리뷰): credit_error 는 sticky 상태였고 clear 되지 않아
            # 이후 재연결 시도가 매번 즉시 ErrorReset 되는 문제가 있었다. reset 시
            # 명시적으로 클리어한다.
            self.credit_error = False
            # ERRATA-18: 미완성 패킷이 있었으면 그 정보를 _eep_pending 으로
            # 승계한다. _eep_pending 자체는 여기서 클리어하지 않는다 — RX FIFO
            # 에 실제로 EEP 를 써넣을 때(SpWNode.tick())까지 유지되는 레벨
            # 신호이기 때문. (RTL 의 r_eep_pending 과 동일 설계, §9.6 참조)
            if self._rx_pkt_in_progress:
                self._eep_pending = True
            self._rx_pkt_in_progress = False
            # ERRATA-26: TX측도 동일 패턴 — 미송신 패킷이 있었으면 승계
            if self._tx_pkt_in_progress:
                self._tx_flushing = True
            self._tx_pkt_in_progress = False

    def on_char(self, ch: Character):
        """
        수신 문자 1개 처리.
        반환값:
          None                -> Link 계층에서 소비 완료 (Null / FCT)
          "TIMECODE"           -> 상위(SpWNode)가 Timecode 로 처리해야 함
          Character(DATA/EOP/EEP) -> Network 계층으로 전달해야 함
        """
        if self._pending_esc:
            self._pending_esc = False
            if ch.kind == CharKind.FCT:
                self._null_seen = True
                self._gotnull_latch = True   # [DECISION-18 Option B] 진짜 gotNull 래치, ErrorReset까지 유지
                return None
            elif ch.kind == CharKind.DATA:
                return "TIMECODE"
            else:
                self.esc_error = True
                return None

        if ch.kind == CharKind.ESC:
            self._pending_esc = True
            return None

        # ECSS 5.5.7.2/.3/.4/.5 (ErrorReset/ErrorWait/Ready/Started) leave 조건:
        # "FCT, N-Char 또는 BC 수신 시 ErrorReset" — Null(ESC+FCT)의 일부가 아닌
        # "순수" FCT 나 N-Char(DATA/EOP/EEP) 를 이 상태들에서 받으면 프로토콜 위반이다.
        # P1-1/P1-2 (codex 리뷰): 원래 DATA 만 검사하고 EOP/EEP 는 빠져 있었고,
        # ERROR_RESET 상태 자체도 이 검사 대상에서 빠져 있어 ERROR_RESET 중에도
        # EOP/EEP 가 오류 없이 그대로 네트워크 계층(RX FIFO)까지 전달되는 문제가 있었다.
        if self.state in (LinkState.ERROR_RESET, LinkState.ERROR_WAIT,
                          LinkState.READY, LinkState.STARTED) \
                and ch.kind in (CharKind.FCT, CharKind.DATA, CharKind.EOP, CharKind.EEP):
            self.protocol_violation = True
            return None

        # ECSS 5.5.7.6 (Connecting) leave 조건 6: "N-Char 수신 시 ErrorReset"
        # (FCT 수신은 Connecting 에서 정상 — gotFCT 조건 자체이므로 제외)
        # P1-1: N-Char 는 DATA 뿐 아니라 EOP/EEP 도 포함한다.
        if self.state == LinkState.CONNECTING and ch.kind in (CharKind.DATA, CharKind.EOP, CharKind.EEP):
            self.protocol_violation = True
            return None

        if ch.kind == CharKind.FCT:
            self._fct_seen = True
            # ERRATA-9 (원문 재확인, codex 리뷰 P1-3 대응): ECSS 5.5.4.j / 5.5.5.a.2
            # "If an FCT is received which causes the transmit credit counter
            # to exceed its maximum value, a credit error shall be raised."
            # 이전 버전은 MAX_CREDIT 에서 조용히 saturate(min) 시켜 초과 FCT를
            # 오류 없이 흡수했다. 표준은 이를 명시적으로 credit error 로 취급한다.
            if self.tx_credit + 8 > self.MAX_CREDIT:
                self.credit_error = True
            else:
                self.tx_credit += 8
            return None

        # DATA / EOP / EEP : 크레딧 budget 검사 (DECISION-07)
        if self.rx_credit_budget <= 0:
            self.credit_error = True
        else:
            self.rx_credit_budget -= 1

        if ch.kind == CharKind.DATA:
            self._nchar_seen = True
            self._rx_pkt_in_progress = True       # ERRATA-18: 패킷 진행 중
        elif ch.kind in (CharKind.EOP, CharKind.EEP):
            self._rx_pkt_in_progress = False      # ERRATA-18: 정상 종료
        return ch

    def note_tx_char_sent(self, ch: Character, is_independent_fct: bool = False):
        """실제로 문자를 송신했을 때 후처리 (credit 차감/증가)

        ERRATA-23: FCT 는 두 가지 경로로 나갈 수 있다 — (a) 우선순위 2/3의 "독립
        FCT"(credit +8 부여 대상), (b) Null idle filler(ESC+FCT 원자쌍)의 두 번째
        문자인 "동반 FCT"(credit 미부여). 이 둘을 구분하지 않고 FCT 종류이기만
        하면 무조건 credit +8을 주면, 유휴 상태에서 반복되는 Null 필러가 돌 때마다
        credit이 잘못 누적되어 MAX_CREDIT 에 계속 눌러앉는 영구 데드락이 생긴다
        (55바이트는 정상, 56바이트부터 EOP 미전송 — RTL의 w_send_fct/w_send_second
        구분과 동일한 원칙).
        """
        if ch.kind in (CharKind.DATA, CharKind.EOP, CharKind.EEP):
            self.tx_credit = max(0, self.tx_credit - 1)
            # ERRATA-26: 실제로 나간(discard 아닌) 문자만 추적한다. 이 함수는
            # SpWNode.tick() §4에서 "인코더로 실제 송신한" 직후에만 호출되므로,
            # flush 중 버려지는 문자는 애초에 여기 안 들어온다(별도 pop 경로).
            if ch.kind == CharKind.DATA:
                self._tx_pkt_in_progress = True
            else:
                self._tx_pkt_in_progress = False
        elif ch.kind == CharKind.FCT and is_independent_fct:
            self.rx_credit_budget = min(self.rx_credit_budget + 8, self.MAX_CREDIT)
            if self.state == LinkState.CONNECTING:
                self._fct_sent_in_connecting = True   # ECSS "Sent FCT"

    def tick(self):
        # [DECISION-18 Option B, 2026-09-14] ECSS 5.4.7.a/5.4.9.b: parity/ESC
        # error 검출은 gotNull이 assert된 동안에만 활성화되어야 한다. 이전에는
        # 이 둘이 gotNull 여부와 무관하게 무조건 immediate_error에 포함돼 있었다
        # -- 실측(golden model에 dec.parity_error 직접 주입)으로 확인: gotNull
        # 이전(콜드부트 직후 ErrorWait 등)에 스퓨리어스 parity/ESC 에러가 뜨면
        # 표준상 무시돼야 하는데 실제로는 즉시 ErrorReset으로 튕겼다. 이제
        # _gotnull_latch로 게이팅한다 -- gotNull 이후(Started 이후~다음
        # ErrorReset 전까지)에는 기존과 동일하게 동작한다.
        immediate_error = (
            (not self.link_en) or self.disconnect
            or (self.parity_error and self._gotnull_latch)
            or (self.esc_error and self._gotnull_latch)
            or self.protocol_violation
            or (self.state == LinkState.RUN and self.credit_error)
        )
        if immediate_error:
            if self.state != LinkState.ERROR_RESET:
                self._enter(LinkState.ERROR_RESET)
            # P0-1 (codex 리뷰): 이미 ERROR_RESET 상태에서 link_en=0 등으로
            # immediate_error 가 계속 True 인 경우, 원래는 아래 else 블록으로 빠져
            # 타이머가 계속 진행되어 640클럭 후 ERROR_WAIT 로 잘못 전이했다가 다음
            # 클럭에 다시 ERROR_RESET 으로 돌아오는 진동이 발생했다. immediate_error
            # 가 True 인 한 ERROR_RESET 에 완전히 머물러야 하므로, 이 분기에서는
            # 타이머를 진행하지 않는다 (link_en 재활성화 시점부터 6.4us 를 새로 계수).
        else:
            self.timer += 1
            if self.state == LinkState.ERROR_RESET:
                # ECSS 5.5.7.2/Figure 5-19: ErrorReset 은 6.4us 타이머를 갖고,
                # 타이머 경과 + LinkDisabled 미설정 시 ErrorWait 로 전이한다.
                if self.timer >= self.params.CNT_6US:
                    self._enter(LinkState.ERROR_WAIT)
            elif self.state == LinkState.ERROR_WAIT:
                # ECSS 5.5.7.3: ErrorWait 은 12.8us 타이머를 갖는다.
                if self.timer >= self.params.CNT_12US:
                    self._enter(LinkState.READY)
            elif self.state == LinkState.READY:
                if self.link_start or (self.auto_start and self._null_seen):
                    self._enter(LinkState.STARTED)
            elif self.state == LinkState.STARTED:
                if self._null_seen:
                    self._enter(LinkState.CONNECTING)
                elif self.timer >= self.params.CNT_12US:
                    self._enter(LinkState.ERROR_RESET)
            elif self.state == LinkState.CONNECTING:
                # ECSS 5.5.7.6.b.5 / Figure 5-19: "gotFCT AND Sent FCT" 일 때만 Run 진입.
                # (gotNull/gotNChar 는 이 전이 조건에 포함되지 않음 — 아래 결정 로그 참조)
                if self._fct_seen and self._fct_sent_in_connecting:
                    self._enter(LinkState.RUN)
                elif self.timer >= self.params.CNT_12US:
                    self._enter(LinkState.ERROR_RESET)
            # RUN: 에러 조건 발생 전까지 유지

        self.link_state_out = self.state
        self.err_disconnect = self.disconnect
        self.err_parity = self.parity_error
        self.err_esc = self.esc_error
        self.err_credit = self.credit_error


# ============================================================
# 8. SpWNode — 최상위 통합 (핀 인터페이스, HO_00_Common.md 섹션 4 대응)
# ============================================================
@dataclass
class NodeInputs:
    link_en: int = 0
    link_start: int = 0
    auto_start: int = 0
    port_reset: int = 0
    tx_data9: int = 0
    tx_valid: int = 0
    rx_ready: int = 1
    tick_in: int = 0
    time_in: int = 0
    # DECISION-16 (시나리오 11): i_rst_n — 비동기 전체 리셋. port_reset과 달리
    # 사용자 TX/RX FIFO 까지 함께 초기화한다(데이터 유실 감수). Active-low이므로
    # 기본값 1(리셋 미인가).
    rst_n: int = 1


class SpWNode:
    """SpaceWire 단일 포트 노드 Reference Model (HO_01 섹션 7.1)"""

    # [DECISION-17 Option B] Timecode가 FCT/N-Char 송신 기회를 이 횟수만큼
    # 연속으로 이기면 그다음 한 번은 양보한다 (§_select_next_tx_char 참조).
    # 값 자체는 이 프로젝트의 실제 트래픽 프로파일에 맞춰 조정 가능한 튜닝
    # 파라미터이며, 프로토콜 정합성(ECSS 5.5.6.a 준수 여부)에는 영향 없음 —
    # 병적 재무장 상황에서만 개입하므로 어떤 값이든 정상 동작 시나리오에서는
    # 카운터가 임계값에 도달하지 않는다.
    TC_STARVE_THRESHOLD = 8

    def __init__(self, params: SpWParams, name: str = "node"):
        self.params = params
        self.name = name
        self.link = SpWLink(params)
        self.enc = SpWEncoder(params)
        self.dec = SpWDecoder(params)
        self.net = SpWNetwork(params)

        self.i = NodeInputs()

        # 핀 출력
        self.ow_tx_ready = False
        self.ow_rx_valid = False
        self.ow_rx_data = 0
        self.ow_tick_out = False
        self.ow_time_out = 0
        self.ow_link_state = LinkState.ERROR_RESET
        self.ow_err_disconnect = False
        self.ow_err_parity = False
        self.ow_err_esc = False
        self.ow_err_credit = False
        # DECISION-13: ECSS 표준 신호는 아니고, 이 프로젝트의 9비트 TX 핀
        # 인터페이스 자체에서 정의하는 사용자 입력 오류 신호다 (P1-7 대응).
        self.ow_err_tx_invalid = False

        # 내부: 진행 중인 ESC 원자적 시퀀스(Null/Timecode)의 두 번째 문자
        self._esc_seq_continue: Optional[Character] = None
        # P2-1 (codex 리뷰): 무제한 큐였던 것을 1개로 제한한다. 송신 불가 상태에서
        # tick_in 이 여러 번 들어오면 최신 값만 유지한다(drop-old 정책).
        self._tc_pending: Deque[int] = deque(maxlen=1)
        self._prev_state: Optional[LinkState] = None
        # ERRATA-23: 방금 _select_next_tx_char() 가 반환한 문자가 "독립 FCT"인지
        # 표시. note_tx_char_sent() 의 credit 부여 여부 판단에 쓰인다.
        self._last_char_was_independent_fct = False
        # [DECISION-17 Option B, 2026-09-13] Timecode가 FCT/N-Char를 연속으로
        # 이긴 횟수. TC_STARVE_THRESHOLD 도달 시 한 번 양보한다. scenario_24가
        # 실측한 "물리적 최대 tick_in 재무장 시 완전 정체"를 막기 위한 안전장치 —
        # 정상 사용(느린 주기의 정당한 Timecode 요청)에서는 이 카운터가 절대
        # 임계값에 도달하지 않으므로 ECSS 5.5.6.a "Broadcast 최우선"을 실질
        # 위반하지 않는다.
        self._tc_starve_cnt = 0

        self.cycle = 0   # 디버깅/타이밍 검증용 사이클 카운터

    def tick(self):
        self.cycle += 1

        # ---- 0. 링크 제어 입력 반영 / 동기 PortReset ----
        self.link.link_en = self.i.link_en
        self.link.link_start = self.i.link_start
        # P1-6 (codex 리뷰): params.ENABLE_AUTOSTART 가 정의만 되어 있고 실제로는
        # 반영되지 않던 것을 수정. 파라미터가 0 이면 i_auto_start 핀이 1 이어도
        # AutoStart 기능 자체가 비활성화된다 (합성 시 파라미터로 기능 제거하는
        # RTL 의도와 일치).
        self.link.auto_start = self.i.auto_start and bool(self.params.ENABLE_AUTOSTART)
        if self.i.port_reset:
            self.link._enter(LinkState.ERROR_RESET)
        # DECISION-16 (시나리오 11): i_rst_n(active-low) 은 port_reset과 달리
        # 사용자 TX/RX FIFO 까지 함께 지운다 — 실제 FIFO 정리는 아래 §5 에서
        # (port_reset과 공유하는) ERROR_RESET 진입 처리 블록에 이어서 수행한다.
        if not self.i.rst_n:
            self.link._enter(LinkState.ERROR_RESET)

        # ---- 1. 수신 처리 (D-S 디코더는 상위 루프에서 set_lines 로 라인 연결됨) ----
        self.dec.tick()
        # DECISION-08 (수정됨): disconnect 판정은 이제 SpWDecoder 가 자체적으로
        # "첫 천이 이전에는 비활성화" 로 정확히 게이팅한다 (ECSS Figure 5-19 NOTE 1,
        # SpWDecoder.seen_any_transition 참조). 과거에는 여기서 상태(state)
        # 기반으로 근사했으나, 이는 한쪽만 재시작된 뒤 재시작 타이밍이 어긋나면
        # 서로의 재시작을 기다리는 동안 무신호 disconnect 오탐이 반복되는
        # 데드락을 유발했다 (편측 credit_error 주입 재연결 테스트로 실제 확인).
        self.link.disconnect = self.dec.disconnect
        self.link.parity_error = self.dec.parity_error

        esc_err_this_tick = False
        if self.dec.char_ready is not None:
            result = self.link.on_char(self.dec.char_ready)
            if result == "TIMECODE":
                self.net.on_timecode_rx(self.dec.char_ready.value)
            elif isinstance(result, Character):
                self.net.on_rx_char(result)
            esc_err_this_tick = self.link.esc_error

        # ---- 1.5. ERRATA-18: pending EEP 복구 삽입 (ECSS 5.5.8.4.a.2) ----
        # 레벨 신호 — RX FIFO(self.net)에 빈 자리가 나는 tick 까지 몇 번이든
        # 계속 시도한다. 여기서 쓰는 _eep_pending 값은 "이전 tick 까지의"
        # 값이다(이번 tick 의 §5 link.tick()/_enter() 가 아직 실행되기 전) —
        # RTL 의 r_eep_pending(FF, 1클럭 지연) 과 동일한 타이밍.
        if self.link._eep_pending and self.net.rx_free_space() > 0:
            self.net.on_rx_char(Character(CharKind.EEP))
            self.link._eep_pending = False

        # ---- 1.6. ERRATA-26: pending TX flush (끊긴 패킷의 미송신 잔여
        # 바이트를 다음 EOP/EEP까지 버림) ----
        # ⚠️ [초안 버그 수정] 처음엔 "터미네이터를 볼 때까지 무한정 대기"로
        # 짰다가, 에러 시점에 TX FIFO가 이미 비어있던 경우(끊긴 패킷의
        # 나머지가 실제로는 이미 다 나간 뒤였던 경우) 호스트가 그다음에
        # 넣는 완전히 새로운 패킷까지 "옛 패킷의 연속"으로 오인해서 계속
        # 버려버리는 회귀가 생겼다(시나리오 18/20 재현). 수정: flush는
        # "에러 시점에 이미 큐에 있던 것"만 처리 대상으로 삼는다 — 터미네
        # 이터를 못 찾은 채로 FIFO가 바닥나면(더 버릴 게 없으면) 거기서
        # 그냥 종료한다. 그 이후 호스트가 새로 넣는 건 무조건 새 데이터로
        # 취급한다(에러 시점 이후에 도착한 걸 "옛것"으로 볼 근거가 없음).
        if self.link._tx_flushing:
            if len(self.net.tx_fifo) == 0:
                self.link._tx_flushing = False
            else:
                discarded = self.net.pop_tx()
                if discarded is not None and discarded.kind in (CharKind.EOP, CharKind.EEP):
                    self.link._tx_flushing = False

        # ---- 2. Timecode 송신 요청 샘플 ----
        tc_val = self.net.sample_tick_in(self.i.tick_in, self.i.time_in)
        if tc_val is not None:
            # ERRATA-19: ECSS 5.5.9 — "Broadcast codes passed to the data link
            # layer by the network layer should be discarded unless the link
            # state machine is in the Run state." RUN이 아닐 때 도착한 tick_in은
            # 큐잉해 뒀다가 RUN 진입 후 지연 발송하면 안 되고 즉시 폐기해야 한다.
            if self.link.state == LinkState.RUN:
                self._tc_pending.append(tc_val)

        # ---- 3. RX FIFO 여유 공간 기반 FCT 요청 ----
        # DECISION-10: 여유 공간이 있다고 매 tick 무조건 FCT 를 요청하면, 이미 충분히
        # 크레딧을 부여한 뒤에도 계속 FCT 요청이 최우선순위를 차지해 정작 사용자
        # 데이터/Timecode 송신 기회를 영원히 빼앗는 문제가 발생한다 (self-test 로 확인).
        # -> "이미 부여한 크레딧(rx_credit_budget)"이 "부여 가능한 한도"보다 작을 때만
        #    추가로 FCT 를 요청하도록 제한한다.
        # ERRATA-18 인터록: _eep_pending 이 풀리기 전엔 새 credit 을 아예 요청하지
        # 않는다 — 안 그러면 파트너가 새 credit 으로 보낸 DATA 가 pending EEP 보다
        # 먼저 RX FIFO 에 들어가 순서가 역전된다(§9.6 참조).
        if self.link.state in (LinkState.CONNECTING, LinkState.RUN) and not self.link._eep_pending:
            grantable = min(self.net.rx_free_space(), SpWLink.MAX_CREDIT)
            self.link.req_fct = (self.link.rx_credit_budget + 8) <= grantable
        else:
            self.link.req_fct = False

        # ---- 4. 송신 문자 선택 및 encoder 전달 ----
        if self.enc.idle():
            next_ch = self._select_next_tx_char()
            if next_ch is not None:
                self.enc.send_char(next_ch)
                self.link.note_tx_char_sent(next_ch, is_independent_fct=self._last_char_was_independent_fct)
        self.enc.tick()

        # ---- 5. Link FSM ----
        self.link.esc_error = esc_err_this_tick
        self.link.tick()
        self.link.esc_error = False   # 1클럭 pulse
        self.link.protocol_violation = False   # 1클럭 pulse

        # P0-3/P0-4/P0-5 (codex 리뷰): ERROR_RESET 상태에서는 encoder/decoder의
        # 부분 문자 조립 상태, 진행 중이던 ESC 원자적 시퀀스(Null/Timecode 의
        # 두 번째 문자), 대기 중인 Timecode 요청을 모두 폐기한다. 이렇게 하지
        # 않으면: (1) reset 직전 ESC 를 보낸 상태에서 reset 이 걸려도 그 다음
        # 클럭에 남은 FCT/Timecode 문자가 그대로 송신되고, (2) reset 중 들어온
        # tick_in 이 ESC 비트를 encoder 큐에 밀어넣으며, (3) 재연결 후 이전 문자의
        # 나머지 비트가 다음 문자에 섞여 프레이밍이 깨질 수 있었다.
        # TX/RX 사용자 FIFO(self.net) 는 보존한다 — 사용자 인터페이스 사양에 따라
        # 별도 결정 사항으로 남겨둔다 (P0-3 권고 참고).
        if self.link.state == LinkState.ERROR_RESET:
            self.enc.reset()
            self.dec.reset_framing()
            self._esc_seq_continue = None
            self._tc_pending.clear()
            self._tc_starve_cnt = 0   # [DECISION-17 Option B] 굶주림 카운터도 함께 리셋
            # DECISION-16 (시나리오 11): i_rst_n 만 사용자 TX/RX FIFO 까지 지운다
            # (port_reset은 FIFO를 보존하는 것이 의도된 설계 — 시나리오 10 참조).
            if not self.i.rst_n:
                self.net.tx_fifo.clear()
                self.net.rx_fifo.clear()
                # ERRATA-18: RX FIFO 자체를 통째로 지웠으니 그 안에 있던
                # "미완성 패킷"도 같이 사라진다 — 이제 와서 EEP로 끝내줄
                # 대상이 없다. eep_pending 을 여기서도 클리어하지 않으면,
                # 다음 tick 에 방금 비운 빈 FIFO에 엉뚱한 EEP 가 혼자 꽂혀
                # 버린다 (RTL은 i_rst_n 이 모든 모듈의 물리적 async reset이라
                # r_eep_pending 도 같은 클럭에 함께 0 이 되므로 이 문제가 없다
                # — golden model 은 net 리셋을 소프트웨어로 흉내내는 구조라서
                # 여기서 명시적으로 맞춰줘야 한다).
                self.link._eep_pending = False
                # ERRATA-26: 같은 이유로 TX FIFO 도 통째로 지웠으니 "버릴
                # 잔여분"도 같이 사라진다. tx_flushing 을 안 지우면 다음
                # host push 를 엉뚱하게 계속 버리게 된다.
                self.link._tx_flushing = False

        self._prev_state = self.link.state

        # ---- 6. 사용자 핀 출력 ----
        self.ow_tx_ready = self.net.push_tx(self.i.tx_data9, bool(self.i.tx_valid))
        self.net.tick_rx_pin(bool(self.i.rx_ready))
        self.ow_rx_valid = self.net.rx_pin_valid
        self.ow_rx_data = self.net.rx_pin_data9

        self.ow_tick_out = self.net.tick_out
        self.ow_time_out = self.net.time_out
        self.net.tick_out = False

        self.ow_link_state = self.link.link_state_out
        self.ow_err_disconnect = self.link.err_disconnect
        self.ow_err_parity = self.link.err_parity
        self.ow_err_esc = self.link.err_esc
        self.ow_err_credit = self.link.err_credit
        self.ow_err_tx_invalid = self.net.invalid_tx_ctrl

    def _select_next_tx_char(self) -> Optional[Character]:
        # 진행 중인 ESC 원자적 시퀀스(Null 또는 Timecode)의 두 번째 문자를 최우선 완료
        if self._esc_seq_continue is not None:
            second = self._esc_seq_continue
            self._esc_seq_continue = None
            # ERRATA-23: 이 경로로 나가는 FCT는 Null 필러의 "동반 FCT"(credit
            # 미부여 대상)다. Timecode 의 경우 FCT가 아니므로 무관.
            self._last_char_was_independent_fct = False
            return second

        state = self.link.state

        # ECSS 5.5.6 Sending priority: Broadcast codes(최고) > FCTs > N-Chars > Nulls(최저)
        # ERRATA-10 (원문 재확인, codex 리뷰 재점검): 이전 버전은 FCT 관련
        # 우선순위를 Timecode(broadcast code)보다 먼저 검사했다. 원문 5.5.6.a는
        # "1.Broadcast codes, 2.FCTs, 3.N-Chars, 4.Nulls" 순서를 명시하므로
        # Timecode 를 최우선으로 옮긴다.

        # 우선순위 1: Timecode (ESC + TC, 원자적 쌍) — Broadcast code
        # P0-4 (codex 리뷰): 상태 조건이 없어 ERROR_RESET 등 비-RUN 상태에서도
        # tick_in 이 들어오면 ESC 비트가 encoder 로 실렸다. ECSS 5.5.7.7 은 Run
        # 상태에서만 broadcast code(Timecode 포함)를 Encoding Layer 로 전달하도록
        # 규정하므로 RUN 상태로 제한한다.
        #
        # [DECISION-17 Option B, 2026-09-13] scenario_24가 실측 확인한 문제:
        # 호스트가 tick_in을 물리적 최대 속도로 계속 재무장하면, 이 분기가
        # 매번 이겨서 아래 우선순위 2/3(FCT)이 영원히 기회를 못 받고 credit이
        # 고갈된 뒤 완전 정체에 빠진다 (credit_error 조차 안 뜸). ECSS 5.5.6.a는
        # Broadcast 최우선을 "절대 순서"로 명시하므로 라운드로빈(옵션 C)은 이
        # 조항 위반이 되어 채택 불가 — 대신 "다른 것도 보낼 준비가 된 상태에서"
        # TC_STARVE_THRESHOLD 회 연속으로 이겼을 때만 한 번 양보하는 안전장치를
        # 둔다. 정상적인(느린 주기의) Timecode 요청에서는 한 번 보내고 나면
        # _tc_pending이 비어 카운터가 자연히 0으로 돌아가므로 이 임계값에 절대
        # 도달하지 않는다 — 즉 정상 동작 시 이 분기는 기존과 완전히 동일하게
        # 작동하고, 병적 재무장 상황에서만 개입한다.
        tc_ready = (state == LinkState.RUN and bool(self._tc_pending))
        if tc_ready:
            other_ready = (
                (state in (LinkState.CONNECTING, LinkState.RUN) and self.link.req_initial_fct > 0
                    and not self.link._eep_pending)
                or (state in (LinkState.CONNECTING, LinkState.RUN) and self.link.req_fct)
                or (state == LinkState.RUN and self.link.tx_credit > 0
                    and not self.link._tx_flushing and self.net.peek_tx() is not None)
            )
            if other_ready and self._tc_starve_cnt >= self.TC_STARVE_THRESHOLD:
                self._tc_starve_cnt = 0
                tc_ready = False   # 이번 슬롯은 FCT/N-Char에 양보
            elif other_ready:
                self._tc_starve_cnt += 1
            else:
                self._tc_starve_cnt = 0   # 아무도 안 밀리는 정상 상황 — 카운터 리셋
        else:
            self._tc_starve_cnt = 0

        if tc_ready:
            self._esc_seq_continue = Character(CharKind.TIMECODE, self._tc_pending.popleft())
            return Character(CharKind.ESC)

        # 우선순위 2: Connecting 진입 직후 FCT 선송신 (ECSS 5.5.4.k)
        # ERRATA-18 인터록: eep_pending 이 안 풀렸으면 이 초기 FCT 도 보류한다.
        # 안 그러면 §5.2 req_fct 게이팅과 무관하게 이 경로로 파트너에게 새
        # credit 이 나가버려 인터록에 구멍이 생긴다 (Connecting 은 SentFCT
        # 성립 전까지 재시도하며 기다리므로 데드락이 아니라 지연일 뿐이다).
        if (state in (LinkState.CONNECTING, LinkState.RUN) and self.link.req_initial_fct > 0
                and not self.link._eep_pending):
            self.link.req_initial_fct -= 1
            self._last_char_was_independent_fct = True
            return Character(CharKind.FCT)

        # 우선순위 3: RX 여유공간 기반 FCT 요청
        if state in (LinkState.CONNECTING, LinkState.RUN) and self.link.req_fct:
            self.link.req_fct = False
            self._last_char_was_independent_fct = True
            return Character(CharKind.FCT)

        # 우선순위 4: 사용자 데이터 (Run 상태 + credit 필요) — N-Char
        # ERRATA-26: tx_flushing 동안은 실제 송신을 하지 않는다(플러시가 먼저
        # 끝나야 함) — 통상 재연결(1920+클럭)보다 flush(1클럭/바이트)가 훨씬
        # 빨라 겹칠 일이 거의 없지만, 방어적으로 명시한다.
        if state == LinkState.RUN and self.link.tx_credit > 0 and not self.link._tx_flushing:
            ch = self.net.peek_tx()
            if ch is not None:
                self.net.pop_tx()
                return ch

        # 우선순위 5: Null (ESC + FCT, idle filler) — Started 이상 상태에서 항상 유지
        # DECISION-04: 링크 유지를 위해 Started/Connecting/Run 어디서든
        # 보낼 것이 없으면 Null 을 계속 채워 넣는다.
        if state in (LinkState.STARTED, LinkState.CONNECTING, LinkState.RUN):
            self._esc_seq_continue = Character(CharKind.FCT)
            return Character(CharKind.ESC)

        return None


# ============================================================
# 결정 로그 (표준 해석 중 모호했던 항목) — HO_00_Common.md 섹션 9 에도 반영 예정
# ============================================================
#
# DECISION-01  제어문자 라인 심볼 코드
#   HO_00_Common.md 섹션 7.4 는 FCT/EOP/EEP/ESC 를 8비트 코드(0x01/0x02/0x06/0x07)로
#   표기했으나, 이는 섹션 7.1(사용자 TX 핀 9비트 포맷: bit[8]=1, 0x00=EOP, 0x01=EEP)과도
#   서로 다른 값이어서 두 표기가 내부적으로 불일치한다.
#   -> 실제 라인 심볼(직렬화 대상)은 ECSS 5.4.2 표준값인 2비트 코드
#      (FCT=00, EOP=01, EEP=10, ESC=11) 로 구현한다.
#      섹션 7.1의 9비트 값은 "사용자 핀 인터페이스" 표현으로만 사용한다.
#
# DECISION-02  패리티 상태 갱신 시점
#   수신측 parity 상태는 parity_error 발생 여부와 무관하게 "수신된 그대로" 매 문자마다
#   갱신한다 (에러 발생 시에도 계속 라인 값을 추종해야 다음 문자의 정합성 검사가 가능).
#
# DECISION-03  TX credit 차감 대상
#   HO_00 섹션 7.7 은 "credit 소진 시 송신 중단"만 언급하고 EOP/EEP 가 credit 을
#   소비하는지 명시하지 않음. GRSPW/실표준 관례에 따라 DATA/EOP/EEP 문자 송신마다
#   1씩 차감하는 것으로 결정.
#
# DECISION-04  Null idle filler 유지 범위
#   HO_00 섹션 6.1 은 "Started: Null 송신"만 명시하지만, DISCONNECT_TIMEOUT_NS=850ns가
#   매우 짧아 Connecting/Run 상태에서도 보낼 문자가 없으면 계속 Null을 채워야
#   상대측의 오탐 disconnect 를 방지할 수 있음.
#   -> Started/Connecting/Run 어디서든 idle 시 Null 을 계속 송신하도록 결정.
#
# DECISION-05  (수정됨 — ECSS 원문 확인 완료) Connecting -> Run 전이 조건
#   최초 초안에서는 HO_00/HO_01 원문("gotNull AND gotFCT AND gotNChar")을 그대로
#   해석하려다 순환 종속성 문제로 gotNChar 를 임의로 제외했었다.
#   ECSS-E-ST-50-12C Rev.1 원문(5.5.7.6.b.5, Figure 5-19)을 직접 확인한 결과, 실제
#   전이 조건은 "gotFCT AND Sent FCT" (최소 1개의 독립 FCT를 보냈고, 최소 1개를
#   받았을 때) 뿐이며, gotNull/gotNChar 는 이 조건에 전혀 포함되지 않는다.
#   오히려 표준은 Connecting 상태에서 N-Char(gotN-Char)를 수신하면 이를 프로토콜
#   위반으로 보고 ErrorReset 으로 되돌아가도록 규정한다(5.5.7.6.b.6) — 즉 HO_00/HO_01
#   원문의 "gotNChar 필요" 서술은 표준과 정반대다.
#   -> 참조 모델을 표준 원문에 맞춰 "gotFCT AND Sent FCT" 로 수정했고, Connecting
#      상태에서 N-Char 수신 시 ErrorReset 되도록 protocol_violation 처리를 추가했다.
#   -> HO_00_Common.md 섹션 7.3 (Connecting -> Run 조건) 자체를 수정해야 한다.
#
# DECISION-11  (신규 발견) ErrorReset/ErrorWait 타이머 배정이 뒤바뀌어 있었음  ***RTL 반영 필수***
#   HO_00_Common.md 섹션 7.3 은 "ErrorReset -> ErrorWait: 무조건(즉시)", "ErrorWait ->
#   Ready: 6.4us 경과" 로 기술한다. 그러나 ECSS-E-ST-50-12C Rev.1 원문(5.5.7.2/5.5.7.3,
#   Figure 5-19)은 반대다:
#     - ErrorReset 상태 자체가 6.4us 타이머를 가지며, 그 경과 + LinkDisabled 미설정
#       조건에서 ErrorWait 로 전이한다.
#     - ErrorWait 상태는 12.8us 타이머를 가지며, 그 경과 시 (조건 없이) Ready 로
#       전이한다.
#   -> 참조 모델을 표준 원문에 맞게 수정했다: ErrorReset 은 CNT_6US, ErrorWait 은
#      CNT_12US 를 사용한다. (Started/Connecting 은 원래도 12.8us 로 맞게 되어 있었음)
#   -> 이 정정은 disconnect 타임아웃(850ns) 과의 상대적 타이밍에는 영향이 없지만,
#      링크 초기화 전체 소요 시간(리셋 후 Run 도달까지)이 HO_00 서술과 달라지므로
#      HO_00_Common.md 섹션 7.2/7.3 과 HO_04(RTL) 의 타이머 카운터 배정을 반드시
#      함께 수정해야 한다.
#
# DECISION-12  (신규 발견) ErrorWait/Ready/Started 에서 "순수" FCT·N-Char 수신은 에러
#   ECSS 원문(Figure 5-19, 5.5.7.3~.5 각 상태의 leave 조건)에 따르면, ErrorWait/Ready/
#   Started 상태에서 (Null 의 일부가 아닌) 단독 FCT 나 N-Char 를 수신하면 프로토콜
#   위반으로 간주해 ErrorReset 으로 돌아간다. 최초 참조 모델 구현에는 이 검사가
#   빠져 있어 추가했다 (SpWLink.protocol_violation).
#
# DECISION-06  Outstanding credit 상한
#   표준/구현 관례상 최대 outstanding credit 은 56(=FCT 7개 분)으로 상한을 둠.
#   HO_00 문서에는 명시되어 있지 않음 (필요 시 파라미터화 가능).
#
# DECISION-07  Credit error 판정 방식
#   "credit_error" 판정 로직이 HO_00/HO_01 어디에도 구체적으로 정의되어 있지 않아,
#   참조 모델에서는 "내가 상대에게 부여한 수신 크레딧(rx_credit_budget, FCT 송신 시 +8,
#   N-Char/EOP/EEP 수신 시 -1)이 음수가 되면 credit_error" 로 정의했다.
#   실제 상대측 위반 시나리오(Scenario 3)로 self-test 검증함.
#
# DECISION-08  Disconnect 감지 적용 상태 범위  ***RTL 반영 필수***
#   HO_00 섹션 7.3 은 "어느 상태에서나 즉시 ErrorReset : disconnect(850ns 무신호)"라고
#   기술하지만, 이를 문자 그대로 ErrorReset/ErrorWait/Ready 상태까지 적용하면 문제가 생긴다:
#   이 구간에서는 애초에 어느 쪽도 문자를 전혀 송신하지 않으므로 D-S 라인에 변화가 없고,
#   DISCONNECT_TIMEOUT_NS(850ns, CNT_DISC=85클럭)가 ErrorWait 대기시간(6.4us, CNT_6US=640
#   클럭)보다 훨씬 짧아 ErrorWait 진입 후 85클럭 만에 "무신호 disconnect" 로 오판되어
#   ErrorReset 으로 되돌아가는 무한 루프(ErrorReset<->ErrorWait 진동)가 발생한다.
#   -> 참조 모델에서는 disconnect 판정을 Started/Connecting/Run 상태에서만 유효하도록
#      제한했다. 또한 Started 진입 시점에 disconnect 카운터를 리셋하여, ErrorWait 동안
#      누적된 "무신호 시간"이 Started 진입 직후의 오탐으로 이어지지 않도록 했다.
#   -> RTL(HO_04)에서도 동일하게, disconnect 타임아웃 카운터의 인에이블/리셋 조건에
#      "state >= Started" 를 반드시 포함해야 한다. HO_00_Common.md 결정 로그에 반영 요망.
#
# DECISION-09  D-S 인코딩 수식 오류 정정  ***중요, RTL 반영 필수***
#   HO_00_Common.md 섹션 7.5 는 "Strobe_new = Data_prev XOR Strobe_prev XOR Data_curr" 로
#   기술하지만, 이 식을 그대로 대입하면 XOR(Data,Strobe) 값이 "토글"이 아니라 "불변"
#   임을 대수적으로 확인할 수 있다:
#     XOR(D(n),S(n)) = D(n) XOR (D(n-1) XOR S(n-1) XOR D(n)) = D(n-1) XOR S(n-1)
#     -> 이전 값과 동일 (토글되지 않음)
#   D-S 인코딩의 핵심 불변식은 "XOR(Data,Strobe) 가 매 비트마다 반드시 토글"되어야
#   수신측이 비트레이트 정보 없이 라인 천이만으로 self-clocking 복원이 가능하다는 것이다.
#   실제로 원문 수식을 그대로 구현했을 때 두 노드가 Started 상태 진입 후 약 15비트
#   전송 시점에서 parity_error/esc_error 가 발생하며 초기화 루프에 빠지는 것을
#   시뮬레이션으로 확인했다 (프레이밍 동기가 깨짐).
#   -> 참조 모델에서는 표준 SpaceWire D-S 인코딩 공식으로 정정했다:
#        S(n) = NOT( D(n) XOR D(n-1) XOR S(n-1) )
#      Data 라인은 원본 비트값을 그대로 전달하므로 수신측은 D/S 라인 천이 검출 시점의
#      Data 값을 그대로 비트로 취한다 (별도 XOR 복호 불필요).
#   -> 이 정정은 RTL(HO_04)의 spw_enc.sv D-S 인코더/디코더 설계에 반드시 반영되어야
#      하며, HO_00_Common.md 섹션 7.5 자체도 이 결정 로그를 참고해 수정이 필요하다.
#
# DECISION-13  9비트 TX 핀 인터페이스 — 정의되지 않은 제어 코드 처리 (P1-7, 사용자 결정)
#   HO_00 섹션 7.1 은 bit[8]=1 일 때 하위 8비트 중 0x00=EOP, 0x01=EEP 두 값만
#   정의하고 나머지(0x02~0xFF, 즉 9비트 값으로 0x102~0x1FF)는 언급이 없었다.
#   최초 참조 모델 구현은 "0x00 이 아니면 전부 EEP" 로 조용히 흡수했으나
#   (codex 리뷰 P1-7), 이는 ECSS 표준과 무관한 이 프로젝트 고유의 사용자 핀
#   인터페이스 설계 문제이며 표준 위반이 아니다.
#   -> 사용자 결정: bit[7:2] 는 예약(reserved=0) 비트로 정의하고, 정확히
#      0x100(EOP)/0x101(EEP) 두 값만 유효하다. 그 외 bit[8]=1 인 나머지 전부
#      (0x102~0x1FF, bit[7:2] 가 0 인 0x102/0x103 포함)는 상위 로직의 버그
#      신호일 수 있으므로 조용히 흡수하지 않고 큐잉을 거부하며 1클럭 pulse
#      오류 신호(ow_err_tx_invalid)를 낸다.
#   -> 이 신호는 ECSS 표준 신호가 아니라 이 프로젝트가 정의하는 사용자 인터페이스
#      전용 오류이므로, HO_00 핀 목록/HO_04 top 포트 목록에 ow_err_tx_invalid
#      추가가 필요하다.
