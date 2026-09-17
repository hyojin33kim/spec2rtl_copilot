// =============================================================================
// spw_phy — SpaceWire Physical Layer (DS 신호 I/O)
// ECSS-E-ST-50-12C Rev.1 §5.3 / HO_04_RTL_Design_v3.md §5.1 / HO_03_Checklist_v2.md §4.1
//
// 기능:
//   1. Pure Digital 모드: 물리 DS 신호 그대로 통과 (시뮬 단계, Xilinx 이식 시
//      IBUFDS/OBUFDS 로 교체 — SpW_Xilinx_Porting_Guide.md 참조)
//   2. i_ds_rx_data / i_ds_rx_strobe 는 외부 비동기 입력이므로, 내부에서 2FF
//      동기화기(SpW_Xilinx_Porting_Guide.md §5.2 패턴)를 거친 뒤에만 사용한다
//   3. Disconnect 감지: 동기화된 Data/Strobe 모두 CNT_DISC 클럭 이상 무변화 시
//      ow_disconnect 1클럭 펄스
//      [ERRATA-5] Data 또는 Strobe 라인에 최초 천이가 발생하기 전에는 카운터를
//      활성화하지 않는다 (ECSS Figure 5-19 NOTE 1) — 링크 시작 전 무한 진동 방지
//
// [신규 발견, 착수 전 정정] CNT_DISC 공식: 문서 원문 그대로
//   (CLK_FREQ_HZ / 1_000_000_000 * DISCONNECT_TIMEOUT_NS) 를 쓰면 정수 나눗셈이
//   먼저 0 이 되어버려 결과가 항상 0. CNT_6US/CNT_12US 와 동일한 안전 순서로 수정.
//
// [v2, spw_datalink §9 구현 중 발견] i_link_reset 포트 신규 추가:
//   기존(v1)에는 r_seen_any_transition/disconnect 카운터가 i_rst_n(칩 전체
//   비동기 리셋)으로만 클리어됐다. 그런데 golden reference model
//   (SpWDecoder.reset_framing())은 "spw_datalink 가 ErrorReset 에 재진입할
//   때마다" seen_any_transition 을 다시 False 로 클리어한다 — 재연결 세션마다
//   상대 응답 전까지는 disconnect 판정 자체를 비활성화하기 위해서다
//   (ECSS Figure 5-19 NOTE 1). i_rst_n 으로만 클리어되면, 한쪽만 재시작해
//   타이밍이 어긋난 상대를 기다리는 동안 무신호 disconnect 오탐이 반복돼
//   영구 데드락에 빠질 위험이 있다(golden model 주석에 실측 근거 명시).
//   spw_datalink 가 ErrorReset 에 새로 진입하는 그 클럭에 1클럭 pulse 로
//   i_link_reset 을 걸어주면, 이 모듈이 seen_any_transition/카운터를
//   즉시 재초기화해 golden model 과 동일한 "재연결 세션마다 리셋" 동작을
//   재현한다. 순수 추가 포트라 하위 호환 — 연결하지 않으면(0 고정) v1과
//   동일하게 동작한다.
// =============================================================================

