`timescale 1ns/1ps

module tb_credit;
    logic clk = 0;
    logic rst_n = 0;
    logic link_en = 0;
    logic link_start = 0;
    logic enc_ready = 0;   // 처음엔 0으로 묶어 §8 자동 송신을 막아두고 필요할 때만 연다

    logic        rx_char_valid = 0;
    logic [8:0]  rx_char = 9'b0;

    logic [2:0]  link_state;
    logic        err_credit;
    logic        tx_char_valid;
    logic [8:0]  tx_char;

    always #5 clk = ~clk;

    localparam [1:0] CODE_FCT = 2'b00, CODE_EOP = 2'b10, CODE_EEP = 2'b01, CODE_ESC = 2'b11;

    spw_datalink #(.RX_FIFO_DEPTH(128), .MAX_CREDIT(56)) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_en(link_en), .i_link_start(link_start), .i_auto_start(1'b0), .i_port_reset(1'b0),
        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char),
        .i_parity_err(1'b0), .i_disconnect(1'b0),
        .ow_tx_char_valid(tx_char_valid), .ow_tx_char(tx_char), .i_enc_ready(enc_ready), .ow_enc_reset(),
        .i_nchar_data(9'b0), .i_nchar_valid(1'b0), .ow_nchar_ready(),
        .ow_rx_char_data(), .ow_rx_char_valid(), .ow_rx_char_ctrl(),
        .i_rx_free_space(8'd128), .i_tick_in(1'b0), .i_time_in(8'b0),
        .ow_tick_out(), .ow_time_out(),
        .ow_link_state(link_state), .ow_err_disconnect(), .ow_err_parity(),
        .ow_err_esc(), .ow_err_credit(err_credit), .ow_err_tx_invalid()
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

    // Connecting 까지 진행 (enc_ready=0 상태 유지 -> §8 자동 송신 없음, credit 순수 수신만 관찰)
    task goto_connecting;
        wait (link_state == 3'd2); // READY
        link_start = 1;
        @(posedge clk); #1;
        link_start = 0;
        send_char({1'b1, 6'b0, CODE_ESC});
        send_char({1'b1, 6'b0, CODE_FCT});
        #1;
        if (link_state !== 3'd4) begin
            $display("FAIL(setup): Connecting 도달 실패 (state=%0d)", link_state);
            $finish;
        end
    endtask

    int errors = 0;

    initial begin
        rst_n = 0; #20; rst_n = 1;
        link_en = 1;
        enc_ready = 0;  // §8 자동 송신 억제 — 수신측 credit(r_tx_credit) 만 순수 관찰

        goto_connecting();
        $display("t=%0t: Connecting 도달 (enc_ready=0, 송신 억제 상태), credit 테스트 시작", $time);

        // ── 시나리오 1: ERRATA-20 — Connecting 상태에서 FCT 수신 시 r_tx_credit 증가 ──
        if (dut.r_tx_credit !== 6'd0) begin
            $display("FAIL: Connecting 진입 직후 r_tx_credit != 0 (%0d)", dut.r_tx_credit); errors++;
        end
        send_char({1'b1, 6'b0, CODE_FCT});  // 독립 FCT 수신 (Connecting 중)
        #1;
        if (dut.r_tx_credit !== 6'd8) begin
            $display("FAIL(ERRATA-20): Connecting 중 FCT 수신했는데 r_tx_credit 증가 안 함 (%0d)", dut.r_tx_credit);
            errors++;
        end else begin
            $display("t=%0t: OK(ERRATA-20) - Connecting 중 FCT 수신 -> r_tx_credit=8 확인", $time);
        end

        // ── 시나리오 2: credit_error — r_tx_credit 을 56까지 채운 뒤 초과 FCT 주입 ──
        repeat (6) send_char({1'b1, 6'b0, CODE_FCT});  // +8*6 = 48, 총 8+48=56
        #1;
        if (dut.r_tx_credit !== 6'd56) begin
            $display("FAIL: 누적 FCT 수신 후 r_tx_credit != 56 (%0d)", dut.r_tx_credit); errors++;
        end else begin
            $display("t=%0t: OK - 누적 FCT 7회 수신 -> r_tx_credit=56(MAX) 확인", $time);
        end

        // 8번째 FCT: 56+8=64 > 56 -> credit_error. ow_err_credit 은 이제
        // 조합(golden model 방식) 이므로 i_rx_char_valid 가 아직 살아있는
        // 시점(문자 전송 클럭 그 자체)에 확인해야 한다 — send_char() 은 호출이
        // 끝나면 이미 rx_char_valid 를 0 으로 내린 뒤이므로 여기서는 태스크를
        // 쓰지 않고 직접 시퀀싱한다.
        @(negedge clk);
        rx_char = {1'b1, 6'b0, CODE_FCT};
        rx_char_valid = 1'b1;
        @(posedge clk); #1;
        if (err_credit !== 1'b1) begin
            $display("FAIL: MAX_CREDIT 초과 FCT 수신했는데 ow_err_credit 미설정"); errors++;
        end else begin
            $display("t=%0t: OK - ow_err_credit=1 (조합, 원인 신호와 동시) 확인", $time);
        end
        rx_char_valid = 1'b0;
        if (dut.r_tx_credit !== 6'd56) begin
            $display("FAIL: credit_error 발생했는데 r_tx_credit 이 그대로 56 유지 안 됨 (%0d, 가산 금지 위반)",
                dut.r_tx_credit);
            errors++;
        end else begin
            $display("t=%0t: OK - credit_error 시 r_tx_credit 가산 금지(56 유지) 확인", $time);
        end
        // Connecting 중이므로 credit_error 는 즉시 ErrorReset 을 유발하지 않는다
        // (§3.3: w_immediate_error 의 credit_err 조건은 RUN 전용)
        if (link_state !== 3'd4) begin
            $display("FAIL: Connecting 중 credit_error 가 잘못 즉시 ErrorReset 유발 (state=%0d)", link_state);
            errors++;
        end else begin
            $display("t=%0t: OK - Connecting 중 credit_error 는 즉시 ErrorReset 유발 안 함 확인", $time);
        end

        // ── 시나리오 3: §8.3 실제 자동 송신 관찰 (ERRATA-11/20 정합성) ──
        // ErrorReset 부터 새로 시작, enc_ready=1 로 열어 §8 이 실제로 초기 FCT 를
        // 자동 송신하는 과정에서 r_rx_credit 이 "독립 FCT 송신 횟수 x 8" 만큼만
        // 증가하고, Null 유휴 필러(ESC+FCT 두 클럭)는 증가에 관여하지 않는지 확인.
        link_en = 0; #20; link_en = 1;
        enc_ready = 1;
        goto_connecting();
        $display("t=%0t: Connecting 재도달 (enc_ready=1, §8 자동 송신 활성)", $time);

        // r_req_initial_fct = min(128/8,7) = 7 이므로, §8.3 최우선순위(초기 FCT)가
        // 매 클럭 FCT 를 내보낸다 (enc_ready=1, i_rx_free_space=128 로 조건 항상 만족).
        // 7클럭 기다리면 r_req_initial_fct 가 0 이 되고 r_rx_credit = 7*8 = 56 이어야 함.
        repeat (10) @(posedge clk);
        #1;
        if (dut.r_req_initial_fct !== 3'd0) begin
            $display("FAIL: 10클럭 후에도 r_req_initial_fct 소진 안 됨 (%0d)", dut.r_req_initial_fct);
            errors++;
        end
        if (dut.r_rx_credit !== 6'd56) begin
            $display("FAIL: 초기 FCT 7회 자동 송신 후 r_rx_credit != 56 (%0d, 예상: 7*8=56)", dut.r_rx_credit);
            errors++;
        end else begin
            $display("t=%0t: OK - §8.3 초기 FCT 7회 자동 송신 -> r_rx_credit=56 확인 (독립 FCT만 계상)",
                $time);
        end

        // 이제 r_req_initial_fct=0, w_fct_send_ok 도 r_rx_credit=56 > 48 이라 거짓
        // (§7.1: r_rx_credit <= MAX_CREDIT-8=48 이어야 함) -> §8.3 은 4순위 Null
        // 필러로 넘어가야 한다. Null 은 ESC+FCT 두 클럭짜리 w_send_second 이므로
        // r_rx_credit 을 추가로 증가시키면 안 된다 (ERRATA-11 핵심).
        begin
            logic [5:0] credit_before;
            credit_before = dut.r_rx_credit;
            repeat (4) @(posedge clk);  // Null(ESC+FCT) 최소 2클럭 이상 흘려보냄
            #1;
            if (dut.r_rx_credit !== credit_before) begin
                $display("FAIL(ERRATA-11): 초기FCT 소진 후 Null 유휴 필러가 r_rx_credit 을 추가로 증가시킴 (%0d -> %0d)",
                    credit_before, dut.r_rx_credit);
                errors++;
            end else begin
                $display("t=%0t: OK(ERRATA-11) - 초기FCT 소진 후 Null 유휴 필러 기간 r_rx_credit 불변(=%0d) 확인",
                    $time, dut.r_rx_credit);
            end
        end

        if (errors == 0) $display("=== ALL CREDIT CHECKS PASSED ===");
        else $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #400000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
