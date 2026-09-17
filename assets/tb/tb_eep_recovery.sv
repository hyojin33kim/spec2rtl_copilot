`timescale 1ns/1ps
// =============================================================================
// tb_eep_recovery — ERRATA-18 (RX측 EEP 자동 복구, ECSS 5.5.8.4.a.2) 전용 RTL TB
//
// golden model 시나리오 18/20/21 에 대응하는 RTL 검증:
//   1) 기본 케이스 — DATA 만 수신한 채(EOP/EEP 없이) 에러 발생 -> 다음 클럭에
//      RX FIFO 로 EEP 가 자동 삽입되는지 (i_rx_free_space 여유 있는 경우)
//   2) FIFO full 대기 — i_rx_free_space=0 인 동안 eep_pending 이 레벨 신호로
//      계속 유지되고(1클럭 pulse 아님), 그동안 w_fct_send_ok(credit 부여)가
//      막혀 있는지, 공간이 나는 순간 즉시 EEP 가 써지는지
//   3) 유휴 대조군 — 미완성 패킷이 없었으면 eep_pending 이 무장되지 않는지
// =============================================================================
module tb_eep_recovery;
    logic clk = 0;
    logic rst_n = 0;
    logic link_en = 0;
    logic link_start = 0;
    logic enc_ready = 1;   // 이 TB는 DUT 자신의 정상 송신(초기 FCT 등)도 필요하므로 항상 열어둠

    logic        rx_char_valid = 0;
    logic [8:0]  rx_char = 9'b0;
    logic [$clog2(129)-1:0] rx_free_space = 8'd128;

    logic [2:0]  link_state;
    logic [8:0]  rx_out_data;
    logic        rx_out_valid, rx_out_ctrl;
    logic        tx_char_valid;
    logic [8:0]  tx_char;

    always #5 clk = ~clk;

    localparam [1:0] CODE_FCT = 2'b00, CODE_EOP = 2'b10, CODE_EEP = 2'b01, CODE_ESC = 2'b11;

    spw_datalink #(.RX_FIFO_DEPTH(128), .MAX_CREDIT(56)) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_en(link_en), .i_link_start(link_start), .i_auto_start(1'b0), .i_port_reset(port_reset),
        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char),
        .i_parity_err(1'b0), .i_disconnect(1'b0),
        .ow_tx_char_valid(tx_char_valid), .ow_tx_char(tx_char), .i_enc_ready(enc_ready), .ow_enc_reset(),
        .i_nchar_data(9'b0), .i_nchar_valid(1'b0), .ow_nchar_ready(),
        .ow_rx_char_data(rx_out_data), .ow_rx_char_valid(rx_out_valid), .ow_rx_char_ctrl(rx_out_ctrl),
        .i_rx_free_space(rx_free_space), .i_tick_in(1'b0), .i_time_in(8'b0),
        .ow_tick_out(), .ow_time_out(),
        .ow_link_state(link_state), .ow_err_disconnect(), .ow_err_parity(),
        .ow_err_esc(), .ow_err_credit(), .ow_err_tx_invalid()
    );

    logic port_reset = 0;

    task send_char(logic [8:0] ch);
        @(negedge clk);
        rx_char = ch;
        rx_char_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rx_char_valid = 1'b0;
        #1;
    endtask

    task goto_run;
        wait (link_state == 3'd2); // READY
        link_start = 1;
        @(posedge clk); #1;
        link_start = 0;
        send_char({1'b1, 6'b0, CODE_ESC});
        send_char({1'b1, 6'b0, CODE_FCT});   // Null -> gotNull -> Started->Connecting
        #1;
        if (link_state !== 3'd4) begin
            $display("FAIL(setup): Connecting 도달 실패 (state=%0d)", link_state);
            $finish;
        end
        send_char({1'b1, 6'b0, CODE_FCT});   // 독립 FCT 수신 -> gotFCT (DUT 자체 초기FCT는 enc_ready=1로 자동 송신)
        wait (link_state == 3'd5);          // RUN
        #1;
    endtask

    int errors = 0;

    initial begin
        rst_n = 0; #20; rst_n = 1;
        link_en = 1;
        goto_run();
        $display("t=%0t: RUN 도달, ERRATA-18 검증 시작", $time);

        // ── 시나리오 1: 기본 케이스 — DATA 3개, EOP 없이, FIFO 여유 있음 ──
        rx_free_space = 8'd128;
        send_char({1'b0, 8'h10});
        if (dut.r_rx_pkt_in_progress !== 1'b1) begin
            $display("FAIL: DATA 수신 후 r_rx_pkt_in_progress 미설정"); errors++;
        end
        send_char({1'b0, 8'h20});
        send_char({1'b0, 8'h30});

        port_reset = 1;
        @(posedge clk); #1;
        port_reset = 0;
        if (link_state !== 3'd0) begin
            $display("FAIL: port_reset 후 ErrorReset 진입 안 함 (state=%0d)", link_state); errors++;
        end
        if (dut.r_eep_pending !== 1'b1) begin
            $display("FAIL: 미완성 패킷 있었는데 r_eep_pending 무장 안 됨"); errors++;
        end else begin
            $display("t=%0t: OK - port_reset 후 r_eep_pending=1 확인", $time);
        end

        // w_eep_write_now 는 콤비네이셔널(레벨) 신호라, r_eep_pending 이 1이
        // 되는 바로 그 클럭(free_space 여유 있음)에 이미 함께 뜬다 -- 클럭을
        // 더 기다리면 이미 r_eep_pending 이 해소된 뒤라 놓친다.
        if (!(rx_out_valid === 1'b1 && rx_out_ctrl === 1'b1 && rx_out_data[1:0] === CODE_EEP)) begin
            $display("FAIL: 같은 클럭에 EEP 자동 삽입 안 됨 (valid=%b ctrl=%b data=%b)",
                rx_out_valid, rx_out_ctrl, rx_out_data);
            errors++;
        end else begin
            $display("t=%0t: OK - EEP 자동 삽입 확인 (rx_out_data=%b)", $time, rx_out_data);
        end

        @(posedge clk); #1;   // 다음 클럭엔 r_eep_pending 이 해소되어 있어야 함
        if (dut.r_eep_pending !== 1'b0) begin
            $display("FAIL: EEP 삽입 후 r_eep_pending 해소 안 됨"); errors++;
        end else if (rx_out_valid !== 1'b0) begin
            $display("FAIL: r_eep_pending 해소 후에도 EEP 가 계속 나감(펄스 아니어야 정상 종료)"); errors++;
        end else begin
            $display("t=%0t: OK - r_eep_pending 해소 및 EEP 출력 종료 확인", $time);
        end

        // ── 시나리오 2: FIFO full 대기 (레벨 신호) + credit 인터록 ──
        link_en = 0; #20; link_en = 1;
        rx_free_space = 8'd128;
        goto_run();
        $display("t=%0t: RUN 재도달, FIFO-full 케이스 시작", $time);

        rx_free_space = 8'd0;   // FIFO 꽉 참 시뮬레이션
        send_char({1'b0, 8'h40});
        send_char({1'b0, 8'h41});

        port_reset = 1;
        @(posedge clk); #1;
        port_reset = 0;
        if (dut.r_eep_pending !== 1'b1) begin
            $display("FAIL: FIFO full 케이스에서 r_eep_pending 무장 안 됨"); errors++;
        end

        repeat (50) begin
            @(posedge clk); #1;
            if (dut.r_eep_pending !== 1'b1) begin
                $display("FAIL: FIFO 여전히 full 인데 r_eep_pending 이 풀려버림 (레벨 신호 아님?)");
                errors++;
            end
            if (rx_out_valid === 1'b1) begin
                $display("FAIL: FIFO full 인데도 EEP(또는 다른 문자) 가 RX 로 나감"); errors++;
            end
            if (dut.w_fct_send_ok !== 1'b0) begin
                $display("FAIL(인터록): eep_pending 동안 w_fct_send_ok 가 떠서 새 credit 부여 위험");
                errors++;
            end
        end
        $display("t=%0t: OK - FIFO full 50클럭 동안 eep_pending 유지 + credit 인터록 확인", $time);

        rx_free_space = 8'd128;  // 이제 공간이 생김 (콤비네이셔널, 클럭 엣지 기다리지 않음)
        #1;
        if (!(rx_out_valid === 1'b1 && rx_out_ctrl === 1'b1 && rx_out_data[1:0] === CODE_EEP)) begin
            $display("FAIL: 공간이 생긴 즉시(같은 클럭) EEP 삽입 안 됨"); errors++;
        end else begin
            $display("t=%0t: OK - 공간 생기자 즉시 EEP 삽입 확인", $time);
        end
        if (dut.r_eep_pending !== 1'b1) begin
            $display("FAIL: 아직 클럭 엣지 전인데 r_eep_pending 이 벌써 해소됨(타이밍 이상)"); errors++;
        end
        @(posedge clk); #1;   // 클럭 엣지를 지나야 r_eep_pending 이 실제로 해소된다
        if (dut.r_eep_pending !== 1'b0) begin
            $display("FAIL: 지연된 EEP 삽입 후에도 r_eep_pending 해소 안 됨"); errors++;
        end else begin
            $display("t=%0t: OK - 지연 삽입 후 r_eep_pending 해소 확인", $time);
        end

        // ── 시나리오 3: 유휴 대조군 — 미완성 패킷 없으면 무장 안 됨 ──
        link_en = 0; #20; link_en = 1;
        rx_free_space = 8'd128;
        goto_run();
        send_char({1'b0, 8'h01});
        send_char({1'b1, 6'b0, CODE_EOP});   // 정상 종료
        if (dut.r_rx_pkt_in_progress !== 1'b0) begin
            $display("FAIL: EOP 수신 후 r_rx_pkt_in_progress 안 지워짐"); errors++;
        end
        port_reset = 1;
        @(posedge clk); #1;
        port_reset = 0;
        if (dut.r_eep_pending !== 1'b0) begin
            $display("FAIL(대조군): 미완성 패킷 없었는데 r_eep_pending 이 무장됨"); errors++;
        end else begin
            $display("t=%0t: OK(대조군) - 유휴 상태 에러 시 eep_pending 무장 안 됨 확인", $time);
        end

        if (errors == 0) $display("=== ALL EEP-RECOVERY (ERRATA-18) CHECKS PASSED ===");
        else $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
