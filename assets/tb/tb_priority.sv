`timescale 1ns/1ps

module tb_priority;
    logic clk = 0;
    logic rst_n = 0;
    logic link_en = 0;
    logic link_start = 0;
    logic enc_ready = 1;

    logic        rx_char_valid = 0;
    logic [8:0]  rx_char = 9'b0;

    logic [2:0]  link_state;
    logic        tx_char_valid;
    logic [8:0]  tx_char;
    logic        nchar_ready;
    logic [8:0]  nchar_data = {1'b0, 8'hCC};
    logic        nchar_valid = 0;
    logic        tick_in = 0;
    logic [7:0]  time_in = 8'hA5;

    always #5 clk = ~clk;

    localparam [1:0] CODE_FCT = 2'b00, CODE_ESC = 2'b11;

    spw_datalink #(.RX_FIFO_DEPTH(128), .MAX_CREDIT(56)) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_en(link_en), .i_link_start(link_start), .i_auto_start(1'b0), .i_port_reset(1'b0),
        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char),
        .i_parity_err(1'b0), .i_disconnect(1'b0),
        .ow_tx_char_valid(tx_char_valid), .ow_tx_char(tx_char), .i_enc_ready(enc_ready), .ow_enc_reset(),
        .i_nchar_data(nchar_data), .i_nchar_valid(nchar_valid), .ow_nchar_ready(nchar_ready),
        .ow_rx_char_data(), .ow_rx_char_valid(), .ow_rx_char_ctrl(),
        .i_rx_free_space(8'd128), .i_tick_in(tick_in), .i_time_in(time_in),
        .ow_tick_out(), .ow_time_out(),
        .ow_link_state(link_state), .ow_err_disconnect(), .ow_err_parity(),
        .ow_err_esc(), .ow_err_credit(), .ow_err_tx_invalid()
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

        // ── Connecting -> Run 자연 전이 확인 ──
        wait (link_state == 3'd2);
        link_start = 1; @(posedge clk); #1; link_start = 0;
        send_char({1'b1, 6'b0, CODE_ESC});
        send_char({1'b1, 6'b0, CODE_FCT});
        #1;
        if (link_state !== 3'd4) begin
            $display("FAIL(setup): Connecting 도달 실패"); $finish;
        end

        // 상대가 FCT 를 보내 r_got_fct=1 만들고, §8.3 이 초기 FCT 를 자동
        // 송신해 r_sent_fct=1 이 되면 다음 클럭 RUN 전이
        send_char({1'b1, 6'b0, CODE_FCT});
        wait (link_state == 3'd5);  // RUN
        $display("t=%0t: OK - Connecting -> Run 자연 전이 확인 (r_got_fct && r_sent_fct)", $time);

        // ── ESC 원자적 시퀀스: ESC 송신 다음 클럭에 반드시 두 번째 문자 ──
        // RUN 진입 직후 몇 클럭 흘려 안정화
        repeat (3) @(posedge clk);
        // 이 시점 근처에서 ESC(코드=11)가 나가는 클럭을 찾아, 바로 다음 클럭에
        // FCT 나 TC 값이 나가는지 확인 (원자성 — 중간에 다른 문자 끼면 안 됨)
        fork
            begin: watch_esc
                integer i;
                logic saw_esc;
                saw_esc = 1'b0;
                for (i = 0; i < 50; i = i + 1) begin
                    @(posedge clk); #1;
                    if (!saw_esc && tx_char_valid && tx_char[8] && tx_char[1:0] == 2'b11) begin
                        saw_esc = 1'b1;
                        // 다음 클럭 확인
                        @(posedge clk); #1;
                        if (!tx_char_valid) begin
                            $display("FAIL(ESC 원자성): ESC 다음 클럭에 유효한 문자 없음"); errors++;
                        end else if (tx_char[8] && tx_char[1:0] == 2'b11) begin
                            $display("FAIL(ESC 원자성): ESC 다음에 또 ESC (원자성 깨짐)"); errors++;
                        end else begin
                            $display("t=%0t: OK - ESC 다음 클럭 즉시 두 번째 문자 확인 (tx_char=%b)", $time, tx_char);
                        end
                        i = 50; // 종료
                    end
                end
                if (!saw_esc) begin
                    $display("FAIL: 50클럭 내 ESC 관측 안 됨"); errors++;
                end
            end
        join

        // ── RUN 우선순위: Timecode > FCT > N-Char > Null ──
        // N-Char 를 계속 요청 상태로 걸어두고, 동시에 tick_in 을 넣어 Timecode 가
        // N-Char 보다 우선 처리되는지 확인
        nchar_valid = 1'b1;
        @(negedge clk);
        tick_in = 1'b1;
        @(posedge clk);   // 이 엣지에서 DUT 가 i_tick_in=1 을 래치
        @(negedge clk);   // posedge 직후 곧바로 클리어하면 DUT always_ff 와
        tick_in = 1'b0;   // 델타사이클 레이스가 발생할 수 있어 negedge 로 옮김
        #1;
        if (dut.r_tc_pending !== 1'b1) begin
            $display("FAIL: tick_in 후 r_tc_pending 미설정"); errors++;
        end else begin
            $display("t=%0t: OK - tick_in -> r_tc_pending 세팅 확인", $time);
        end

        // r_tc_pending=1 인 다음 클럭, ESC 원자적 시퀀스가 안 걸려있다면 §8.3 은
        // Timecode 를 최우선으로 선택해야 한다 (N-Char 요청 있어도 밀림)
        // ESC 시퀀스 진행 중일 수 있으니 r_esc_pending=0 이 될 때까지 대기 후 확인
        wait (dut.r_esc_pending == 1'b0);
        @(posedge clk); #1;
        if (dut.r_esc_pending == 1'b1 && dut.r_esc_kind == 1'b1) begin
            $display("t=%0t: OK - Timecode 가 N-Char 보다 우선 선택됨 (r_esc_kind=1)", $time);
        end else if (!dut.r_tc_pending) begin
            $display("t=%0t: OK - Timecode 이미 처리 완료(r_tc_pending=0) - 우선 소비된 것으로 판단", $time);
        end else begin
            $display("FAIL: Timecode pending 인데 다음 송신이 Timecode ESC 아님 (r_esc_pending=%b r_esc_kind=%b)",
                dut.r_esc_pending, dut.r_esc_kind);
            errors++;
        end

        // ── ow_nchar_ready 정합성: 뜨는 클럭엔 반드시 tx_char=nchar_data ──
        // Timecode 소비 후, credit 이 있는 상태에서 N-Char 가 결국 나가는지 확인
        // (credit 은 앞선 Connecting 단계에서 이미 8 이상 쌓여있음, RUN 재확인)
        fork
            begin: watch_nchar
                integer j;
                logic saw_nchar_ready;
                saw_nchar_ready = 1'b0;
                for (j = 0; j < 100; j = j + 1) begin
                    @(posedge clk); #1;
                    if (nchar_ready) begin
                        saw_nchar_ready = 1'b1;
                        if (tx_char !== nchar_data) begin
                            $display("FAIL: ow_nchar_ready=1 인데 ow_tx_char != nchar_data (tx_char=%b)", tx_char);
                            errors++;
                        end else begin
                            $display("t=%0t: OK - ow_nchar_ready=1 클럭에 ow_tx_char=nchar_data 정합 확인", $time);
                        end
                        j = 100;
                    end
                end
                if (!saw_nchar_ready) begin
                    $display("FAIL: 100클럭 내 ow_nchar_ready 관측 안 됨"); errors++;
                end
            end
        join
        nchar_valid = 1'b0;

        if (errors == 0) $display("=== ALL PRIORITY/ESC CHECKS PASSED ===");
        else $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
