`timescale 1ns/1ps

module tb_esc_rx;
    logic clk = 0;
    logic rst_n = 0;
    logic link_en = 0;
    logic link_start = 0;

    logic        rx_char_valid = 0;
    logic [8:0]  rx_char = 9'b0;

    logic [2:0]  link_state;
    logic [8:0]  rx_char_data;
    logic        rx_char_valid_out;
    logic        rx_char_ctrl;
    logic        tick_out;
    logic [7:0]  time_out;

    always #5 clk = ~clk;

    // 제어 코드: FCT=00 EOP=10 EEP=01 ESC=11 (spw_enc.sv 실제 포맷)
    localparam [1:0] CODE_FCT = 2'b00, CODE_EOP = 2'b10, CODE_EEP = 2'b01, CODE_ESC = 2'b11;

    spw_datalink dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_en(link_en), .i_link_start(link_start), .i_auto_start(1'b0), .i_port_reset(1'b0),
        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char),
        .i_parity_err(1'b0), .i_disconnect(1'b0),
        .ow_tx_char_valid(), .ow_tx_char(), .i_enc_ready(1'b1), .ow_enc_reset(),
        .i_nchar_data(9'b0), .i_nchar_valid(1'b0), .ow_nchar_ready(),
        .ow_rx_char_data(rx_char_data), .ow_rx_char_valid(rx_char_valid_out), .ow_rx_char_ctrl(rx_char_ctrl),
        .i_rx_free_space('0), .i_tick_in(1'b0), .i_time_in(8'b0),
        .ow_tick_out(tick_out), .ow_time_out(time_out),
        .ow_link_state(link_state), .ow_err_disconnect(), .ow_err_parity(),
        .ow_err_esc(), .ow_err_credit(), .ow_err_tx_invalid()
    );

    task send_char(logic [8:0] ch);
        @(negedge clk);
        rx_char = ch;
        rx_char_valid = 1'b1;
        @(posedge clk);   // DUT가 이 엣지에서 값을 래치
        @(negedge clk);
        rx_char_valid = 1'b0;
        #1;
    endtask

    int errors = 0;

    initial begin
        rst_n = 0; #20; rst_n = 1;
        link_en = 1;

        // ErrorReset(640) -> ErrorWait(1280) -> Ready 까지 대기
        wait (link_state == 3'd2); // READY
        $display("t=%0t: Ready 도달", $time);

        link_start = 1;
        @(posedge clk); #1;
        if (link_state !== 3'd3) begin // STARTED
            $display("FAIL: link_start 후 Started 전이 안 함"); errors++;
        end
        link_start = 0;
        $display("t=%0t: Started 도달", $time);

        // ── 시나리오 1: Null(ESC+FCT) 수신 -> Started -> Connecting ──
        send_char({1'b1, 6'b0, CODE_ESC});   // ESC
        #1;
        if (dut.r_rx_pending_esc !== 1'b1) begin
            $display("FAIL: ESC 수신 후 r_rx_pending_esc 미설정"); errors++;
        end
        send_char({1'b1, 6'b0, CODE_FCT});   // FCT -> Null 완성
        #1;
        if (link_state !== 3'd4) begin // CONNECTING
            $display("FAIL: Null 수신 후 Connecting 전이 안 함 (state=%0d)", link_state); errors++;
        end else begin
            $display("t=%0t: OK - Null(ESC+FCT) 수신 -> Started->Connecting 전이 확인", $time);
        end

        // ── 시나리오 2: Connecting 에서 N-Char(DATA) 수신 -> protocol_violation -> ErrorReset ──
        // 주의(§8 구현 이후): §8.3 이 Connecting 에서 초기 FCT 를 자동 송신하므로
        // r_sent_fct 가 자연스럽게 SET 될 수 있다 — 독립 FCT 를 수신시켜 r_got_fct
        // 까지 세팅하면 그 다음 클럭에 §3.3 조건(r_got_fct && r_sent_fct)이 충족돼
        // RUN 으로 자연 전이해버려 이 시나리오(Connecting 상태 유지 확인)를 검증할
        // 수 없게 된다. 따라서 Connecting 진입 직후, 독립 FCT 수신 이전에 먼저
        // DATA 를 주입해 protocol_violation 을 확인한다.
        send_char({1'b0, 8'hAB});  // DATA
        #1;
        if (link_state !== 3'd0) begin // ERROR_RESET
            $display("FAIL: Connecting 에서 DATA 수신했는데 ErrorReset 안 됨 (state=%0d)", link_state); errors++;
        end else begin
            $display("t=%0t: OK - Connecting DATA 수신 -> protocol_violation -> ErrorReset 확인", $time);
        end

        // ── 시나리오 3: Connecting 재도달 후 독립 FCT 수신 -> w_got_fct (에러 아님) ──
        // ErrorReset 부터 다시 Ready->Started->Connecting 진행
        link_en = 0; #20; link_en = 1;
        wait (link_state == 3'd2); // READY
        link_start = 1; @(posedge clk); #1; link_start = 0;
        send_char({1'b1, 6'b0, CODE_ESC});
        send_char({1'b1, 6'b0, CODE_FCT});
        #1;
        if (link_state !== 3'd4) begin
            $display("FAIL(setup2): Connecting 재도달 실패 (state=%0d)", link_state); errors++;
        end
        send_char({1'b1, 6'b0, CODE_FCT});
        #1;
        if (dut.r_got_fct !== 1'b1) begin
            $display("FAIL: Connecting 에서 독립 FCT 수신 후 r_got_fct 미설정"); errors++;
        end else begin
            $display("t=%0t: OK - Connecting 독립 FCT 수신 -> r_got_fct 확인 (state=%0d, RUN 자연전이 가능)",
                $time, link_state);
        end
        // 이 시점 state 는 4(Connecting 유지) 또는 5(RUN 자연전이) 모두 정상 —
        // §8.3 이 그 클럭까지 초기FCT/일반FCT 를 몇 번 보냈는지에 따라 달라짐.
        // RUN 전이 자체가 §3.5 스펙대로이므로 에러 처리하지 않는다.

        // ── 시나리오 4: ErrorWait 중 순수 FCT 수신 -> protocol_violation(ERRATA-3) ──
        link_en = 0; #20; link_en = 1;
        wait (link_state == 3'd1); // ERROR_WAIT
        $display("t=%0t: ErrorWait 도달, 순수 FCT 주입", $time);
        send_char({1'b1, 6'b0, CODE_FCT});
        #1;
        if (link_state !== 3'd0) begin
            $display("FAIL: ErrorWait 에서 순수 FCT 수신했는데 ErrorReset 안 됨 (ERRATA-3)"); errors++;
        end else begin
            $display("t=%0t: OK - ErrorWait 순수 FCT 수신 -> ErrorReset (ERRATA-3) 확인", $time);
        end

        // ── 시나리오 5: RUN 상태 시뮬레이션 없이, ESC+EOP(비FCT/DATA) 조합의 esc_error 단독 검증 ──
        // (RUN 도달은 §5/§8 미구현이라 이 단계에서 불가 — 순수 comb 조합만 강제 확인)
        rx_char = 9'b0; rx_char_valid = 0;
        force dut.r_rx_pending_esc = 1'b1;
        force dut.i_rx_char_valid  = 1'b1;
        force dut.i_rx_char        = {1'b1, 6'b0, CODE_EOP};  // ESC 다음 EOP = 위반
        #1;
        if (dut.w_esc_error !== 1'b1) begin
            $display("FAIL: ESC 다음 EOP 도착 시 w_esc_error 미설정"); errors++;
        end else begin
            $display("t=%0t: OK - ESC 다음 비FCT/DATA 도착 -> w_esc_error 확인", $time);
        end
        release dut.r_rx_pending_esc;
        release dut.i_rx_char_valid;
        release dut.i_rx_char;

        if (errors == 0) $display("=== ALL ESC-RX CHECKS PASSED ===");
        else $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
