// =============================================================================
// spw_top.sv
//
// SpaceWire 단일 포트 노드 최상위 통합 모듈.
// spw_phy -> spw_enc -> spw_datalink -> spw_network 4계층을 연결한다.
//
// 기준 문서: HO_06_spw_top_Wiring_v1.md (전체 배선 매트릭스, 실 RTL 대조 완료)
//           HO_04_spw_datalink_Handover_v2.md §3/§4 (spw_phy/enc/datalink 배선 근거)
//           HO_05_spw_network_Handover_v2.md §2/§3 (spw_datalink/network 배선 근거)
//
// 하위 모듈 (전부 개별 iverilog 검증 완료, Phase 1):
//   spw_phy_v2.sv, spw_enc.sv, spw_datalink_v2.sv, spw_network.sv
//
// ⚠️ 이 파일 자체는 spw_top 통합 시뮬레이션(Phase 1, 4모듈 동시 동작 iverilog TB)을
// 아직 거치지 않았다 — 개별 모듈 검증만 완료된 상태에서 배선표 그대로 인스턴스화한
// 것이다. HO_06 §9의 미결 #7(credit 카운터 동시 이벤트 레이스)도 이 통합 단계에서
// 실제로 시뮬레이션해야 한다.
//
// [DECISION-13, 소유권] ow_err_tx_invalid 는 spw_datalink가 아니라 spw_network의
// 출력이다 — spw_top에서 이 포트를 찾을 때 spw_datalink 쪽이 아니라 net 인스턴스
// 쪽을 봐야 한다(HO_06 §6.4).
//
// [리셋] i_rst_n(전체 async, 4개 모듈 전부 팬아웃) vs i_port_reset(spw_datalink에만,
// FSM만 동기 초기화, FIFO는 건드리지 않음 — DECISION-16). spw_network는
// i_port_reset을 받지 않는다(자체 프로토콜 상태가 없으므로 i_rst_n만 받음).
//
// [i_link_reset, v2 핵심] spw_datalink.ow_enc_reset 을 spw_enc.i_enc_reset 뿐
// 아니라 spw_phy.i_link_reset 에도 반드시 팬아웃해야 재연결 데드락이 방지된다
// (HO_06 §4, 빠뜨리면 silent failure).
// =============================================================================

