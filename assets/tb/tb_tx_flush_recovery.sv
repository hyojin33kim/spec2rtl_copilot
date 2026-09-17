`timescale 1ns/1ps
// =============================================================================
// tb_tx_flush_recovery — ERRATA-26 (TX측 잔여 바이트 flush) 전용 RTL TB
//
// golden model 시나리오 22/23 에 대응하는 RTL 검증. spw_network 의 실제 TX
// FIFO는 없으므로, 이 TB 자체가 SystemVerilog queue 로 작은 TX FIFO를 흉내
// 낸다 (i_nchar_data/i_nchar_valid 를 그 queue 로 드라이브하고, ow_nchar_ready
// 가 뜨면 pop).
//
//   1) 기본 케이스 — DATA 잔여가 큐에 남은 채(EOP 이전) 에러 발생 -> 그 잔여가
//      전혀 인코더로 나가지 않고(discard) 다음 EOP/EEP 까지 조용히 버려지는지
//   2) 유휴 대조군 — 미송신 패킷이 없었으면 r_tx_flushing 이 무장되지 않는지
//   3) 재연결 후 새 패킷이 정상적으로 (버려지지 않고) 전송되는지
// =============================================================================
module tb_tx_flush_recovery;
    logic clk = 0;
    logic rst_n = 0;
    logic link_en = 0;
    logic link_start = 0;
    logic enc_ready = 1;

    logic        rx_char_valid = 0;
    logic [8:0]  rx_char = 9'b0;
    logic        port_reset = 0;

    logic [2:0]  link_state;
    logic        tx_char_valid;
    logic [8:0]  tx_char;
    logic        nchar_ready;

    // ── TX FIFO 흉내 (SystemVerilog queue) ──────────────────────
    // ⚠️ iverilog 이슈: always_comb 는 tx_q.size()/tx_q[0] 같은 큐 메서드
    // 호출의 변화를 암묵적 sensitivity list 에 제대로 못 잡는다 (다른
    // always_ff 블록에서 pop_front() 로 큐가 비어도 always_comb 가 재평가
    // 안 되고 이전 값에 고정되는 걸 실측으로 확인). 그래서 pop 과 peek
    // 재계산을 같은 always_ff 블록 안에서 블로킹 대입으로 처리한다 —
    // 이러면 매 클럭엣지 직후 즉시 갱신되어 그 사이클 내내 안정적으로
    // 유지된다(이 TB 안에서는 클럭엣지 사이에 tx_q 를 건드리는 다른
    // 경로가 없으므로 이 방식으로 충분하다).
    logic [8:0] tx_q[$];
    logic       nchar_valid = 1'b0;
    logic [8:0] nchar_data  = 9'b0;
    always_ff @(posedge clk) begin
        if (nchar_ready && tx_q.size() > 0) tx_q.pop_front();
        if (tx_q.size() > 0) begin
            nchar_valid <= 1'b1;   // non-blocking -- 진짜 동기 FIFO처럼 다음
            nchar_data  <= tx_q[0];// 클럭에 반영(같은 엣지의 DUT NBA 로직과
        end else begin            // 경쟁하지 않도록. blocking(=) 대입은 실행
            nchar_valid <= 1'b0;   // 순서가 미정인 always 블록 간 레이스를
            nchar_data  <= 9'b0;   // 유발함(실측으로 확인: 1개가 안 빠지고 남음)
        end
    end

    always #5 clk = ~clk;

    localparam [1:0] CODE_FCT = 2'b00, CODE_EOP = 2'b10, CODE_EEP = 2'b01, CODE_ESC = 2'b11;

    spw_datalink #(.RX_FIFO_DEPTH(128), .MAX_CREDIT(56)) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_en(link_en), .i_link_start(link_start), .i_auto_start(1'b0), .i_port_reset(port_reset),
        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char),
        .i_parity_err(1'b0), .i_disconnect(1'b0),
        .ow_tx_char_valid(tx_char_valid), .ow_tx_char(tx_char), .i_enc_ready(enc_ready), .ow_enc_reset(),
        .i_nchar_data(nchar_data), .i_nchar_valid(nchar_valid), .ow_nchar_ready(nchar_ready),
        .ow_rx_char_data(), .ow_rx_char_valid(), .ow_rx_char_ctrl(),
        .i_rx_free_space(8'd128), .i_tick_in(1'b0), .i_time_in(8'b0),
        .ow_tick_out(), .ow_time_out(),
        .ow_link_state(link_state), .ow_err_disconnect(), .ow_err_parity(),
        .ow_err_esc(), .ow_err_credit(), .ow_err_tx_invalid()
    );

    // 실제로 인코더로 "송신"된 것만 기록 (w_send_nchar 가 뜬 클럭만 -- flush로
    // 버려진 pop 은 w_send_nchar 가 안 뜨므로 여기 안 잡힘)
    logic [8:0] sent_log[$];
    always_ff @(posedge clk) begin
        if (dut.w_send_nchar) sent_log.push_back(dut.w_tx_char);
    end

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
        send_char({1'b1, 6'b0, CODE_FCT});
        #1;
        if (link_state !== 3'd4) begin
            $display("FAIL(setup): Connecting 도달 실패 (state=%0d)", link_state);
            $finish;
        end
        send_char({1'b1, 6'b0, CODE_FCT});
        wait (link_state == 3'd5);
        #1;
    endtask

    int errors = 0;
    int sent_log_baseline;

    initial begin
        rst_n = 0; #20; rst_n = 1;
        link_en = 1;
        goto_run();
        $display("t=%0t: RUN 도달, ERRATA-26 검증 시작", $time);

        // ── 시나리오 1: 기본 케이스 — DATA 50개 + EOP 를 큐에 채우고, 몇 개만
        //    나간 상태에서 에러를 걸어 나머지가 그대로 잔류하게 만든다.
        for (int i = 0; i < 50; i++) tx_q.push_back({1'b0, 8'(i)});
        tx_q.push_back({1'b1, 6'b0, CODE_EOP});
        // 몇 클럭만 흘려보내 일부만 나가게 함 (credit=56 이라 credit 부족은 아니고,
        // 그냥 시간을 짧게 줘서 "다 못 보낸 채" 로 만드는 것)
        repeat (30) @(posedge clk);
        #1;
        if (tx_q.size() == 0) begin
            $display("FAIL(setup): 30클럭 만에 51개가 다 나가버림 -- 테스트 전제 무효"); errors++;
        end
        sent_log_baseline = sent_log.size();
        $display("t=%0t: 사전조건 - tx_q 잔여 %0d개, sent_log %0d개(baseline)", $time, tx_q.size(), sent_log_baseline);

        port_reset = 1;
        @(posedge clk); #1;
        port_reset = 0;
        if (link_state !== 3'd0) begin
            $display("FAIL: port_reset 후 ErrorReset 진입 안 함 (state=%0d)", link_state); errors++;
        end
        if (dut.r_tx_flushing !== 1'b1) begin
            $display("FAIL: 미송신 패킷 있었는데 r_tx_flushing 무장 안 됨"); errors++;
        end else begin
            $display("t=%0t: OK - port_reset 후 r_tx_flushing=1 확인", $time);
        end

        // flush 가 끝날 때까지 기다린다 (다음 EOP를 buffer 에서 발견하면 종료)
        begin
            int guard;
            guard = 0;
            while (dut.r_tx_flushing === 1'b1 && guard < 2000) begin
                @(posedge clk); #1;
                guard++;
            end
            if (dut.r_tx_flushing !== 1'b0) begin
                $display("FAIL: r_tx_flushing 이 2000클럭 내에 해소 안 됨(가드 초과)"); errors++;
            end else begin
                $display("t=%0t: OK - r_tx_flushing 이 %0d클럭 만에 해소됨", $time, guard);
            end
        end
        if (tx_q.size() != 0) begin
            $display("FAIL: flush 종료 후에도 tx_q 에 잔여가 남음 (%0d개)", tx_q.size()); errors++;
        end
        if (sent_log.size() != sent_log_baseline) begin
            $display("FAIL(ERRATA-26): flush 중 잔여 바이트가 실제로 '송신'(w_send_nchar)됨 -- leak! sent_log 크기=%0d (baseline=%0d)",
                sent_log.size(), sent_log_baseline); errors++;
        end else begin
            $display("t=%0t: OK(ERRATA-26) - flush 도중 아무것도 실제 송신되지 않음 (leak 없음) 확인", $time);
        end

        // 재연결 후 새 패킷이 정상적으로 (버려지지 않고) 나가는지 확인
        goto_run();
        $display("t=%0t: 재연결 -> RUN 재도달", $time);
        tx_q.push_back({1'b0, 8'h99});
        tx_q.push_back({1'b0, 8'h88});
        tx_q.push_back({1'b1, 6'b0, CODE_EOP});
        begin
            int guard2;
            guard2 = 0;
            while (sent_log.size() < sent_log_baseline + 3 && guard2 < 3000) begin
                @(posedge clk); #1;
                guard2++;
            end
        end
        if (sent_log.size() < sent_log_baseline + 3) begin
            $display("FAIL: flush 이후 새 패킷이 정상 송신되지 않음 (sent_log=%0d개)", sent_log.size());
            errors++;
        end else begin
            $display("t=%0t: OK - flush 이후 새 패킷 정상 송신 확인 (sent_log 크기=%0d)", $time, sent_log.size());
        end

        // ── 시나리오 2: 유휴 대조군 — 미송신 패킷 없으면 무장 안 됨 ──
        link_en = 0; #20; link_en = 1;
        tx_q.delete();
        sent_log.delete();
        goto_run();
        tx_q.push_back({1'b0, 8'h01});
        tx_q.push_back({1'b1, 6'b0, CODE_EOP});
        begin
            int guard3;
            guard3 = 0;
            while (tx_q.size() > 0 && guard3 < 3000) begin
                @(posedge clk); #1;
                guard3++;
            end
        end
        if (dut.r_tx_pkt_in_progress !== 1'b0) begin
            $display("FAIL: EOP 까지 정상 송신했는데 r_tx_pkt_in_progress 안 지워짐"); errors++;
        end

        port_reset = 1;
        @(posedge clk); #1;
        port_reset = 0;
        if (dut.r_tx_flushing !== 1'b0) begin
            $display("FAIL(대조군): 미송신 패킷 없었는데 r_tx_flushing 이 무장됨"); errors++;
        end else begin
            $display("t=%0t: OK(대조군) - 유휴 상태 에러 시 tx_flushing 무장 안 됨 확인", $time);
        end

        if (errors == 0) $display("=== ALL TX-FLUSH-RECOVERY (ERRATA-26) CHECKS PASSED ===");
        else $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #1000000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
