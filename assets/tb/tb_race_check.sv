`timescale 1ns/1ps
module tb_race_check;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n;
    logic link_en=0, link_start=0, auto_start=0, port_reset=0;
    logic [2:0] link_state;
    logic [8:0] rx_char = 0; logic rx_char_valid = 0; logic parity_err=0;
    logic [8:0] tx_char; logic tx_char_valid; logic enc_ready=1;
    logic [8:0] nchar_data = 0; logic nchar_valid = 0; logic nchar_ready;
    logic [7:0] rx_free_space = 8'd200;

    localparam [1:0] CODE_FCT=2'b00, CODE_EOP=2'b10, CODE_EEP=2'b01, CODE_ESC=2'b11;

    spw_datalink #(.RX_FIFO_DEPTH(200), .MAX_CREDIT(56), .CNT_6US(640), .CNT_12US(1280)) dut(
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_en(link_en), .i_link_start(link_start), .i_auto_start(auto_start), .i_port_reset(port_reset),
        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char), .i_parity_err(parity_err), .i_disconnect(1'b0),
        .ow_tx_char_valid(tx_char_valid), .ow_tx_char(tx_char), .i_enc_ready(enc_ready), .ow_enc_reset(),
        .i_nchar_data(nchar_data), .i_nchar_valid(nchar_valid), .ow_nchar_ready(nchar_ready),
        .ow_rx_char_data(), .ow_rx_char_valid(), .ow_rx_char_ctrl(),
        .i_rx_free_space(rx_free_space),
        .i_tick_in(1'b0), .i_time_in(8'b0), .ow_tick_out(), .ow_time_out(),
        .ow_link_state(link_state),
        .ow_err_disconnect(), .ow_err_parity(), .ow_err_esc(), .ow_err_credit(), .ow_err_tx_invalid()
    );

    task tick; @(posedge clk); #1; endtask
    task send_char(logic [8:0] ch);
        @(negedge clk);
        rx_char = ch; rx_char_valid = 1;
        @(posedge clk); @(negedge clk);
        rx_char_valid = 0;
        #1;
    endtask

    int guard;
    int errors = 0;
    initial begin
        rst_n=0; repeat(3) tick(); rst_n=1;
        link_en=1;
        repeat(650) tick();
        repeat(1290) tick();
        $display("t=%0t: state=%0d (expect Ready=2)", $time, link_state);
        link_start=1; tick(); link_start=0;
        $display("t=%0t: state=%0d (expect Started=3)", $time, link_state);

        send_char({1'b1,6'b0,CODE_ESC});
        send_char({1'b1,6'b0,CODE_FCT});
        $display("t=%0t: state=%0d (expect Connecting=4)", $time, link_state);

        guard = 0;
        while (link_state != 3'd5 && guard < 200) begin
            tick();
            guard++;
        end
        $display("t=%0t: after %0d ticks, state=%0d req_init=%0d sent_fct=%b got_fct_seen=?",
                  $time, guard, link_state, dut.r_req_initial_fct, dut.r_sent_fct);

        if (link_state != 3'd5) begin
            $display("아직 RUN 아님 -- 독립 FCT 하나 더 수신시켜 gotFCT 성립시도");
            send_char({1'b1,6'b0,CODE_FCT});
            repeat(50) tick();
            $display("t=%0t: state=%0d req_init=%0d sent_fct=%b", $time, link_state, dut.r_req_initial_fct, dut.r_sent_fct);
        end

        if (link_state !== 3'd5) begin
            $display("[FAIL] RUN 도달 실패, 종료");
            errors++;
            $display("=== %0d CHECK(S) FAILED ===", errors);
            $finish;
        end

        $display("t=%0t: RUN 도달! r_tx_credit=%0d", $time, dut.r_tx_credit);

        force dut.r_tx_credit = 6'd10;
        tick();
        release dut.r_tx_credit;
        $display("t=%0t: r_tx_credit forced->10, now=%0d", $time, dut.r_tx_credit);

        nchar_data = 9'h05A; nchar_valid = 1;
        rx_char = {1'b1,6'b0,CODE_FCT}; rx_char_valid = 1;
        @(posedge clk);
        $display("t=%0t: SAME CYCLE check -- w_got_fct=%b w_send_nchar=%b r_tx_credit(pre)=%0d",
                  $time, dut.w_got_fct, dut.w_send_nchar, dut.r_tx_credit);
        #1;
        rx_char_valid = 0; nchar_valid = 0;
        $display("t=%0t: AFTER race cycle, r_tx_credit=%0d (10+8-1=17 expected if both applied, 9 if -1 only wins, 18 if +8 only wins)",
                  $time, dut.r_tx_credit);

        // ── 자동 판정 (2026-09-02 추가, 같은 날 ERRATA-25 해결로 기대값 갱신) ──
        // §5.1 의 always_ff 는 [✅ 해결] 이제 증가/감소 동시 발생 케이스를
        // 명시적 if/else if 로 나열해(선택 B) 둘 다 반영하도록 고쳐졌다.
        // 과거(선택 A, 분리형 두 if 블록)에는 텍스트 순서상 나중 블록이
        // 덮어써 결과가 9(=10-1, +8 유실)였는데, 이제는 old_value+8-1=17이
        // 정확히 나와야 한다. 만약 §5.1이 다시 분리형으로 되돌아가면 이
        // check() 가 FAIL 하여 회귀를 잡아준다.
        if (dut.r_tx_credit === 6'd17) begin
            $display("[PASS] ERRATA-25 해결 확인: 동시 이벤트(FCT수신+N-Char송신) 시 +8/-1 둘 다 반영 (r_tx_credit=17=10+8-1)");
        end else if (dut.r_tx_credit === 6'd9) begin
            errors++;
            $display("[FAIL] r_tx_credit=9 -- ERRATA-25 수정(선택 B) 이전 상태(분리형, +8 유실)로 되돌아간 것으로 보임");
        end else begin
            errors++;
            $display("[FAIL] 예상 밖 r_tx_credit=%0d (17 예상)", dut.r_tx_credit);
        end

        if (errors == 0) $display("=== ALL RACE-CHECK ASSERTIONS PASSED ===");
        else $display("=== %0d CHECK(S) FAILED ===", errors);

        $finish;
    end
    initial begin #5_000_000; $display("[FAIL] timeout"); $finish; end
endmodule
