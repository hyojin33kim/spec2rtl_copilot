// =============================================================================
// spw_datalink — SpaceWire Data Link Layer (Link State FSM, Flow Control, ESC)
// ECSS-E-ST-50-12C Rev.1 §5.5 / HO_04_RTL_Design_v6.md / spw_datalink_rtl_guide_v5.md
//
// 근거: spw_ref_model.py SpWLink / SpWNode._esc_seq_continue / SpWNode._tc_pending
// 기준 문서: spw_datalink_rtl_guide_v5.md (포트명/구현 상세 우선)
//
// 상위 배치: spw_top
//   spw_phy → spw_enc → spw_datalink(본 모듈) → spw_network
//
// 착수 시점(2026-08-25) 기준 확정 사항:
//   - ERRATA-19: i_tick_in은 r_state==ST_RUN일 때만 래치, RUN 이전 도착은 폐기
//     (golden model의 deque 큐잉이 버그였음 — 본 RTL 구현이 원래 정확)
//   - DECISION-14(auto_start 비대칭 콜드부트 필요)는 ECSS 5.5.7.4.a.1 원문으로 최종 확정
//     ("Ready 상태에서 Transmit Enable 비활성화" — Null 포함 아무것도 안 보냄)
//   - ERRATA-20(구 ERRATA-17, r_tx_credit 상태 게이트): Connecting 상태도 포함해
//     FCT 수신 시 credit 증가하도록 반영 (§5.1)
//   - 미결 #7(credit 카운터 동시 이벤트 레이스): §5.1/§5.2 구현 시 반드시 시뮬레이션
//     으로 w_got_fct/w_send_nchar 동시 발생 케이스 검증할 것 (아직 미해결, 선택 A/B 미확정)
//
// 미해결 항목 (구현 진행하며 순차 처리, guide §10 참조):
//   #1 FCT/N-Char starvation — [정정, 2026-09-14] "종결(현행 A 유지)"이라던
//      이전 결론은 실측(golden model scenario_24, tb_decision17_tc_starvation.sv)
//      으로 틀린 것으로 확인됨 -- 물리적 최대 tick_in 재무장 시 완전 정체 재현.
//      DECISION-17 v5에서 Option B(TC_STARVE_THRESHOLD=8 throttle)로 해결·
//      resolved 완료(§8.3 r_tc_starve_cnt 참조).
//   #2 enc_ready 결선 — 종결(A: datalink 내부 완결)
//   #3 credit_error 구현 — 본 파일에서 구현
//   #4 i_tick_in RUN 이전 도착 — 해소(discard가 정답, ERRATA-19)
//   #5 ERRATA-6 gotNull 근사 — [정정, 2026-09-14] "종결(상태 기반 근사로
//      충분)"이라던 이전 결론도 근거 없이 내려진 것으로 확인됨(DECISION-18).
//      실측(골든모델에 dec.parity_error 직접 주입)으로 확인: 종전 구현은
//      parity/ESC error를 gotNull 여부와 무관하게 무조건 즉시 ErrorReset
//      사유로 취급해, ECSS 5.4.7.a/5.4.9.b("gotNull 이후에만 활성화")를
//      실제로 위반하고 있었다. DECISION-18 v2에서 Option B(진짜
//      r_gotnull_latch 래치 도입, ErrorReset 진입 시에만 clear)로 해결·
//      resolved 완료(§3.2 w_immediate_error 참조).
//   #6 auto_start 데드락 — 최종 해소(DECISION-14 원문 확정)
//   #7 credit 레이스 — 종결(DECISION-17과 무관, ERRATA-25에서 이미 해결 —
//      §5.1 r_tx_credit 선택 B(명시적 if/else if) 참조)
//
// [v2, 2026-08-31, PATCH-1] ESC/Null 두 번째 문자(FCT/Timecode) 완성 핸드셰이크
//   버그 수정: §8.3 최우선 분기(r_esc_pending)의 w_send_second 가 i_enc_ready
//   와 handshake 되지 않아, encoder busy 중 두 번째 문자가 유실되고 다음 ESC가
//   중복 송신되던 버그. tb_esc_enc_handshake.sv(spw_enc self-loopback 단위
//   테스트)와 tb_spw_top_loopback.sv(2노드 통합)로 재현·확정 후 수정.
//   credit(r_rx_credit)/SentFCT(r_sent_fct) 로직은 이미 w_send_fct 에만
//   연결되어 있고 w_send_second 와 무관함을 확인했으므로(ERRATA-11급 이중
//   계산 없음), 이 수정은 부작용 없는 완결된 수정이다. 상세 근거는 아래
//   §8.3 PATCH-1 주석 참조.
// =============================================================================