module spw_phy #(
    parameter int CLK_FREQ_HZ           = 100_000_000,
    parameter int DISCONNECT_TIMEOUT_NS = 850
) (
    // ── Clock / Reset ────────────────────────────────────────────
    input  logic i_clk,
    input  logic i_rst_n,

    // ── Link 재연결 통지 (v2 신규) ──────────────────────────────────
    // spw_datalink 가 ErrorReset 에 새로 진입하는 클럭에 1클럭 pulse.
    // r_seen_any_transition/disconnect 카운터를 그 세션에 한해 재초기화한다
    // (golden model reset_framing() 과 동일 의도). 미연결(0 고정) 시 기존(v1)
    // 과 동일하게 동작 — 하위 호환.
    input  logic i_link_reset,

    // ── 물리 DS 인터페이스 (Pure Digital, 비동기 외부 입력) ───────
    input  logic i_ds_rx_data,
    input  logic i_ds_rx_strobe,
    output logic ow_ds_tx_data,
    output logic ow_ds_tx_strobe,

    // ── spw_enc 인터페이스 — RX (동기화 완료된 비트) ──────────────
    output logic ow_rx_data_bit,
    output logic ow_rx_strobe_bit,

    // ── spw_enc 인터페이스 — TX ────────────────────────────────────
    input  logic i_tx_data_bit,
    input  logic i_tx_strobe_bit,

    // ── 상태 출력 ──────────────────────────────────────────────────
    output logic ow_disconnect
);

    // ── 타이머 localparam ────────────────────────────────────────
    // [정정] 안전한 나눗셈 순서: MHz 로 먼저 축소 → ns 값 곱함 → 1000 으로 나눔
    localparam int CNT_DISC = CLK_FREQ_HZ / 1_000_000 * DISCONNECT_TIMEOUT_NS / 1000; // 85 @ 100MHz
    localparam int CNT_W    = (CNT_DISC <= 1) ? 1 : $clog2(CNT_DISC + 1);

    // ── 2FF 동기화기 — RX Data ───────────────────────────────────
    logic r_data_meta, or_rx_data_bit;
    logic r_strb_meta, or_rx_strobe_bit;

    (* ASYNC_REG = "TRUE" *) logic unused_attr_data_meta = r_data_meta;
    (* ASYNC_REG = "TRUE" *) logic unused_attr_data_sync = or_rx_data_bit;
    (* ASYNC_REG = "TRUE" *) logic unused_attr_strb_meta = r_strb_meta;
    (* ASYNC_REG = "TRUE" *) logic unused_attr_strb_sync = or_rx_strobe_bit;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_data_meta <= 1'b0;
            or_rx_data_bit <= 1'b0;
            r_strb_meta <= 1'b0;
            or_rx_strobe_bit <= 1'b0;
        end else begin
            r_data_meta <= i_ds_rx_data;
            or_rx_data_bit <= r_data_meta;
            r_strb_meta <= i_ds_rx_strobe;
            or_rx_strobe_bit <= r_strb_meta;
        end
    end

    // 동기화된 RX 비트를 enc 로 그대로 전달
    assign ow_rx_data_bit   = or_rx_data_bit;
    assign ow_rx_strobe_bit = or_rx_strobe_bit;

    // ── 이전값 래치 (변화 감지용, 동기화된 신호 기준) ─────────────
    logic r_prev_data_sync;
    logic r_prev_strb_sync;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_prev_data_sync <= 1'b0;
            r_prev_strb_sync <= 1'b0;
        end else begin
            r_prev_data_sync <= or_rx_data_bit;
            r_prev_strb_sync <= or_rx_strobe_bit;
        end
    end

    logic w_data_changed;
    logic w_strb_changed;
    logic w_any_transition;

    // ── [ERRATA-5] 최초 천이 발생 여부 래치 ───────────────────────
    logic r_seen_any_transition;

    // ── Disconnect 카운터 ─────────────────────────────────────────
    logic [CNT_W-1:0] r_no_change_cnt;
    logic              w_sync_rst_cnt;
    logic              or_disconnect;

    // ── Comb 블록: 변화 감지 + sync reset 조건 ────────────────────
    always_comb begin
        w_data_changed   = (or_rx_data_bit != r_prev_data_sync);
        w_strb_changed   = (or_rx_strobe_bit != r_prev_strb_sync);
        w_any_transition = w_data_changed | w_strb_changed;
        // sync reset 조건: 천이가 있었거나, 아직 첫 천이 전이면 카운터를 0으로 유지.
        // i_link_reset(재연결 세션 시작) 도 이 클럭엔 카운터를 강제로 0에 묶어둔다.
        w_sync_rst_cnt   = w_any_transition | !r_seen_any_transition | i_link_reset;
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_seen_any_transition <= 1'b0;
        end else if (i_link_reset) begin
            r_seen_any_transition <= 1'b0;   // 재연결 세션마다 재초기화 (v2)
        end else if (w_any_transition) begin
            r_seen_any_transition <= 1'b1;
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_no_change_cnt <= '0;
            or_disconnect   <= 1'b0;
        end else begin
            if (w_sync_rst_cnt) begin
                r_no_change_cnt <= '0;
                or_disconnect   <= 1'b0;
            end else if (r_no_change_cnt >= CNT_W'(CNT_DISC)) begin
                r_no_change_cnt <= '0;
                or_disconnect   <= 1'b1;   // 1클럭 pulse
            end else begin
                r_no_change_cnt <= r_no_change_cnt + 1'b1;
                or_disconnect   <= 1'b0;
            end
        end
    end

    assign ow_disconnect = or_disconnect;

    // ── TX 경로 — Pure Digital 통과 ────────────────────────────────
    // Xilinx 이식 시 이 두 assign 을 OBUFDS 인스턴스로 교체
    // (SpW_Xilinx_Porting_Guide.md 참조)
    assign ow_ds_tx_data   = i_tx_data_bit;
    assign ow_ds_tx_strobe = i_tx_strobe_bit;

endmodule
