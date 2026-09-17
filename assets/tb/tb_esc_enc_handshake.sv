// =============================================================================
// tb_esc_enc_handshake.sv — spw_datalink <-> spw_enc ESC/Null 원자적 시퀀스
// (두 번째 문자, FCT) 완성 핸드셰이크 전용 단위 테스트 (Phase 1, iverilog)
//
// 목적: tb_spw_top_loopback.sv 2노드 통합 테스트에서 관찰된
//   "ESC 전송 후 두 번째 문자(FCT)가 encoder busy 구간에서 유실되고,
//    다음 ESC 가 그 자리를 대신 차지한다(ESC->ESC 중복)"
// 버그를, spw_top 풀스택(2노드, PHY 포함) 없이 spw_datalink + spw_enc
// 단 둘만으로 최소 재현/회귀 감시한다.
//
// 근거 (root cause, 이번 세션에서 코드 리딩으로 확정):
//   spw_datalink.sv §8.3 always_comb 의 최우선 분기
//       if (r_esc_pending) begin
//           w_send_second = 1'b1;
//           ...
//       end
//   는 다른 모든 분기(Timecode/FCT/N-Char/Null, 657~700행)와 달리
//   `i_enc_ready` 조건이 전혀 없다. r_esc_pending 도 w_send_second 가 뜨면
//   (712~724행) i_enc_ready 와 무관하게 그 클럭에 곧바로 0 으로 클리어된다.
//   즉 ESC 전송 시작 바로 다음 클럭에 — 실제로는 encoder 가 아직 ESC 비트를
//   시프트 중(busy, BIT_PERIOD_CYCLES=10 이면 문자당 40클럭 소요)이라
//   ow_tx_char_ready=0 인데도 — "두 번째 문자(FCT) 전송 완료"로 잘못
//   간주해버린다. 실제 FCT 는 encoder 가 busy라 로드되지 않고 그냥
//   버려지고, encoder 가 다시 idle 이 되면 §8.3 은 (r_esc_pending 이 이미
//   0 이므로) Null 우선순위 분기를 새로 타 ESC 를 또 보낸다 — 이것이
//   현장에서 본 "ESC -> ESC 중복" 증상이다.
//
// 방법: 단일 spw_datalink + spw_enc 를, encoder 자신의 TX D/S 라인을
// 그대로 자신의 RX 입력에 되먹임(self-loopback)해서 연결한다. 이러면
// spw_enc 가 실제로 "무엇을 물리 선(wire)에 실었는지"를 spw_enc 자신의
// RX 디코더가 그대로 복원하므로, 두 번째 노드나 spw_phy 없이도
// "ESC 다음에 정말 FCT가 왔는가"를 문자 단위로 직접, 빠르게 관찰할 수
// 있다 (2노드 spw_top 풀스택 대비 훨씬 빠르고 원인 지점에 국한된 재현).
//
// 판정 규칙 (invariant): 링크가 Started(3) 이상에 도달한 뒤, 디코딩된
// 임의의 ESC(code=11) 제어문자는 반드시 그 다음에 오는 문자가
// FCT(code=00) 이어야 한다(Null 원자적 완성). 그 사이에 다른 ESC 나
// data-shaped 문자(Timecode 등)가 끼어들면 FAIL.
// =============================================================================
`timescale 1ns/1ps

module tb_esc_enc_handshake;

    localparam int CLK_FREQ_HZ   = 100_000_000; // 10ns period, spw_enc 기본값과 동일
    localparam int RX_FIFO_DEPTH = 128;

    logic i_clk = 0;
    logic i_rst_n;
    always #5 i_clk = ~i_clk;   // 100MHz

    // ── datalink 제어 입력 ──────────────────────────────────────
    logic link_en = 0, link_start = 0, auto_start = 0, port_reset = 0;
    logic [2:0] link_state;

    // ── datalink <-> enc 문자 인터페이스 ─────────────────────────
    logic        tx_char_valid, tx_char_ready, enc_reset_pulse;
    logic [8:0]  tx_char;
    logic        rx_char_valid, parity_err;
    logic [8:0]  rx_char;

    // ── enc 자기 자신에게 되먹임 (self-loopback D/S 라인) ────────
    logic w_ds_data, w_ds_strobe;

    // 에러 관찰용 (참고 표시만, FAIL 판정에는 미사용)
    logic err_disc, err_par, err_esc_o, err_credit;

    spw_datalink #(
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH), .MAX_CREDIT(56),
        .CNT_6US(640), .CNT_12US(1280)
    ) dut (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_link_en(link_en), .i_link_start(link_start),
        .i_auto_start(auto_start), .i_port_reset(port_reset),

        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char),
        .i_parity_err(parity_err), .i_disconnect(1'b0),

        .ow_tx_char_valid(tx_char_valid), .ow_tx_char(tx_char),
        .i_enc_ready(tx_char_ready), .ow_enc_reset(enc_reset_pulse),

        .i_nchar_data(9'b0), .i_nchar_valid(1'b0), .ow_nchar_ready(),

        .ow_rx_char_data(), .ow_rx_char_valid(), .ow_rx_char_ctrl(),

        .i_rx_free_space(8'(RX_FIFO_DEPTH)),

        .i_tick_in(1'b0), .i_time_in(8'b0),
        .ow_tick_out(), .ow_time_out(),

        .ow_link_state(link_state),
        .ow_err_disconnect(err_disc), .ow_err_parity(err_par),
        .ow_err_esc(err_esc_o), .ow_err_credit(err_credit),
        .ow_err_tx_invalid()
    );

    spw_enc #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .TX_RATE_MBPS(10)
    ) uenc (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_enc_reset(enc_reset_pulse),

        .i_tx_char(tx_char), .i_tx_char_valid(tx_char_valid),
        .ow_tx_char_ready(tx_char_ready),

        .ow_rx_char(rx_char), .ow_rx_char_valid(rx_char_valid),
        .ow_parity_err(parity_err),

        .ow_tx_data_bit(w_ds_data), .ow_tx_strobe_bit(w_ds_strobe),
        .i_rx_data_bit(w_ds_data),  .i_rx_strobe_bit(w_ds_strobe)   // ★ self-loopback
    );

    // ---------------------------------------------------------------
    // 판정 로직: ESC(code=11) 뒤에는 반드시 FCT(code=00) 만 와야 함
    // ---------------------------------------------------------------
    int checks = 0;
    int errors = 0;
    bit expect_fct = 1'b0;
    bit monitoring = 1'b0;   // link_state >= Started(3) 되면 관찰 시작

    always_ff @(posedge i_clk) begin
        if (link_state >= 3'd3) monitoring <= 1'b1;

        if (monitoring && rx_char_valid) begin
            if (rx_char[8]) begin
                // control 문자 (FCT/EEP/EOP/ESC, code = rx_char[1:0])
                if (expect_fct) begin
                    checks <= checks + 1;
                    if (rx_char[1:0] !== 2'b00) begin
                        errors <= errors + 1;
                        $display("t=%0t: [FAIL] ESC 다음에 FCT 가 아닌 control 문자 도착 (code=%b) -- Null 원자성 깨짐 (ESC 중복/유실 의심)",
                                  $time, rx_char[1:0]);
                    end
                    expect_fct <= 1'b0;
                end else if (rx_char[1:0] == 2'b11) begin
                    expect_fct <= 1'b1;   // ESC 시작 -- 다음 문자는 반드시 FCT(Null 완성) 이어야 함
                end
                // 독립 FCT(credit 요청) 등 그 외 control 문자는 그대로 통과
            end else begin
                // data-shaped 문자 (이 TB 는 Timecode/N-Char 를 안 쏘므로 오면 이상)
                if (expect_fct) begin
                    checks <= checks + 1;
                    errors <= errors + 1;
                    $display("t=%0t: [FAIL] ESC 다음에 data-shaped 문자 도착 -- Null 원자성 깨짐", $time);
                    expect_fct <= 1'b0;
                end
            end
        end
    end

    initial begin
        $display("=== tb_esc_enc_handshake: spw_datalink<->spw_enc ESC/Null 원자성 단위 테스트 ===");
        i_rst_n = 0;
        #20;
        i_rst_n = 1;

        link_en = 1;
        wait (link_state == 3'd2);   // Ready
        $display("t=%0t: Ready 도달", $time);

        link_start = 1;
        @(posedge i_clk); #1;
        link_start = 0;
        $display("t=%0t: link_start pulse, Started 진입 (state=%0d)", $time, link_state);

        // Null(ESC+FCT) 을 충분히 많이 반복 관찰. BIT_PERIOD_CYCLES=10 이면
        // 문자 하나 송신에 40클럭이 걸리므로, 매 Null 마다 encoder busy 구간이
        // 반드시 끼어든다 -- handshake 결함이 있으면 초반 몇 회 안에 드러난다.
        #2_000_000;  // 2ms 관찰 (100MHz 기준 200,000 클럭)

        $display("=== tb_esc_enc_handshake summary: %0d checks, %0d FAILED ===", checks, errors);
        if (checks == 0)
            $display("[FAIL] ESC 문자가 한 번도 관찰되지 않음 -- 링크가 Started 까지도 도달 못했을 가능성 (선행 조건 재확인 필요)");
        else if (errors == 0)
            $display("[PASS] ESC/Null 원자성 %0d회 전부 정상 (FCT 유실/중복 없음)", checks);
        else
            $display("[FAIL] ESC/Null 원자성 위반 %0d/%0d 건 발생", errors, checks);

        $finish;
    end

    // 무한루프 방지
    initial begin
        #3_000_000;
        $display("[FAIL] timeout -- 링크가 끝내 Started 에 못 미치거나 시뮬레이션이 멈춤");
        $finish;
    end

endmodule