module spw_datalink #(
    parameter int RX_FIFO_DEPTH = 128,
    parameter int MAX_CREDIT    = 56,    // 7 x 8 (ECSS 5.5.4)
    parameter int CNT_6US       = 640,   // @ 100MHz
    parameter int CNT_12US      = 1280   // @ 100MHz
) (
    // ── Clock / Reset ────────────────────────────────────────────
    input  logic        i_clk,
    input  logic        i_rst_n,          // Active-Low Async (전체 초기화, DECISION-16)

    // ── MIB 제어 ─────────────────────────────────────────────────
    input  logic        i_link_en,        // LinkEnable
    input  logic        i_link_start,     // LinkStart
    input  logic        i_auto_start,     // AutoStart
    input  logic        i_port_reset,     // PortReset (동기, 프로토콜 상태만, DECISION-16)

    // ── Encoding Layer → DataLink (수신 문자) ───────────────────
    // 주의: spw_enc가 10비트 심볼을 완성한 다음 클럭에 1클럭 pulse
    input  logic        i_rx_char_valid,  // 수신 문자 완성 펄스
    input  logic [8:0]  i_rx_char,        // 수신 문자 본체 [8]=flag(ctrl/data)
    input  logic        i_parity_err,     // 패리티 에러 펄스 (i_rx_char_valid 와 동시 가능)
    input  logic        i_disconnect,     // Disconnect 에러 펄스

    // ── DataLink → Encoding Layer (송신 문자) ───────────────────
    output logic        ow_tx_char_valid, // 송신 문자 유효 (Encoder에 실어줘라)
    output logic [8:0]  ow_tx_char,       // 송신할 문자 [8]=flag
    input  logic        i_enc_ready,      // Encoder idle — 다음 문자 수용 가능 (미결 #2, 해소)
    output logic        ow_enc_reset,     // Encoder 강제 리셋 (ErrorReset 진입 시 1클럭 pulse)

    // ── Network Layer TX ─────────────────────────────────────────
    input  logic [8:0]  i_nchar_data,     // 송신 N-Char (TX FIFO peek)
    input  logic        i_nchar_valid,    // TX FIFO not empty
    output logic        ow_nchar_ready,   // TX FIFO pop 신호

    // ── Network Layer RX ─────────────────────────────────────────
    output logic [8:0]  ow_rx_char_data,  // 수신 N-Char
    output logic        ow_rx_char_valid, // 수신 N-Char 유효 펄스
    output logic        ow_rx_char_ctrl,  // 1=EOP/EEP, 0=DATA

    // ── FCT 조건 A: spw_network 제공 ─────────────────────────────
    // 값 = RX_FIFO_DEPTH - rx_fifo 점유량, 폭 = $clog2(RX_FIFO_DEPTH+1) 비트
    // 비교(>=8, <=48) 로직은 본 모듈 내부 완결, spw_network는 raw 값만 제공
    input  logic [$clog2(RX_FIFO_DEPTH+1)-1:0] i_rx_free_space,

    // ── Timecode ──────────────────────────────────────────────────
    // i_tick_in은 spw_network에서 rising edge 감지 후 1클럭 펄스로 전달
    input  logic        i_tick_in,        // Timecode 송신 트리거 (미결 #4, 해소: RUN 아니면 discard)
    input  logic [7:0]  i_time_in,        // flag[7:6] + counter[5:0]
    output logic        ow_tick_out,      // 수신 Timecode 완성 펄스
    output logic [7:0]  ow_time_out,      // 수신 Timecode 값

    // ── 상태 출력 ─────────────────────────────────────────────────
    output logic [2:0]  ow_link_state,    // 0:ER 1:EW 2:RD 3:ST 4:CN 5:RN
    output logic        ow_err_disconnect,
    output logic        ow_err_parity,
    output logic        ow_err_esc,
    output logic        ow_err_credit,    // 미결 #3, 본 파일에서 구현
    output logic        ow_err_tx_invalid // DECISION-13 — 잘못된 TX 제어 코드
);

    // =========================================================================
    // 3.1 Link State 인코딩
    // =========================================================================
    localparam logic [2:0]
        ST_ERROR_RESET = 3'd0,
        ST_ERROR_WAIT  = 3'd1,
        ST_READY       = 3'd2,
        ST_STARTED     = 3'd3,
        ST_CONNECTING  = 3'd4,
        ST_RUN         = 3'd5;

    // =========================================================================
    // 내부 레지스터 (§4)
    // =========================================================================
    logic [2:0]  r_state;
    logic [10:0] r_timer_cnt;
    logic        r_timer_expired;

    logic [5:0]  r_tx_credit;             // 0~56
    logic [5:0]  r_rx_credit;             // 0~56

    logic        r_null_seen;             // auto_start 조건
    logic        r_gotnull_latch;         // DECISION-18 Option B: 진짜 gotNull 래치 (ErrorReset에서만 clear)
    logic        r_got_fct;               // Connecting→Run 조건
    logic        r_sent_fct;              // SentFCT 래치 (Connecting)
    logic [2:0]  r_req_initial_fct;       // min(RX_FIFO_DEPTH/8, 7) 카운트다운

    logic        r_seen_any_transition;   // D/S 최초 천이 감지 (disconnect 게이트)

    logic        r_err_disconnect;
    logic        r_err_parity;
    logic        r_err_esc;
    logic        r_err_credit;            // 미결 #3

    logic        r_rx_pending_esc;        // 수신 ESC FSM: ESC 후 다음 문자 대기
    logic        r_esc_pending;           // 송신 ESC 원자적 시퀀스 진행 중
    logic        r_esc_kind;              // 0=Null용FCT, 1=Timecode
    logic [7:0]  r_tc_value;              // 송신 대기 Timecode 값
    logic        r_tc_pending;            // 래치된 Timecode 유효 플래그

    // ERRATA-18 (EEP 자동 복구, ECSS 5.5.8.4.a.2):
    logic        r_rx_pkt_in_progress;    // RUN 중 DATA 수신 시작~EOP/EEP 이전까지 1
    logic        r_eep_pending;           // 에러 진입 시 미완성 패킷이 있었으면 무장,
                                           // RX FIFO에 EEP 를 실제로 써넣을 때까지 유지
                                           // (레벨 신호 — 몇 클럭이 걸리든 계속 대기)

    // ERRATA-26 (TX FIFO 잔여 바이트 leak 방지, E1과 대칭되는 TX측):
    logic        r_tx_pkt_in_progress;    // RUN 중 DATA 송신 시작~EOP/EEP 이전까지 1
    logic        r_tx_flushing;           // 에러 진입 시 미송신 패킷이 있었으면 무장,
                                           // 다음 EOP/EEP(또는 FIFO 바닥)까지 계속
                                           // pop-and-discard (레벨 신호)

    // DECISION-17 Option B (golden model spw_ref_model.py::SpWNode._tc_starve_cnt
    // 이식, 2026-09-14): Timecode가 "다른 것(FCT/N-Char)도 보낼 준비된 상태"에서
    // TC_STARVE_THRESHOLD 회 연속으로 이기면 그다음 한 번은 양보한다. 정상적인
    // (느린 주기의) Timecode 요청에서는 r_tc_pending이 곧 소비돼 0이 되므로 이
    // 카운터가 임계값에 도달하지 않는다 -- ECSS 5.5.6.a "Broadcast 최우선"을
    // 정상 동작 궤적에서 그대로 지킨다. scenario_24(golden model)가 실측한
    // "물리적 최대 tick_in 재무장 시 완전 정체"를 막기 위한 안전장치.
    logic [3:0]  r_tc_starve_cnt;

    // =========================================================================
    // 내부 comb 신호 (다음 단계에서 §3.3/§5~§9 구현 시 채움)
    // =========================================================================
    logic [2:0]  w_next_state;
    logic        w_timer_sync_rst;
    logic        w_credit_sync_rst;
    logic        w_entering_error_reset;

    logic        w_got_null, w_got_fct, w_got_nchar, w_got_timecode, w_esc_error;
    logic        w_tx_credit_err, w_rx_credit_err, w_credit_err;
    logic        w_fct_send_ok;
    logic        w_eep_write_now;         // ERRATA-18: 이 클럭에 pending EEP 를 실제로 씀
    logic        w_send_esc, w_send_fct, w_send_nchar, w_send_second, w_send_timecode_esc;
    logic        w_next_esc_kind;
    logic        w_tc_other_ready;        // DECISION-17 Option B: FCT/N-Char 중 하나라도 보낼 준비됐는지
    logic        w_tc_starve_yield;       // DECISION-17 Option B: 이번 슬롯은 Timecode가 양보
    logic [8:0]  w_tx_char;
    logic        w_valid_disconnect;
    logic        w_protocol_violation;

    // -------------------------------------------------------------------------
    // (§9.2 는 이번 단계에서 구현 완료 — 스텁 제거됨)
    // -------------------------------------------------------------------------

    // =========================================================================
    // §3.2 공통 즉시 ErrorReset 조건
    // =========================================================================
    // 참조 모델 SpWLink.tick() 의 immediate_error 대응.
    // 주의: golden model 의 immediate_error 목록에는 disconnect/parity_error/
    // esc_error/protocol_violation/(RUN&&credit_error) 도 포함되지만, 그 신호들은
    // §5~§9 (credit/ESC/protocol_violation)에서 정의된다. 이 섹션(§3.3)에서는
    // 우선 !i_link_en 만 즉시 조건으로 다루고, 나머지 즉시 에러는 §3.3 상태별
    // 전이 표에 개별 행으로 반영되어 있으므로 w_next_state comb 에서 함께 합류된다.
    // [DECISION-18 Option B, 2026-09-14] ECSS 5.4.7.a/5.4.9.b: parity/ESC
    // error 검출은 gotNull이 assert된 동안에만 활성화돼야 한다. 이전에는
    // r_gotnull_latch 없이 i_parity_err/w_esc_error를 무조건 즉시 ErrorReset
    // 사유로 취급했다 -- tb_decision18_gotnull_gate.sv로 실측 확인: gotNull
    // 이전(콜드부트 직후 ErrorWait 등)의 스퓨리어스 parity/ESC 에러가 표준상
    // 무시돼야 하는데 즉시 ErrorReset으로 튕겼다. r_gotnull_latch로 게이팅
    // 추가 -- gotNull 이후(첫 Null 수신~다음 ErrorReset 전까지)에는 기존과
    // 완전히 동일하게 동작한다(회귀 없음, tb_err_reset.sv 갱신 참조).
    logic w_immediate_error;
    assign w_immediate_error = (!i_link_en) | i_disconnect
                              | (i_parity_err & r_gotnull_latch)
                              | (w_esc_error  & r_gotnull_latch)
                              | w_protocol_violation
                              | (r_state == ST_RUN & w_credit_err);
    // ※ w_esc_error/w_protocol_violation/w_credit_err 는 각각 §6/§9.3/§5.1 에서
    //   정의될 예정. 지금은 §5~§9 미구현이라 항상 0으로 뜨므로, 이 FSM 단독으로는
    //   !i_link_en 조건만 실제로 동작한다 (다음 단계에서 각 섹션 구현 시 자동 합류).

    // =========================================================================
    // §3.3 상태 전이 comb (w_next_state)
    // =========================================================================
    // 우선순위: (1) i_port_reset 동기 리셋 → 즉시 ErrorReset
    //           (2) w_immediate_error → 즉시 ErrorReset (그 상태에 계속 머묾)
    //           (3) 상태별 정상/에러 전이 조건 (guide §3.3 표)
    always_comb begin
        w_next_state = r_state;  // 기본값: 유지

        if (i_port_reset) begin
            w_next_state = ST_ERROR_RESET;
        end else if (w_immediate_error) begin
            w_next_state = ST_ERROR_RESET;
        end else begin
            unique case (r_state)
                ST_ERROR_RESET: begin
                    // ERRATA-1: ErrorReset은 CNT_6US
                    if (r_timer_cnt >= CNT_6US[10:0]) begin
                        w_next_state = ST_ERROR_WAIT;
                    end
                end

                ST_ERROR_WAIT: begin
                    // ERRATA-3: 순수 FCT 또는 N-Char 수신 시 즉시 ErrorReset
                    if (w_got_fct || w_got_nchar) begin
                        w_next_state = ST_ERROR_RESET;
                    end else if (r_timer_cnt >= CNT_12US[10:0]) begin
                        // ERRATA-1: ErrorWait은 CNT_12US
                        w_next_state = ST_READY;
                    end
                end

                ST_READY: begin
                    // ERRATA-3: Ready 에서도 순수 FCT/N-Char 수신 시 ErrorReset
                    if (w_got_fct || w_got_nchar) begin
                        w_next_state = ST_ERROR_RESET;
                    end else if (i_link_start || (i_auto_start && r_null_seen)) begin
                        // gotNull 선수신 필수 [P3-1] — auto_start 만으로는 부족
                        w_next_state = ST_STARTED;
                    end
                end

                ST_STARTED: begin
                    // ERRATA-3: 순수 FCT/N-Char 수신 시 ErrorReset (Null 완성 전)
                    if (w_got_fct || w_got_nchar) begin
                        w_next_state = ST_ERROR_RESET;
                    end else if (w_got_null) begin
                        // 수신 ESC+FCT 파싱 완료 (r_rx_pending_esc FSM 결과)
                        w_next_state = ST_CONNECTING;
                    end else if (r_timer_cnt >= CNT_12US[10:0]) begin
                        w_next_state = ST_ERROR_RESET;  // gotNull 없이 타임아웃
                    end
                end

                ST_CONNECTING: begin
                    // ERRATA-2: N-Char(DATA/EOP/EEP) 수신은 여기서 protocol violation
                    if (w_got_nchar) begin
                        w_next_state = ST_ERROR_RESET;
                    end else if ((r_got_fct || w_got_fct) && r_sent_fct) begin
                        // "gotFCT AND SentFCT" 만 Run 진입 조건 (gotNull/gotNChar 불포함).
                        // r_got_fct(래치) 뿐 아니라 같은 클럭에 막 도착한 w_got_fct 도
                        // 즉시 반영 — golden model 이 on_char()(수신 처리)를 tick()
                        // (전이 판단)보다 먼저 같은 클럭에서 실행하는 것과 동치.
                        w_next_state = ST_RUN;
                    end else if (r_timer_cnt >= CNT_12US[10:0]) begin
                        w_next_state = ST_ERROR_RESET;  // 조건 미달 타임아웃
                    end
                end

                ST_RUN: begin
                    // [DECISION-18 v5, 2026-09-14] 미결 #5 해소: "r_null_seen 기반
                    // 상태 근사로 충분하다"는 예전 결론은 실측 결과 틀린 것으로
                    // 확인됐다(진짜 gotNull 게이팅은 §3.2 w_immediate_error의
                    // r_gotnull_latch가 전담 — 그쪽 참조). 이 case 안에는 추가로
                    // 판단할 게 없다 — disconnect/parity/esc/credit_err 전부
                    // w_immediate_error 가 이미 커버한다.
                end

                default: w_next_state = ST_ERROR_RESET;
            endcase
        end
    end

    assign w_entering_error_reset = (w_next_state == ST_ERROR_RESET)
                                   & (r_state     != ST_ERROR_RESET);

    // =========================================================================
    // r_state FF (async reset only)
    // =========================================================================
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state <= ST_ERROR_RESET;
        end else begin
            r_state <= w_next_state;
        end
    end

    // =========================================================================
    // §3.4 타이머 (r_timer_cnt, r_timer_expired)
    // =========================================================================
    // 상태가 바뀌면 타이머를 0부터 새로 계수(sync reset).
    // 상태가 유지되더라도 w_immediate_error(또는 port_reset)로 ErrorReset에
    // "붙들려" 있는 동안에는 진행하지 않는다 — golden model SpWLink.tick()의
    // immediate_error 분기가 timer += 1 자체를 건너뛰는 것과 동일한 동작.
    // (이게 없으면 !i_link_en 이 오래 지속되다 해제되는 순간 타이머가 이미
    //  CNT_6US 를 넘겨 즉시 ErrorWait 로 튀는 버그가 생김.)
    assign w_timer_sync_rst = (w_next_state != r_state);
    logic w_timer_hold;
    assign w_timer_hold = (r_state == ST_ERROR_RESET) && (i_port_reset || w_immediate_error);

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_timer_cnt <= 11'd0;
        end else begin
            if (w_timer_sync_rst) begin
                r_timer_cnt <= 11'd0;
            end else if (!w_timer_hold) begin
                r_timer_cnt <= r_timer_cnt + 11'd1;
            end
            // w_timer_hold 인 동안은 카운트 정지 (golden model 과 동일)
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_timer_expired <= 1'b0;
        end else if (w_timer_sync_rst) begin
            r_timer_expired <= 1'b0;
        end else begin
            unique case (r_state)
                ST_ERROR_RESET: r_timer_expired <= (r_timer_cnt >= CNT_6US[10:0]);
                ST_ERROR_WAIT,
                ST_STARTED,
                ST_CONNECTING: r_timer_expired <= (r_timer_cnt >= CNT_12US[10:0]);
                default:       r_timer_expired <= 1'b0;
            endcase
        end
    end

    // =========================================================================
    // §3.5 Connecting → Run 전이 보조 래치 (r_got_fct, r_sent_fct)
    // =========================================================================
    // golden model SpWLink._enter(): 상태 전이마다 _fct_seen(=r_got_fct) 은 항상
    // 클리어, _fct_sent_in_connecting(=r_sent_fct) 은 CONNECTING 진입 시에만
    // False 로 초기화. w_send_fct/w_got_fct 는 각각 §8/§6 에서 정의된다.
    logic w_entering_connecting;
    assign w_entering_connecting = (w_next_state == ST_CONNECTING) && (r_state != ST_CONNECTING);

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_got_fct <= 1'b0;
        end else if (w_next_state != r_state) begin
            // 모든 상태 전이(진입 포함)에서 클리어 — Connecting 진입 후 새로
            // 수신하는 FCT만 유효해야 함 (§3.5)
            r_got_fct <= 1'b0;
        end else if (r_state == ST_CONNECTING && w_got_fct) begin
            r_got_fct <= 1'b1;
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_sent_fct <= 1'b0;
        end else if (w_entering_connecting) begin
            r_sent_fct <= 1'b0;
        end else if (r_state == ST_CONNECTING && w_send_fct) begin
            r_sent_fct <= 1'b1;
        end
    end

    // =========================================================================
    // r_null_seen (auto_start 조건 — Ready 이후 Null 수신 이력)
    // =========================================================================
    // golden model: CONNECTING 진입 시에는 유지(Started 에서 이미 달성), 그 외
    // 모든 전이에서는 클리어.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_null_seen <= 1'b0;
        end else if (w_next_state != r_state) begin
            if (w_next_state == ST_CONNECTING) begin
                // 유지 + 같은 클럭에 뜬 w_got_null(Started→Connecting을 유발한
                // 바로 그 이벤트)도 놓치지 않고 반영
                r_null_seen <= r_null_seen | w_got_null;
            end else begin
                r_null_seen <= 1'b0;
            end
        end else if (w_got_null) begin
            r_null_seen <= 1'b1;
        end
    end

    // =========================================================================
    // r_gotnull_latch (DECISION-18 Option B, 2026-09-14)
    // =========================================================================
    // ECSS 5.4.6.b/d + 5.5.7.2.a.2/NOTE: gotNull은 "Receive Enable이
    // de-assert될 때만" 클리어된다 -- ErrorReset 진입 시점(RX Enable
    // de-assert)에만 일어나고, 그 외 모든 상태 전이(RUN 진입 포함)에서는
    // 유지돼야 한다. 위 r_null_seen은 Started->Connecting 전이 판정용 좁은
    // 목적의 플래그라 Connecting이 아닌 모든 전이(RUN 포함!)에서 클리어되므로
    // 이 용도로 재사용할 수 없다 -- 별도 latch가 필요하다(golden model
    // spw_ref_model.py의 SpWLink._gotnull_latch와 동일).
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_gotnull_latch <= 1'b0;
        end else if (w_entering_error_reset) begin
            r_gotnull_latch <= 1'b0;
        end else if (w_got_null) begin
            r_gotnull_latch <= 1'b1;
        end
    end

    // =========================================================================
    // ow_link_state 출력
    // =========================================================================
    assign ow_link_state = r_state;

    // =========================================================================
    // §6 수신 ESC 처리 FSM + §9.3 protocol violation + §9.5 ESC 수신 에러
    // =========================================================================
    // spw_enc.sv 실제 9비트 문자 포맷 기준 (guide §6 원문의 i_rx_char[8:7] 케이스는
    // spw_enc 포맷과 불일치 — flag는 [8] 하나, code는 [1:0]에 있음. 아래는 그 실제
    // 포맷대로 재작성):
    //   i_rx_char[8]   = flag (1=control, 0=data)
    //   i_rx_char[1:0] = control code, FCT=00 EOP=10 EEP=01 ESC=11 (spw_enc.sv 헤더/
    //                    ERRATA-7 근거)
    //
    // 참조 모델 SpWLink.on_char() 대응. 순서 중요:
    //   1) r_rx_pending_esc=1 이면 이번 문자가 ESC 의 두 번째 문자
    //   2) 그 외, 이번 문자 자체가 ESC 이면 pending 진입 (FF 에서 처리, 여기선 판정만)
    //   3) 그 외에는 상태별 protocol_violation 검사 후 FCT/N-Char 판정
    logic w_is_ctrl, w_is_esc, w_is_fct, w_is_nchar_ctrl;
    assign w_is_ctrl       = i_rx_char[8];
    assign w_is_esc        = w_is_ctrl && (i_rx_char[1:0] == 2'b11);
    assign w_is_fct        = w_is_ctrl && (i_rx_char[1:0] == 2'b00);
    assign w_is_nchar_ctrl = w_is_ctrl && (i_rx_char[1:0] == 2'b10 || i_rx_char[1:0] == 2'b01); // EOP/EEP

    always_comb begin
        w_got_null           = 1'b0;
        w_got_fct             = 1'b0;
        w_got_nchar           = 1'b0;
        w_got_timecode        = 1'b0;
        w_esc_error           = 1'b0;
        w_protocol_violation  = 1'b0;

        if (i_rx_char_valid) begin
            if (r_rx_pending_esc) begin
                // ── ESC 의 두 번째 문자 ────────────────────────────
                if (w_is_fct) begin
                    w_got_null = 1'b1;              // ESC+FCT = Null 완성
                end else if (!w_is_ctrl) begin
                    w_got_timecode = 1'b1;           // ESC+DATA = Timecode 완성
                end else begin
                    w_esc_error = 1'b1;              // ESC+ (EOP/EEP/ESC) = 표준 위반
                end
                // Null/Timecode 자체는 protocol_violation 대상이 아님(참조 모델과 동일 —
                // on_char() 의 protocol_violation 검사는 pending_esc 분기 밖에서만 수행됨)

            end else if (w_is_esc) begin
                // ESC 시작 — 판정은 다음 문자까지 보류 (r_rx_pending_esc FF 에서 SET)

            end else begin
                // ── 첫 번째 문자 (ESC 아님) ────────────────────────
                // ECSS 5.5.7.2/.3/.4/.5: ErrorReset/ErrorWait/Ready/Started 에서
                // 순수 FCT 또는 N-Char(DATA/EOP/EEP) 수신 시 protocol_violation.
                // ECSS 5.5.7.6: Connecting 에서는 N-Char(DATA/EOP/EEP) 만 위반
                // (FCT 수신은 gotFCT 조건 자체이므로 정상).
                if (r_state == ST_ERROR_RESET || r_state == ST_ERROR_WAIT
                        || r_state == ST_READY || r_state == ST_STARTED) begin
                    if (w_is_fct || !w_is_ctrl || w_is_nchar_ctrl) begin
                        w_protocol_violation = 1'b1;
                    end
                end else if (r_state == ST_CONNECTING) begin
                    if (!w_is_ctrl || w_is_nchar_ctrl) begin
                        w_protocol_violation = 1'b1;   // N-Char만 위반, FCT는 정상(gotFCT)
                    end else if (w_is_fct) begin
                        w_got_fct = 1'b1;
                    end
                end else begin
                    // ST_RUN (그 외 상태는 이 분기에 도달하지 않음)
                    if (w_is_fct) begin
                        w_got_fct = 1'b1;
                    end else begin
                        w_got_nchar = 1'b1;             // DATA 또는 EOP/EEP
                    end
                end
            end
        end
    end

    // ── FF: r_rx_pending_esc ─────────────────────────────────────
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_rx_pending_esc <= 1'b0;
        end else if (w_entering_error_reset) begin
            r_rx_pending_esc <= 1'b0;           // ErrorReset 진입 시 강제 clear (§9.1)
        end else if (i_rx_char_valid) begin
            if (!r_rx_pending_esc && w_is_esc) begin
                r_rx_pending_esc <= 1'b1;       // ESC 수신 → pending
            end else begin
                r_rx_pending_esc <= 1'b0;       // 두 번째 문자 수신 완료(또는 최초부터 비ESC)
            end
        end
    end

    // ── Timecode 값 추출 (§6, w_got_timecode=1 인 클럭에 즉시 출력) ──
    assign ow_tick_out  = w_got_timecode;
    assign ow_time_out  = i_rx_char[7:0];

    // =========================================================================
    // ERRATA-18  EEP 자동 복구 (ECSS 5.5.8.4.a.2)
    // =========================================================================
    // r_rx_pkt_in_progress: RUN 중 실제 DATA(비제어 N-Char) 수신을 시작했고
    // 아직 EOP/EEP 로 정상 종료되지 않았는지 추적. w_entering_error_reset 시
    // 그 값을 r_eep_pending 으로 "승계"한 뒤 자신은 클리어된다.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_rx_pkt_in_progress <= 1'b0;
        end else if (w_entering_error_reset) begin
            r_rx_pkt_in_progress <= 1'b0;
        end else if (w_got_nchar && !w_is_ctrl) begin
            r_rx_pkt_in_progress <= 1'b1;          // DATA 도착
        end else if (w_got_nchar && w_is_ctrl) begin
            r_rx_pkt_in_progress <= 1'b0;          // EOP/EEP 로 정상 종료
        end
    end

    // r_eep_pending: 에러 진입 시 미완성 패킷이 있었으면 무장(SET)된다.
    // ⚠️ 1클럭 pulse 가 아니라 **레벨 신호**다 — RX FIFO(spw_network 소유)에
    // 실제로 빈 자리가 나서 w_eep_write_now 가 뜨는 그 클럭까지, ErrorReset
    // 이후 ErrorWait/Ready/Started/Connecting 을 거쳐 몇 클럭이 걸리든(심지어
    // 다음 Run 진입 이후까지도) 계속 유지된다. 아래 w_fct_send_ok 게이팅이
    // 이 pending 이 풀리기 전엔 파트너에게 새 credit 을 주지 않으므로, 이
    // 신호가 살아있는 동안 정상 DATA 가 새로 도착해 순서를 앞지르는 일은
    // 구조적으로 발생하지 않는다.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_eep_pending <= 1'b0;
        end else if (w_entering_error_reset && r_rx_pkt_in_progress) begin
            r_eep_pending <= 1'b1;
        end else if (w_eep_write_now) begin
            r_eep_pending <= 1'b0;
        end
    end

    // FIFO 에 여유(i_rx_free_space>0)가 생기는 즉시(레벨 조건, 몇 클럭이든
    // 대기) pending 된 EEP 를 그 자리에 써넣는다.
    assign w_eep_write_now = r_eep_pending && (i_rx_free_space > '0);

    // ── Network Layer RX 출력 ────────────────────────────────────
    // 평소엔 w_got_nchar/i_rx_char 를 그대로 전달. w_eep_write_now 인 그
    // 클럭에는(이 클럭엔 w_got_nchar 가 뜰 수 없다 — 위 설명 참조) 그 자리를
    // 가로채 합성 EEP({flag=1, code=2'b01})를 대신 내보낸다.
    assign ow_rx_char_data  = w_eep_write_now ? {1'b1, 6'b0, 2'b01} : i_rx_char;
    assign ow_rx_char_valid = w_eep_write_now ? 1'b1                : w_got_nchar;
    assign ow_rx_char_ctrl  = w_eep_write_now ? 1'b1                : w_is_ctrl;
                                                 // 1=EOP/EEP, 0=DATA (valid=1 인 클럭에서만 유효)

    // =========================================================================
    // ERRATA-26  TX FIFO 잔여 바이트 leak 방지 (E1/ERRATA-18과 대칭되는 TX측)
    // =========================================================================
    // r_tx_pkt_in_progress: RUN 중 실제 DATA(비제어 N-Char) 송신을 시작했고
    // 아직 EOP/EEP 로 정상 종료되지 않았는지 추적. w_entering_error_reset 시
    // 그 값을 r_tx_flushing 으로 "승계"한 뒤 자신은 클리어된다.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_pkt_in_progress <= 1'b0;
        end else if (w_entering_error_reset) begin
            r_tx_pkt_in_progress <= 1'b0;
        end else if (w_send_nchar && !i_nchar_data[8]) begin
            r_tx_pkt_in_progress <= 1'b1;          // DATA 송신
        end else if (w_send_nchar && i_nchar_data[8]) begin
            r_tx_pkt_in_progress <= 1'b0;          // EOP/EEP 로 정상 종료
        end
    end

    // r_tx_flushing: 에러 진입 시 미송신 패킷이 있었으면 무장(SET)된다.
    // eep_pending(RX측, 공간을 "기다리는" 레벨 신호)과 달리, 이쪽은 "에러
    // 시점에 이미 큐에 있던 것만" 다음 EOP/EEP(또는 FIFO 바닥)까지 계속
    // pop-and-discard 한다 — 터미네이터를 못 찾은 채 FIFO 가 바닥나면(더
    // 버릴 게 없으면) 거기서 그냥 종료한다. 에러 이후 호스트가 새로 넣는
    // 건 무조건 새 데이터로 취급한다(에러 시점 이후 도착한 걸 "옛것"으로
    // 볼 근거가 없음 — golden model 초안에서 "무한정 대기"로 짰다가 다음
    // 패킷까지 삼켜버리는 회귀가 나서 이 방식으로 수정한 이력 있음).
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_flushing <= 1'b0;
        end else if (w_entering_error_reset && r_tx_pkt_in_progress) begin
            r_tx_flushing <= 1'b1;
        end else if (r_tx_flushing && !i_nchar_valid) begin
            r_tx_flushing <= 1'b0;                 // 버릴 게 이미 없음 -> 종료
        end else if (r_tx_flushing && i_nchar_valid && i_nchar_data[8]) begin
            r_tx_flushing <= 1'b0;                 // 터미네이터(EOP/EEP) 를 버림 -> 종료
        end
    end

    // =========================================================================
    // §5 Flow Control — Credit 카운터 (ERRATA-11/20 반영)
    // =========================================================================
    // ERRATA-11 핵심: "독립 FCT 송신"과 "Null 유휴 필러의 FCT 절반"은 와이어
    // 레벨에서 같은 심볼이지만 의미가 다르다 — 후자는 credit 승인이 아니다.
    // 이 설계는 애초에 두 이벤트를 다른 신호로 분리한다: w_send_fct(§8.3,
    // 우선순위 2/초기FCT — 독립 FCT만) vs w_send_second(§8, ESC 원자적 시퀀스의
    // 두 번째 문자 = Null 필러의 FCT 절반). §5.2 는 w_send_fct 만 참조하므로
    // Null 필러가 자동으로 credit 이중계상에서 제외된다(참조모델 패치와 동일 효과,
    // note_tx_char_sent(is_independent_fct) 구분에 대응).
    //
    // ERRATA-20 반영: r_tx_credit 은 ST_CONNECTING 도 포함해서 갱신(아래 §5.1).
    // r_rx_credit(§5.2) 과 상태 게이트를 대칭으로 통일.

    assign w_credit_sync_rst = (w_next_state == ST_ERROR_RESET);

    // ── Comb: credit 오버플로우/언더플로우 사전 검사 ──────────────
    // ⚠️ 폭 주의: r_tx_credit(6비트, 0~63) + 8 이 64를 넘으면(예: 56+8=64) 6비트
    // 산술에서 mod-64 wrap 이 발생해 "64 > 56" 비교가 거짓으로 나와 credit_err
    // 검출 자체가 실패한다(guide §5.1 원문 코드를 그대로 옮기면 재현되는 버그 —
    // 이 구현에서 시뮬레이션으로 실제 발견/수정). 비교 전 폭을 7비트로 넓혀
    // wrap 없이 계산한다.
    logic [6:0] w_tx_credit_sum;
    assign w_tx_credit_sum = {1'b0, r_tx_credit} + 7'd8;

    always_comb begin
        // TX: FCT 수신으로 56 초과 여부 (Connecting/Run 에서만 유효한 검사)
        w_tx_credit_err = w_got_fct
                        & (r_state == ST_CONNECTING || r_state == ST_RUN)
                        & (w_tx_credit_sum > {1'b0, MAX_CREDIT[5:0]});

        // RX: credit 없는데 N-Char 수신
        w_rx_credit_err = w_got_nchar & (r_rx_credit == 6'd0);

        w_credit_err = w_tx_credit_err | w_rx_credit_err;
    end

    // ── FF: r_tx_credit (§5.1, ERRATA-20 반영 — CONNECTING 포함) ──
    // [✅ ERRATA-25 해결, 2026-09-02] 이전엔 증가/감소를 별도 non-blocking
    // `if` 블록 두 개(선택 A)로 분리해뒀는데, w_got_fct(RX)와 w_send_nchar
    // (TX)가 같은 클럭에 동시에 뜨면 텍스트 순서상 나중 블록(감소)의 대입이
    // 그 클럭의 최종값을 그냥 덮어써 +8 증가분이 통째로 유실됐다
    // (`tb_race_check.sv` 로 실측: old=10일 때 결과가 17이 아니라 9).
    // 아래처럼 두 조건의 네 가지 조합(둘다/증가만/감소만/둘다아님)을 명시적
    // `if/else if`로 나열하는 "선택 B"로 전환해 동시 발생 케이스에서도
    // +8과 -1이 함께(net +7) 반영되도록 고쳤다.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_credit <= 6'd0;
        end else if (w_credit_sync_rst) begin
            r_tx_credit <= 6'd0;
        end else begin
            // FCT 수신에 의한 증가 (Connecting, Run) — ERRATA-20
            if (((r_state == ST_CONNECTING || r_state == ST_RUN)
                    && w_got_fct && !w_tx_credit_err)
                    && (r_state == ST_RUN && w_send_nchar)) begin
                // ERRATA-25: 같은 클럭에 증가/감소 동시 발생 -> 둘 다 반영(net +7)
                r_tx_credit <= r_tx_credit + 6'd8 - 6'd1;
            end else if ((r_state == ST_CONNECTING || r_state == ST_RUN)
                    && w_got_fct && !w_tx_credit_err) begin
                r_tx_credit <= r_tx_credit + 6'd8;
            end else if (r_state == ST_RUN && w_send_nchar) begin
                // N-Char 송신에 의한 감소 (Run) — w_send_nchar 는 §8.3 에서 정의
                r_tx_credit <= r_tx_credit - 6'd1;
            end
        end
    end

    // ── FF: r_rx_credit (§5.2) ──────────────────────────────────
    // w_send_fct 는 §8.3 에서 "독립 FCT 송신"일 때만 1 (ERRATA-11 반영 — Null
    // 필러의 FCT 절반은 w_send_second 이지 w_send_fct 가 아니므로 여기 포함 안 됨).
    // ⚠️ 폭 주의: 여기엔 §5.1(w_tx_credit_sum)과 달리 명시적 7비트 오버플로우
    // 사전검사가 없다 — r_rx_credit 은 §7.1 FCT 송신 게이트
    // (w_fct_send_ok = r_rx_credit <= MAX_CREDIT-8) 가 애초에 48 초과 시 FCT 를
    // 보내지 않도록 원천 차단하는 구조로 설계되어 있어(§7 구현 시 이 게이트가
    // w_send_fct 의 필요조건이 됨), r_rx_credit 자체가 56을 넘을 방법이 없다.
    // 단, 이건 §7 구현을 전제로 한 안전성이므로 §7 완성 시 이 가정이 실제로
    // 지켜지는지 반드시 재검증할 것.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_rx_credit <= 6'd0;
        end else if (w_credit_sync_rst) begin
            r_rx_credit <= 6'd0;
        end else if ((r_state == ST_CONNECTING || r_state == ST_RUN) && !w_rx_credit_err) begin
            r_rx_credit <= r_rx_credit
                + (w_send_fct  ? 6'd8 : 6'd0)
                - (w_got_nchar ? 6'd1 : 6'd0);
        end
    end

    // ── FF: r_req_initial_fct (§5.4, Connecting 진입 시 min(FIFO/8,7)) ──
    // ECSS 5.5.4.k: min(RX_FIFO_DEPTH/8, 7)
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_req_initial_fct <= 3'd0;
        end else if (w_entering_connecting) begin
            r_req_initial_fct <= 3'(RX_FIFO_DEPTH / 8 < 7 ? RX_FIFO_DEPTH / 8 : 7);
        end else if (w_send_fct && r_req_initial_fct > 3'd0) begin
            r_req_initial_fct <= r_req_initial_fct - 3'd1;
        end
    end

    // =========================================================================
    // §9.4 credit_error 검출 (미결 #3 — 구현 완료)
    // =========================================================================
    // ⚠️ guide §10 미결#3 원문 코드는 next_state 계산에 "래치된 r_err_credit"을
    // 쓰라고 하지만, 이는 golden model 대비 1클럭 지연 버그다 — golden model
    // (SpWLink.tick())은 그 클럭에 이미 SET 된 내부 credit_error 플래그를
    // immediate_error 계산에서 즉시(같은 클럭) 검사한다. §3.3 의
    // w_immediate_error 는 이미 w_credit_err(그 클럭의 comb 원인)를 직접
    // 참조하도록 구현되어 있어 golden model과 지연 없이 일치한다 — 이게 옳은
    // 형태이므로 별도의 래치를 next_state 판단에 끼워넣지 않는다.
    //
    // 출력 ow_err_credit 도 같은 이유로 golden model 의 "err_credit = credit_error
    // 매 클럭 그대로 미러링" 방식을 따라 w_credit_err 를 직접 반영한다(스티키
    // 래치가 아님 — ErrorReset 을 유발한 바로 그 클럭에도 값이 보이고, 다음
    // 클럭엔 원인이 사라지면 그대로 0 이 되는 게 golden model 과 동일한 거동).
    assign r_err_credit  = w_credit_err;   // 내부 미사용이지만 §4 선언과의 일관성을 위해 유지
    assign ow_err_credit = w_credit_err;

    // =========================================================================
    // §7 FCT 송신 조건 (2개 AND)
    // =========================================================================
    localparam int RX_FREE_THRESH = 8;

    // 조건 A (물리적 여유): spw_network 제공 raw 값, 비교는 본 모듈 내부 완결
    // 조건 B (논리적 크레딧): r_rx_credit <= MAX_CREDIT-8 이어야 다음 FCT로
    //   56을 넘기지 않는다 (§5.2 의 r_rx_credit 오버플로우 방지 전제가 바로 이 게이트)
    // 조건 C (ERRATA-18 인터록): r_eep_pending 이 풀리기 전엔 새 credit 을
    //   전혀 주지 않는다. 안 그러면 파트너가 새 credit 을 받아 DATA 를
    //   보내는 게 pending EEP 삽입보다 먼저 RX FIFO 에 들어갈 수 있어
    //   "EEP 가 새 패킷 뒤로 밀리는" 순서 역전이 생긴다.
    assign w_fct_send_ok = (i_rx_free_space >= RX_FREE_THRESH)
                         & (r_rx_credit <= (MAX_CREDIT - 8))
                         & !r_eep_pending;

    // =========================================================================
    // DECISION-17 Option B: Timecode starvation throttle
    // (golden model spw_ref_model.py::SpWNode._select_next_tx_char() 이식)
    // =========================================================================
    localparam int TC_STARVE_THRESHOLD = 8;   // golden model SpWNode.TC_STARVE_THRESHOLD와 동일

    // "다른 것도 보낼 준비된 상태"인지 -- §8.3 RUN 분기의 2/3순위(FCT/N-Char)
    // 조건과 동일해야 한다(단, i_enc_ready는 아래 카운터 게이팅에서 별도 적용).
    assign w_tc_other_ready = w_fct_send_ok
                            | (i_nchar_valid & (r_tx_credit > 6'd0) & !r_tx_flushing);

    // 이번 클럭에 Timecode가 양보해야 하는지: RUN + Timecode 대기 + 경합상대
    // 있음 + 카운터가 이미 임계값 도달. §8.3의 Timecode 분기 조건에 그대로
    // AND로 끼워넣는다(아래).
    assign w_tc_starve_yield = (r_state == ST_RUN) & r_tc_pending & i_enc_ready
                             & w_tc_other_ready & (r_tc_starve_cnt >= TC_STARVE_THRESHOLD[3:0]);

    // ── FF: r_tc_starve_cnt ──
    // 정상 사용(느린 주기의 정당한 Timecode 요청)에서는 r_tc_pending이 한 번
    // 소비되면 곧 0이 되어 이 카운터가 임계값에 절대 도달하지 않는다 -- 병적
    // 재무장(scenario_24가 실측한 물리적 최대 tick_in 토글) 상황에서만 개입.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tc_starve_cnt <= 4'd0;
        end else if (w_entering_error_reset) begin
            r_tc_starve_cnt <= 4'd0;   // 다른 §8.2/§8.1 임시 상태와 동일하게 클리어
        end else if (r_state == ST_RUN && i_enc_ready && r_tc_pending && w_tc_other_ready) begin
            r_tc_starve_cnt <= w_tc_starve_yield ? 4'd0 : (r_tc_starve_cnt + 4'd1);
        end else if (r_state == ST_RUN && i_enc_ready) begin
            // Timecode 자체가 없거나(r_tc_pending=0) 경합상대가 없음 -- 정상
            // 상황, 카운터 리셋
            r_tc_starve_cnt <= 4'd0;
        end
    end

    // =========================================================================
    // §8.2 Timecode 래치 (r_tc_pending, r_tc_value)
    // =========================================================================
    // 미결 #4 (해소, ERRATA-19): RUN 이전 도착한 i_tick_in 은 래치하지 않고
    // discard. golden model 의 deque(maxlen=1) 큐잉이 버그였고, 이 RTL(선택 A)
    // 이 원래 정확했다는 게 v4/v5 에서 확정됨.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tc_pending <= 1'b0;
            r_tc_value   <= 8'd0;
        end else if (w_entering_error_reset) begin
            r_tc_pending <= 1'b0;   // ErrorReset 진입 시 폐기 (§9.1)
            r_tc_value   <= 8'd0;
        end else if (i_tick_in && r_state == ST_RUN) begin
            // 새 Timecode 요청 — drop-old 정책 (참조 모델 deque(maxlen=1) 동작과
            // 동일한 "최신값으로 덮어쓰기". RUN 이전 도착은 이 조건 자체가
            // 거짓이라 자동으로 discard 됨(ERRATA-19).
            r_tc_pending <= 1'b1;
            r_tc_value   <= i_time_in;
        end else if (w_send_timecode_esc) begin
            // ESC 송신 시 래치 소비
            r_tc_pending <= 1'b0;
        end
    end

    // =========================================================================
    // §8.3 송신 우선순위 결정 (comb) + §8.1 ESC 원자적 시퀀스 TX 구조
    // =========================================================================
    logic w_tx_char_valid_comb;

    // 우선순위 (RUN): ESC 시퀀스 진행중(최우선) > Timecode > FCT > N-Char > Null(유휴)
    // 우선순위 (CONNECTING): 초기 FCT > 일반 FCT > Null
    // STARTED: Null 만 (850ns 타임아웃 방지)
    // ErrorReset/ErrorWait/Ready: 아무것도 송신 안 함 (ECSS 5.5.7.4.a.1, DECISION-14)
    always_comb begin
        // 기본값
        w_send_esc          = 1'b0;
        w_send_fct           = 1'b0;
        w_send_nchar          = 1'b0;
        w_send_second        = 1'b0;
        w_send_timecode_esc  = 1'b0;
        w_next_esc_kind      = 1'b0;
        w_tx_char            = 9'b0;

        // ── 최우선: ESC 원자적 시퀀스 진행 중 (두 번째 문자 완성) ──
        // [PATCH-1, 2026-08-31] 다른 모든 분기(Timecode/FCT/N-Char/Null,
        // 653/660/665/670/689/697행)는 전부 `&& i_enc_ready` 로 게이팅되어
        // 있는데 이 분기만 빠져 있었다. encoder 가 아직 ESC 비트를 시프트
        // 중(busy)인데도 "두 번째 문자 전송 완료"로 간주해버려서, 실제
        // FCT/Timecode 는 encoder 에 로드되지 않고 유실되고 r_esc_pending
        // 만 먼저 클리어되는 버그였다 (그 뒤 encoder 가 idle 이 되면
        // r_esc_pending=0 이니 Null 분기를 새로 타 ESC 를 또 보내 "ESC->ESC
        // 중복" 증상 발생, tb_esc_enc_handshake.sv / tb_spw_top_loopback.sv
        // 로 재현·확정). golden model 의 enc.idle() 게이팅(spw_ref_model.py
        // SpWNode.tick() 752~758행, _select_next_tx_char() 800~805행)과
        // 동일하게 맞춘다. r_esc_pending 클리어(722행)는 w_send_second 를
        // 그대로 참조하므로 이 한 줄로 자동으로 같이 게이팅된다.
        if (r_esc_pending) begin
            w_send_second = i_enc_ready;   // [PATCH-1] was: 1'b1 (unconditional)
            if (r_esc_kind == 1'b0) begin
                w_tx_char = {1'b1, 6'b0, 2'b00};  // FCT (code=00) = Null 완성
            end else begin
                w_tx_char = {1'b0, r_tc_value};    // Timecode 값 (data-shaped)
            end

        end else if (r_state == ST_RUN) begin
            // ── RUN 상태 ─────────────────────────────────────────
            // 1순위: Timecode ESC (ECSS 5.5.6 — Broadcast code 최우선)
            // [DECISION-17 Option B] !w_tc_starve_yield 게이팅 추가: 정상 동작
            // 궤적에서는 항상 참(카운터가 임계값에 도달 못 함)이라 기존과 동일하게
            // 작동하고, 병적 재무장 상황에서만 2/3순위로 양보한다.
            if (r_tc_pending && i_enc_ready && !w_tc_starve_yield) begin
                w_send_esc          = 1'b1;
                w_send_timecode_esc = 1'b1;
                w_next_esc_kind      = 1'b1;  // 다음 클럭: Timecode 두 번째 문자
                w_tx_char = {1'b1, 6'b0, 2'b11};  // ESC (code=11)

            // 2순위: FCT 요청 (독립 FCT)
            end else if (w_fct_send_ok && i_enc_ready) begin
                w_send_fct = 1'b1;
                w_tx_char  = {1'b1, 6'b0, 2'b00};  // FCT

            // 3순위: N-Char (credit 있고 TX FIFO 에 데이터 있을 때)
            // [PATCH-2, 2026-08-31] spw_network.sv 헤더 주석(25~30행)에 명시된 대로,
            // TX 방향 host 9비트 포맷(bit8=1, [7:0]=0x00/0x01 for EOP/EEP)을 enc
            // 제어코드 공간(ERRATA-7: FCT=00/EOP=10/EEP=01/ESC=11)으로 재인코딩하는
            // 책임이 spw_datalink 에 있는데 빠져 있었다. `w_tx_char = i_nchar_data`
            // 로 그냥 통과시키면 EOP(0x100, code[1:0]=00)가 FCT(code=00)로 잘못
            // 해석되어 수신측에서 독립 FCT로 오인 → credit 이 상한(56) 위로 부여되며
            // w_tx_credit_err 발동 → disconnect 로 이어지는 것을 tb_spw_top_loopback.sv
            // 시뮬레이션으로 확인했다(DATA 0x5A 다음 EOP 송신 지점).
            end else if (i_nchar_valid && r_tx_credit > 6'd0 && i_enc_ready && !r_tx_flushing) begin
                w_send_nchar = 1'b1;
                if (i_nchar_data[8]) begin
                    // 제어 문자 (EOP/EEP) -- host 포맷 -> enc 제어코드로 재인코딩
                    w_tx_char = (i_nchar_data[7:0] == 8'h00)
                              ? {1'b1, 6'b0, 2'b10}   // EOP (ERRATA-7: code=10)
                              : {1'b1, 6'b0, 2'b01};  // EEP (ERRATA-7: code=01)
                end else begin
                    w_tx_char = i_nchar_data;         // DATA 는 그대로 (flag=0, payload=raw byte)
                end

            // 4순위: Null (idle filler — ESC 보내고 다음 클럭 FCT, ERRATA-11 대상)
            end else if (i_enc_ready) begin
                w_send_esc      = 1'b1;
                w_next_esc_kind = 1'b0;  // 다음 클럭: FCT (Null 완성) — w_send_fct 아님
                w_tx_char = {1'b1, 6'b0, 2'b11};  // ESC
            end

        end else if (r_state == ST_CONNECTING) begin
            // ── CONNECTING 상태 ──────────────────────────────────
            // 1순위: 초기 FCT 선송신 (§5.4 r_req_initial_fct)
            // ERRATA-18 인터록: r_eep_pending 이 안 풀렸으면 이 경로도 보류.
            // w_fct_send_ok(2순위, RUN 에서도 공유)는 이미 !r_eep_pending 을
            // 포함하지만, 이 1순위는 별도 카운터라 따로 게이팅해야 한다.
            if (r_req_initial_fct > 3'd0 && i_enc_ready && !r_eep_pending) begin
                w_send_fct = 1'b1;
                w_tx_char  = {1'b1, 6'b0, 2'b00};

            // 2순위: 일반 FCT 요청
            end else if (w_fct_send_ok && i_enc_ready) begin
                w_send_fct = 1'b1;
                w_tx_char  = {1'b1, 6'b0, 2'b00};

            // 3순위: Null
            end else if (i_enc_ready) begin
                w_send_esc      = 1'b1;
                w_next_esc_kind = 1'b0;
                w_tx_char = {1'b1, 6'b0, 2'b11};
            end

        end else if (r_state == ST_STARTED) begin
            // ── STARTED: Null 만 송신 (850ns 타임아웃 방지, DECISION-14 전제) ──
            if (i_enc_ready) begin
                w_send_esc      = 1'b1;
                w_next_esc_kind = 1'b0;
                w_tx_char = {1'b1, 6'b0, 2'b11};
            end
        end
        // ErrorReset/ErrorWait/Ready: 아무것도 송신하지 않음
        // (ECSS 5.5.7.4.a.1: Ready 에서 Transmit Enable 비활성화 — v5 원문 확정)

        // Encoder로 내보낼 문자 유효
        w_tx_char_valid_comb = w_send_second | w_send_fct | w_send_nchar
                             | (w_send_esc & ~r_esc_pending);
    end

    // ── FF: r_esc_pending, r_esc_kind (§8.1 ESC 원자적 시퀀스) ──
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_esc_pending <= 1'b0;
            r_esc_kind    <= 1'b0;
        end else if (w_entering_error_reset) begin
            r_esc_pending <= 1'b0;       // ESC 시퀀스 강제 중단 (§9.1)
            r_esc_kind    <= 1'b0;
        end else if (w_send_esc) begin
            r_esc_pending <= 1'b1;       // ESC 보냄 → 두 번째 문자 대기
            r_esc_kind    <= w_next_esc_kind;
        end else if (w_send_second) begin
            r_esc_pending <= 1'b0;       // 두 번째 문자 완료
        end
    end

    // =========================================================================
    // §8.4 ow_nchar_ready
    // =========================================================================
    // guide §8.4 원문(3개 AND: state==RUN & credit>0 & enc_ready)은 §8.3 의
    // 우선순위(Timecode/FCT 가 N-Char 보다 앞설 수 있음)를 반영하지 않아, FCT나
    // Timecode 가 그 클럭에 우선 선택되어도 ow_nchar_ready 가 떠서 network layer
    // 가 TX FIFO 를 잘못 pop 할 위험이 있다 — 이 구현에서 발견해 w_send_nchar
    // (§8.3 이 실제로 N-Char 를 선택한 결과)와 동치로 정정했다.
    // [ERRATA-26, 2026-09-02] r_tx_flushing 동안은 w_send_nchar(실제 송신)와
    // 무관하게, FIFO에 뭐가 있으면(i_nchar_valid) 그걸 그냥 pop-and-discard
    // 한다 — 인코더로는 절대 나가지 않는다(위 §8.3 우선순위-3 이 !r_tx_flushing
    // 으로 막혀 있으므로 실제 송신과 동시에 일어날 수 없다).
    assign ow_nchar_ready = r_tx_flushing ? i_nchar_valid : w_send_nchar;

    // ── Encoder 인터페이스 출력 ────────────────────────────────
    assign ow_tx_char_valid = w_tx_char_valid_comb;
    assign ow_tx_char       = w_tx_char;

    // =========================================================================
    // §9.1 ErrorReset 진입 시 리셋 — ow_enc_reset 펄스
    // =========================================================================
    assign ow_enc_reset = w_entering_error_reset;  // 1클럭 pulse (spw_enc 강제 리셋)

    // =========================================================================
    // §9.1/§9.2 Disconnect 게이팅 — (A) 결정: spw_phy 로 역할 일원화
    // =========================================================================
    // ⚠️ 아키텍처 결정 기록: guide §9.2 는 spw_datalink 내부에
    // r_seen_any_transition 을 별도로 두고 i_disconnect 를 다시 게이팅하라고
    // 명시하지만, golden model 을 재확인한 결과 seen_any_transition 은
    // SpWDecoder(=spw_phy 대응) 계층 하나에만 존재하고 SpWLink(=spw_datalink
    // 대응)는 이를 별도로 갖지 않는다 — SpWLink.disconnect 는 이미 Decoder 가
    // 게이트를 마친 최종값을 그대로 받아쓸 뿐이다. 즉 guide §9.2 가 요구하는
    // 이중 게이트는 golden model 구조와 어긋나는 설계였다.
    //
    // 실제로 spw_datalink 로컬 게이트를 구현해보니, i_disconnect 가 ErrorReset
    // 전이를 유발하는 바로 그 클럭에 게이트 클리어와 판정이 동시에 일어나
    // ow_err_disconnect 가 그 원인 클럭에도 정상 관측되지 않는 레이스가
    // 발생함을 시뮬레이션으로 확인했다.
    //
    // (A) 결정: spw_phy.sv 에 i_link_reset 포트를 신설해(v2), spw_datalink 가
    // ErrorReset 에 재진입하는 클럭마다 spw_phy 의 r_seen_any_transition 을
    // 직접 재초기화하도록 근본 해결했다(spw_top 배선 시 ow_enc_reset 또는
    // 동일한 w_entering_error_reset 신호를 spw_phy.i_link_reset 에 연결).
    // 따라서 spw_datalink 는 spw_phy 가 이미 재연결 세션 단위로 올바르게
    // 게이트한 i_disconnect 를 그대로 신뢰하면 된다 — 이중 게이트 불필요.
    //
    // r_seen_any_transition 레지스터는 guide §4 문서와의 대응을 위해 이름만
    // 유지하되 항상 0(미사용)으로 고정한다. §12 참조모델 대응표 갱신 필요.
    assign r_seen_any_transition = 1'b0;  // 미사용 — 역할은 spw_phy.r_seen_any_transition 으로 이전

    // =========================================================================
    // §9.2 Disconnect 에러 활성화 (ERRATA-5, DECISION-08) — (A) 결정 반영
    // =========================================================================
    // spw_phy 가 이미 i_link_reset 기반으로 재연결 세션마다 올바르게 게이트한
    // 값이므로, 여기서는 그대로 신뢰한다 (추가 게이팅 없음).
    assign w_valid_disconnect = i_disconnect;

    // =========================================================================
    // §9.1 나머지 에러 출력 (ow_err_disconnect/parity/esc)
    // =========================================================================
    // §9.4(credit_error)와 동일한 이유로, golden model 처럼 "그 클럭의 원인
    // 신호를 그대로 미러링"하는 조합 방식을 쓴다(스티키 래치 아님) — 이렇게
    // 해야 ErrorReset 을 유발한 바로 그 클럭에도 값이 보이고, 다음 클럭부터는
    // 원인이 사라지면 그대로 0 이 되는 golden model(SpWLink.tick() 끝부분:
    // err_disconnect=disconnect, err_parity=parity_error, err_esc=esc_error)
    // 과 정확히 같은 거동이 된다.
    assign r_err_disconnect  = w_valid_disconnect;
    assign r_err_parity      = i_parity_err;
    assign r_err_esc         = w_esc_error;

    assign ow_err_disconnect = w_valid_disconnect;
    assign ow_err_parity     = i_parity_err;
    assign ow_err_esc        = w_esc_error;

    // =========================================================================
    // DECISION-13 — ow_err_tx_invalid (보류)
    // =========================================================================
    // guide 어디에도 이 신호의 구체적 판정 로직/근거 조항이 없다(포트 선언과
    // 이름만 존재). §8.3 comb 로직은 항상 유효한 control code(FCT/ESC)만
    // 생성하도록 설계되어 있어, 이 설계 안에서는 "잘못된 TX 제어 코드"가
    // 구조적으로 발생할 여지가 없어 보인다 — 다만 이게 DECISION-13 의 실제
    // 의도인지 확인 없이 임의로 단정하지 않고, 근거 확인 전까지 0 고정 유지.
    assign ow_err_tx_invalid = 1'b0;  // TODO: DECISION-13 근거 확인 후 구현

endmodule
