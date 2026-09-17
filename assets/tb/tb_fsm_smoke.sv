// FSM 단독 스모크 테스트 (§5~9 미구현 상태 — timer 전이만 검증)
`timescale 1ns/1ps

module tb_fsm_smoke;
    logic clk = 0;
    logic rst_n = 0;

    logic link_en = 0;
    logic link_start = 0;
    logic auto_start = 0;
    logic port_reset = 0;

    logic [2:0] link_state;

    always #5 clk = ~clk;

    spw_datalink #(
        .RX_FIFO_DEPTH(128),
        .MAX_CREDIT(56),
        .CNT_6US(640),
        .CNT_12US(1280)
    ) dut (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_link_en(link_en),
        .i_link_start(link_start),
        .i_auto_start(auto_start),
        .i_port_reset(port_reset),
        .i_rx_char_valid(1'b0),
        .i_rx_char(9'b0),
        .i_parity_err(1'b0),
        .i_disconnect(1'b0),
        .ow_tx_char_valid(),
        .ow_tx_char(),
        .i_enc_ready(1'b1),
        .ow_enc_reset(),
        .i_nchar_data(9'b0),
        .i_nchar_valid(1'b0),
        .ow_nchar_ready(),
        .ow_rx_char_data(),
        .ow_rx_char_valid(),
        .ow_rx_char_ctrl(),
        .i_rx_free_space('0),
        .i_tick_in(1'b0),
        .i_time_in(8'b0),
        .ow_tick_out(),
        .ow_time_out(),
        .ow_link_state(link_state),
        .ow_err_disconnect(),
        .ow_err_parity(),
        .ow_err_esc(),
        .ow_err_credit(),
        .ow_err_tx_invalid()
    );

    initial begin
        $display("t=%0t: start", $time);
        rst_n = 0;
        #20;
        rst_n = 1;

        // reset 직후 link_en=0 상태이므로 ErrorReset에 고정되어야 함 (immediate_error)
        #100;
        if (link_state !== 3'd0) begin
            $display("FAIL: link_en=0 인데 ErrorReset을 벗어남 (state=%0d)", link_state);
            $finish;
        end
        $display("t=%0t: OK - link_en=0 동안 ErrorReset 고정 확인 (timer hold 동작)", $time);

        // link_en=1 로 올린 시점부터 타이머 시작
        link_en = 1;
        $display("t=%0t: link_en=1", $time);

        // ErrorReset(640clk) -> ErrorWait 전이 대기
        wait (link_state == 3'd1);
        $display("t=%0t: ErrorReset -> ErrorWait 전이 확인", $time);

        // ErrorWait(1280clk) -> Ready 전이 대기
        wait (link_state == 3'd2);
        $display("t=%0t: ErrorWait -> Ready 전이 확인", $time);

        // Ready에서 link_start 없이는 머물러야 함
        #200;
        if (link_state !== 3'd2) begin
            $display("FAIL: link_start=0 인데 Ready 를 벗어남");
            $finish;
        end
        $display("t=%0t: OK - Ready 에서 link_start=0 이면 유지 확인", $time);

        // link_start=1 -> Started 전이
        link_start = 1;
        @(posedge clk);
        #1;
        if (link_state !== 3'd3) begin
            $display("FAIL: link_start=1 인데 Started 로 전이 안 함 (state=%0d)", link_state);
            $finish;
        end
        $display("t=%0t: OK - link_start=1 -> Started 전이 확인", $time);

        // Started 에서 gotNull 없이 CNT_12US 경과 -> ErrorReset 로 타임아웃
        link_start = 0;
        wait (link_state == 3'd0);
        $display("t=%0t: OK - Started 에서 gotNull 없이 타임아웃 -> ErrorReset 확인", $time);

        $display("=== ALL FSM SMOKE CHECKS PASSED ===");
        $finish;
    end

    // 무한루프 방지
    initial begin
        #100000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