module spw_top #(
    parameter int  CLK_FREQ_HZ           = 100_000_000,
    parameter int  TX_RATE_MBPS          = 10,
    parameter int  DISCONNECT_TIMEOUT_NS = 850,
    parameter int  TX_FIFO_DEPTH         = 128,
    parameter int  RX_FIFO_DEPTH         = 128,
    parameter int  MAX_CREDIT            = 56,
    parameter bit  ENABLE_TIMECODE       = 1
) (
    // ── Clock / Reset ────────────────────────────────────────────
    input  logic i_clk,
    input  logic i_rst_n,          // 전체 async 리셋 (4개 모듈 전부, DECISION-16)

    // ── MIB 제어 (§6.1) ──────────────────────────────────────────
    input  logic i_link_en,
    input  logic i_link_start,
    input  logic i_auto_start,
    input  logic i_port_reset,     // 동기, spw_datalink FSM만 (FIFO 불변)

    // ── 물리 DS 인터페이스 (Pure Digital) ────────────────────────
    input  logic i_ds_rx_data,
    input  logic i_ds_rx_strobe,
    output logic ow_ds_tx_data,
    output logic ow_ds_tx_strobe,

    // ── 사용자 데이터 핀 (§6.2) ──────────────────────────────────
    input  logic [8:0] i_tx_data9,
    input  logic        i_tx_valid,
    output logic        ow_tx_ready,

    output logic [8:0] ow_rx_data9,
    output logic        ow_rx_valid,
    input  logic        i_rx_ready,

    // ── Timecode 핀 (§6.3, spw_network 경유) ─────────────────────
    input  logic        i_tick_in,
    input  logic [7:0]  i_time_in,
    output logic        ow_tick_out,
    output logic [7:0]  ow_time_out,

    // ── 상태/에러 출력 (§6.4) ─────────────────────────────────────
    output logic [2:0] ow_link_state,
    output logic       ow_err_disconnect,  // 조합 미러 (spw_datalink)
    output logic       ow_err_parity,      // 조합 미러 (spw_datalink)
    output logic       ow_err_esc,         // 조합 미러 (spw_datalink)
    output logic       ow_err_credit,      // 조합 미러 (spw_datalink)
    output logic       ow_err_tx_invalid,  // ★ registered pulse, 출처 = spw_network (DECISION-13)
    output logic       ow_disconnect       // spw_phy 원신호 (선택적 top 노출, HO_06 §6.4 참조)
);

    // =========================================================================
    // §7 파라미터 전파 — CNT_6US/CNT_12US는 CLK_FREQ_HZ 기반으로 여기서 계산해
    // spw_datalink에 넘긴다 (직접 상수 하드코딩 금지, HO_06 §7)
    // =========================================================================
    localparam int CNT_6US  = CLK_FREQ_HZ / 1_000_000 * 64 / 10;  // 640 @ 100MHz
    localparam int CNT_12US = CNT_6US * 2;                          // 1280 @ 100MHz

    // =========================================================================
    // 모듈 간 내부 배선 (HO_06 §2~§5)
    // =========================================================================

    // -- spw_phy <-> spw_enc --
    logic w_rx_data_bit, w_rx_strobe_bit;
    logic w_tx_data_bit, w_tx_strobe_bit;

    // -- spw_phy <-> spw_datalink (v2 신규, disconnect 게이팅 일원화) --
    logic w_disconnect;      // spw_phy.ow_disconnect -> spw_datalink.i_disconnect
    logic w_link_reset;      // spw_datalink.ow_enc_reset -> spw_phy.i_link_reset (+ spw_enc.i_enc_reset)

    // -- spw_enc <-> spw_datalink --
    logic        w_enc_reset;        // = w_link_reset (팬아웃 소스, 이름만 구분)
    logic [8:0]  w_tx_char;
    logic        w_tx_char_valid;
    logic        w_enc_ready;        // spw_enc.ow_tx_char_ready -> spw_datalink.i_enc_ready (이름 다름 주의)
    logic [8:0]  w_rx_char;
    logic        w_rx_char_valid;
    logic        w_parity_err;

    // -- spw_datalink <-> spw_network --
    logic [8:0] w_nchar_data;    // spw_network.ow_dl_tx_data -> spw_datalink.i_nchar_data
    logic       w_nchar_valid;   // spw_network.ow_dl_tx_valid -> spw_datalink.i_nchar_valid
    logic       w_nchar_ready;   // spw_datalink.ow_nchar_ready -> spw_network.i_dl_tx_pop

    logic [8:0] w_rx_char_data;  // spw_datalink.ow_rx_char_data -> spw_network.i_dl_rx_data
    logic       w_rx_char_valid_dl; // spw_datalink.ow_rx_char_valid -> spw_network.i_dl_rx_valid
    logic       w_rx_char_ctrl;  // spw_datalink.ow_rx_char_ctrl -> spw_network.i_dl_rx_ctrl

    logic [$clog2(RX_FIFO_DEPTH+1)-1:0] w_rx_free_space; // spw_network -> spw_datalink

    logic       w_dl_tick_in;    // spw_network.ow_dl_tick_in -> spw_datalink.i_tick_in
    logic [7:0] w_dl_time_in;    // spw_network.ow_dl_time_in -> spw_datalink.i_time_in
    logic       w_dl_tick_out;   // spw_datalink.ow_tick_out -> spw_network.i_dl_tick_out
    logic [7:0] w_dl_time_out;   // spw_datalink.ow_time_out -> spw_network.i_dl_time_out

    assign w_enc_reset = w_link_reset;

    // =========================================================================
    // spw_phy
    // =========================================================================
    spw_phy #(
        .CLK_FREQ_HZ          (CLK_FREQ_HZ),
        .DISCONNECT_TIMEOUT_NS(DISCONNECT_TIMEOUT_NS)
    ) u_spw_phy (
        .i_clk           (i_clk),
        .i_rst_n         (i_rst_n),

        .i_link_reset    (w_link_reset),      // HO_06 §4 — 필수 배선

        .i_ds_rx_data    (i_ds_rx_data),
        .i_ds_rx_strobe  (i_ds_rx_strobe),
        .ow_ds_tx_data   (ow_ds_tx_data),
        .ow_ds_tx_strobe (ow_ds_tx_strobe),

        .ow_rx_data_bit  (w_rx_data_bit),
        .ow_rx_strobe_bit(w_rx_strobe_bit),

        .i_tx_data_bit   (w_tx_data_bit),
        .i_tx_strobe_bit (w_tx_strobe_bit),

        .ow_disconnect   (w_disconnect)
    );

    assign ow_disconnect = w_disconnect;

    // =========================================================================
    // spw_enc
    // =========================================================================
    spw_enc #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .TX_RATE_MBPS(TX_RATE_MBPS)
    ) u_spw_enc (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),

        .i_enc_reset  (w_enc_reset),         // HO_06 §3 — spw_datalink.ow_enc_reset 팬아웃

        .i_tx_char       (w_tx_char),
        .i_tx_char_valid (w_tx_char_valid),
        .ow_tx_char_ready(w_enc_ready),       // 이름 다름: enc 쪽 ready -> datalink 쪽 enc_ready

        .ow_rx_char      (w_rx_char),
        .ow_rx_char_valid(w_rx_char_valid),
        .ow_parity_err   (w_parity_err),

        .ow_tx_data_bit  (w_tx_data_bit),
        .ow_tx_strobe_bit(w_tx_strobe_bit),
        .i_rx_data_bit   (w_rx_data_bit),
        .i_rx_strobe_bit (w_rx_strobe_bit)
    );

    // =========================================================================
    // spw_datalink
    // =========================================================================
    spw_datalink #(
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
        .MAX_CREDIT   (MAX_CREDIT),
        .CNT_6US      (CNT_6US),
        .CNT_12US     (CNT_12US)
    ) u_spw_datalink (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),

        .i_link_en    (i_link_en),
        .i_link_start (i_link_start),
        .i_auto_start (i_auto_start),
        .i_port_reset (i_port_reset),

        .i_rx_char_valid(w_rx_char_valid),
        .i_rx_char      (w_rx_char),
        .i_parity_err   (w_parity_err),
        .i_disconnect   (w_disconnect),

        .ow_tx_char_valid(w_tx_char_valid),
        .ow_tx_char      (w_tx_char),
        .i_enc_ready     (w_enc_ready),
        .ow_enc_reset    (w_link_reset),      // HO_06 §4 — spw_phy.i_link_reset 로도 팬아웃(위에서 처리)

        .i_nchar_data (w_nchar_data),
        .i_nchar_valid(w_nchar_valid),
        .ow_nchar_ready(w_nchar_ready),

        .ow_rx_char_data (w_rx_char_data),
        .ow_rx_char_valid(w_rx_char_valid_dl),
        .ow_rx_char_ctrl (w_rx_char_ctrl),

        .i_rx_free_space(w_rx_free_space),

        .i_tick_in (w_dl_tick_in),
        .i_time_in (w_dl_time_in),
        .ow_tick_out(w_dl_tick_out),
        .ow_time_out(w_dl_time_out),

        .ow_link_state    (ow_link_state),
        .ow_err_disconnect(ow_err_disconnect),
        .ow_err_parity    (ow_err_parity),
        .ow_err_esc       (ow_err_esc),
        .ow_err_credit    (ow_err_credit)
        // ow_err_tx_invalid 포트 없음 — [v2, DECISION-13 재배치] spw_network가 대신 생성 (아래)
    );

    // =========================================================================
    // spw_network
    // =========================================================================
    spw_network #(
        .TX_FIFO_DEPTH  (TX_FIFO_DEPTH),
        .RX_FIFO_DEPTH  (RX_FIFO_DEPTH),
        .ENABLE_TIMECODE(ENABLE_TIMECODE)
    ) u_spw_network (
        .i_clk  (i_clk),
        .i_rst_n(i_rst_n),          // i_port_reset 없음 — DECISION-16, 자체 프로토콜 상태 없음

        .i_tx_data9(i_tx_data9),
        .i_tx_valid(i_tx_valid),
        .ow_tx_ready(ow_tx_ready),

        .ow_rx_data9(ow_rx_data9),
        .ow_rx_valid(ow_rx_valid),
        .i_rx_ready (i_rx_ready),

        .ow_err_tx_invalid(ow_err_tx_invalid),  // ★ DECISION-13 출처 — spw_network

        .ow_dl_tx_data (w_nchar_data),
        .ow_dl_tx_valid(w_nchar_valid),
        .i_dl_tx_pop   (w_nchar_ready),

        .i_dl_rx_data (w_rx_char_data),
        .i_dl_rx_valid(w_rx_char_valid_dl),
        .i_dl_rx_ctrl (w_rx_char_ctrl),

        .ow_rx_free_space(w_rx_free_space),

        .i_tick_in(i_tick_in),
        .i_time_in(i_time_in),
        .ow_dl_tick_in(w_dl_tick_in),
        .ow_dl_time_in(w_dl_time_in),

        .i_dl_tick_out(w_dl_tick_out),
        .i_dl_time_out(w_dl_time_out),
        .ow_tick_out  (ow_tick_out),
        .ow_time_out  (ow_time_out)
    );

endmodule
