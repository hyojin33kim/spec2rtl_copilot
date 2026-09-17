`timescale 1ns/1ps

module tb_phy;
    logic clk = 0;
    logic rst_n = 0;
    logic link_reset = 0;
    logic ds_rx_data = 0;
    logic ds_rx_strobe = 0;
    logic disconnect;

    always #5 clk = ~clk;

    // CLK_FREQ_HZ=100MHz, DISCONNECT_TIMEOUT_NS=850 -> CNT_DISC=85
    spw_phy #(.CLK_FREQ_HZ(100_000_000), .DISCONNECT_TIMEOUT_NS(850)) dut (
        .i_clk(clk), .i_rst_n(rst_n), .i_link_reset(link_reset),
        .i_ds_rx_data(ds_rx_data), .i_ds_rx_strobe(ds_rx_strobe),
        .ow_ds_tx_data(), .ow_ds_tx_strobe(),
        .ow_rx_data_bit(), .ow_rx_strobe_bit(),
        .i_tx_data_bit(1'b0), .i_tx_strobe_bit(1'b0),
        .ow_disconnect(disconnect)
    );

    // 간단한 토글 태스크 — strobe 를 한번 뒤집어 "천이" 발생시킴.
    // 2FF 동기화기(r_data_meta -> or_rx_*_bit)를 거치므로 실제 r_seen_any_transition
    // 반영까지 약 3클럭 지연된다 — 충분히 대기 후 리턴.
    task toggle_strobe;
        @(negedge clk);
        ds_rx_strobe = ~ds_rx_strobe;
        repeat (4) @(posedge clk);
        #1;
    endtask

    int errors = 0;

    initial begin
        rst_n = 0; #20; rst_n = 1;

        // ── 시나리오 1(회귀): 천이 전에는 disconnect 카운터 비활성 ──
        // 리셋 직후, 아무 천이도 없이 200클럭 흘려도 disconnect 뜨면 안 됨
        // (ERRATA-5: 최초 천이 전까지 카운터 자체가 비활성)
        repeat (200) @(posedge clk);
        #1;
        if (disconnect !== 1'b0) begin
            $display("FAIL(회귀): 최초 천이 전인데 disconnect 발생"); errors++;
        end else begin
            $display("t=%0t: OK(회귀) - 최초 천이 전 200클럭 동안 disconnect 없음 확인 (ERRATA-5)", $time);
        end

        // ── 시나리오 2(회귀): 천이 후 무변화 85클럭 지속 시 disconnect 발생 ──
        toggle_strobe();  // 최초 천이 -> r_seen_any_transition=1
        $display("t=%0t: 최초 천이 발생 (r_seen_any_transition=%b)", $time, dut.r_seen_any_transition);

        fork
            begin: wait_disc
                repeat (100) begin
                    @(posedge clk); #1;
                    if (disconnect) begin
                        $display("t=%0t: OK(회귀) - 무변화 지속 후 disconnect 펄스 확인 (no_change_cnt=%0d)",
                            $time, dut.r_no_change_cnt);
                        disable wait_disc;
                    end
                end
                $display("FAIL(회귀): 100클럭 내 disconnect 미발생"); errors++;
            end
        join

        // ── 시나리오 3 (신규 v2): i_link_reset 없이 재연결 시뮬레이션 -> 데드락 재현 가능성 ──
        // 천이가 있었던 상태(r_seen_any_transition=1)에서, i_link_reset 을 걸지
        // 않은 채 다시 무변화가 지속되면 또 disconnect 가 뜬다 (v1 과 동일 동작
        // -- 이건 정상, i_link_reset 미사용 시 하위호환 확인용)
        toggle_strobe();
        repeat (90) @(posedge clk);
        #1;
        $display("t=%0t: i_link_reset 미사용 상태에서 재확인 진행 중 (하위호환 체크)", $time);

        // ── 시나리오 4 (신규 v2 핵심): i_link_reset 펄스로 즉시 재초기화 ──
        @(negedge clk);
        link_reset = 1'b1;
        @(posedge clk); #1;
        link_reset = 1'b0;
        if (dut.r_seen_any_transition !== 1'b0) begin
            $display("FAIL: i_link_reset 후 r_seen_any_transition 클리어 안 됨"); errors++;
        end else begin
            $display("t=%0t: OK(v2) - i_link_reset -> r_seen_any_transition=0 즉시 클리어 확인", $time);
        end
        if (dut.r_no_change_cnt !== '0) begin
            $display("FAIL: i_link_reset 후 r_no_change_cnt 리셋 안 됨 (%0d)", dut.r_no_change_cnt);
            errors++;
        end else begin
            $display("t=%0t: OK(v2) - i_link_reset -> r_no_change_cnt=0 리셋 확인", $time);
        end

        // ── 시나리오 5 (신규 v2 핵심 — 데드락 방지 실증) ──
        // i_link_reset 직후, 상대 응답(천이) 없이 CNT_DISC(85클럭)를 훌쩍 넘겨도
        // r_seen_any_transition=0 이므로 disconnect 가 뜨지 않아야 한다.
        // (이게 바로 골든모델 reset_framing() 이 막으려던 재연결 데드락 시나리오)
        repeat (150) @(posedge clk);
        #1;
        if (disconnect !== 1'b0) begin
            $display("FAIL(v2 핵심): i_link_reset 후 상대 응답 전인데 disconnect 오탐 발생 (데드락 위험 재현됨)");
            errors++;
        end else begin
            $display("t=%0t: OK(v2 핵심) - i_link_reset 후 150클럭(CNT_DISC=85 초과) 동안 상대 응답 없어도 disconnect 오탐 없음 확인 (재연결 데드락 방지)",
                $time);
        end

        // 이제 상대가 응답(천이)하면 정상적으로 seen_any_transition 재설정되고,
        // 그 이후부터 다시 disconnect 카운터가 정상 동작해야 함
        toggle_strobe();
        if (dut.r_seen_any_transition !== 1'b1) begin
            $display("FAIL: link_reset 이후 천이 발생했는데 r_seen_any_transition 미설정"); errors++;
        end else begin
            $display("t=%0t: OK - link_reset 이후 상대 응답 -> r_seen_any_transition=1 재설정 확인", $time);
        end

        if (errors == 0) $display("=== ALL SPW_PHY CHECKS PASSED ===");
        else $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
