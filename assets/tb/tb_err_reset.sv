`timescale 1ns/1ps

module tb_err_reset;
    logic clk = 0;
    logic rst_n = 0;
    logic link_en = 0;
    logic link_start = 0;
    logic enc_ready = 1;
    logic disconnect = 0;
    logic parity_err = 0;

    logic        rx_char_valid = 0;
    logic [8:0]  rx_char = 9'b0;

    logic [2:0]  link_state;
    logic        err_disconnect, err_parity, err_esc, err_credit;
    logic        enc_reset;

    always #5 clk = ~clk;

    localparam [1:0] CODE_FCT = 2'b00, CODE_ESC = 2'b11;

    spw_datalink #(.RX_FIFO_DEPTH(128), .MAX_CREDIT(56)) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_en(link_en), .i_link_start(link_start), .i_auto_start(1'b0), .i_port_reset(1'b0),
        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char),
        .i_parity_err(parity_err), .i_disconnect(disconnect),
        .ow_tx_char_valid(), .ow_tx_char(), .i_enc_ready(enc_ready), .ow_enc_reset(enc_reset),
        .i_nchar_data(9'b0), .i_nchar_valid(1'b0), .ow_nchar_ready(),
        .ow_rx_char_data(), .ow_rx_char_valid(), .ow_rx_char_ctrl(),
        .i_rx_free_space(8'd128), .i_tick_in(1'b0), .i_time_in(8'b0),
        .ow_tick_out(), .ow_time_out(),
        .ow_link_state(link_state),
        .ow_err_disconnect(err_disconnect), .ow_err_parity(err_parity),
        .ow_err_esc(err_esc), .ow_err_credit(err_credit), .ow_err_tx_invalid()
    );

    task send_char(logic [8:0] ch);
        @(negedge clk);
        rx_char = ch;
        rx_char_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rx_char_valid = 1'b0;
        #1;
    endtask

    int errors = 0;

    initial begin
        rst_n = 0; #20; rst_n = 1;

        link_en = 1;
        wait (link_state == 3'd2); // READY
        $display("t=%0t: Ready 도달", $time);

        // ── 시나리오 1: disconnect — (A) 결정 반영, 게이팅 없이 즉시 반영 ──
        // spw_datalink 는 이제 r_seen_any_transition 게이트가 없다(spw_phy 로 이전).
        // i_disconnect 가 뜨면 (r_rx_char_valid 수신 여부와 무관하게) 즉시
        // w_valid_disconnect=1 -> ErrorReset 이어야 한다.
        @(negedge clk);
        disconnect = 1'b1;
        @(posedge clk); #1;
        // ow_err_disconnect 는 조합(golden model 방식)이므로 원인이 살아있는
        // 이 시점에 확인
        if (err_disconnect !== 1'b1) begin
            $display("FAIL: disconnect 발생했는데 ow_err_disconnect 미설정"); errors++;
        end else begin
            $display("t=%0t: OK - ow_err_disconnect=1 (조합, 원인 신호와 동시) 확인", $time);
        end
        if (link_state !== 3'd0) begin
            $display("FAIL((A) 결정): 게이팅 없이 disconnect 즉시 ErrorReset 안 됨 (state=%0d)", link_state);
            errors++;
        end else begin
            $display("t=%0t: OK((A) 결정) - disconnect 즉시(게이팅 없이) ErrorReset 확인 (문자 수신 이력 무관)",
                $time);
        end
        disconnect = 1'b0;

        // ── ow_enc_reset 펄스 폭 확인 ──
        #1;
        if (enc_reset !== 1'b0) begin
            $display("FAIL: ErrorReset 진입 1클럭 후에도 ow_enc_reset 이 여전히 1 (pulse 폭 위반)");
            errors++;
        end else begin
            $display("t=%0t: OK - ow_enc_reset 이 1클럭짜리 pulse 로 확인", $time);
        end

        // ── r_seen_any_transition 이 spw_datalink 내부에서 항상 0(미사용)인지 ──
        if (dut.r_seen_any_transition !== 1'b0) begin
            $display("FAIL((A) 결정): r_seen_any_transition 이 0 이 아님 (spw_phy 로 역할 이전됐어야 함)");
            errors++;
        end else begin
            $display("t=%0t: OK((A) 결정) - r_seen_any_transition 이 spw_datalink 내부에서 항상 0(미사용) 확인",
                $time);
        end

        // ── 시나리오 2a: ow_err_parity — gotNull 이전에는 ErrorReset 유발 안 함
        // [DECISION-18 Option B, 2026-09-14] ECSS 5.4.7.a: parity error 검출은
        // gotNull이 assert된 동안에만 활성화돼야 한다. 이 시나리오는 원래
        // "parity_err → 무조건 즉시 ErrorReset"을 기대했었는데, 그건 실제로는
        // r_gotnull_latch 게이팅이 없던(=버그였던) 구버전 동작을 그대로
        // 정답으로 박제해둔 것이었다 — 실측(golden model 직접 주입, dec.
        // parity_error)으로 이 구버전 동작이 표준 위반임을 확인 후 정정.
        // 여기서는 아직 Null을 한 번도 못 받은 상태(gotNull 이전)이므로,
        // ow_err_parity(원인 신호 그대로, 게이팅 없음)는 여전히 뜨지만
        // ErrorReset은 발생하지 않아야 한다.
        link_en = 0; #20; link_en = 1;
        wait (link_state == 3'd2); // READY
        link_start = 1; @(posedge clk); #1; link_start = 0;
        wait (link_state == 3'd3); // STARTED
        @(negedge clk);
        parity_err = 1'b1;
        @(posedge clk); #1;
        if (err_parity !== 1'b1) begin
            $display("FAIL: parity_err 발생했는데 ow_err_parity 미설정"); errors++;
        end else begin
            $display("t=%0t: OK - ow_err_parity=1 (조합, 원인 신호와 동시, 게이팅 없음) 확인", $time);
        end
        if (link_state !== 3'd3) begin
            $display("FAIL: [DECISION-18] gotNull 이전 parity_err 이 ErrorReset 유발함 (state=%0d, 기대: STARTED=3 유지)",
                      link_state);
            errors++;
        end else begin
            $display("t=%0t: OK - [DECISION-18] gotNull 이전 parity_err 무시(ErrorReset 미유발, STARTED 유지) 확인",
                      $time);
        end
        parity_err = 1'b0;
        @(negedge clk);

        // ── 시나리오 2b: 실제 Null(ESC+FCT) 수신 후에는 parity_err 이 여전히
        // ErrorReset을 유발해야 한다 (게이팅이 정상 케이스까지 죽이면 안 됨) ──
        send_char({1'b1, 6'b0, CODE_ESC});
        send_char({1'b1, 6'b0, CODE_FCT});
        wait (link_state == 3'd4); // CONNECTING (Started -> Connecting via w_got_null)
        if (dut.r_gotnull_latch !== 1'b1) begin
            $display("FAIL: [DECISION-18] Null 수신 후에도 r_gotnull_latch 가 안 세워짐"); errors++;
        end else begin
            $display("t=%0t: OK - [DECISION-18] Null 수신 후 r_gotnull_latch=1 확인", $time);
        end
        @(negedge clk);
        parity_err = 1'b1;
        @(posedge clk); #1;
        if (link_state !== 3'd0) begin
            $display("FAIL: [DECISION-18] gotNull 이후에도 parity_err 이 ErrorReset 유발 안 함 (게이팅 과잉)");
            errors++;
        end else begin
            $display("t=%0t: OK - [DECISION-18] gotNull 이후 parity_err 은 여전히 ErrorReset 유발 확인", $time);
        end
        parity_err = 1'b0;

        if (errors == 0) $display("=== ALL ERR/RESET CHECKS PASSED ===");
        else $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #300000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
