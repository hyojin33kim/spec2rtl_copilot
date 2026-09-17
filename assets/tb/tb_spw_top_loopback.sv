// =============================================================================
// tb_spw_top_loopback.sv — spw_top 2노드 루프백 통합 스모크 테스트 (Phase 1, iverilog)
//
// 목적: HO_06_spw_top_Wiring_v1.md 배선표대로 작성한 spw_top.sv가 개별 모듈
// 단위 검증을 넘어 "실제로 링크가 붙고 데이터가 왕복하는지" 통합 레벨에서
// 확인한다. DECISION-14(auto_start 비대칭)에 따라 노드 A는 link_start로
// 콜드부트를 개시하고, 노드 B는 auto_start로 응답한다.
// =============================================================================
`timescale 1ns/1ps

module tb_spw_top_loopback;

    localparam int CLK_FREQ_HZ = 100_000_000; // 100MHz, 10ns period
    localparam int RX_FIFO_DEPTH = 128;
    localparam int TX_FIFO_DEPTH = 128;

    logic i_clk = 0;
    logic i_rst_n;

    always #5 i_clk = ~i_clk; // 10ns period -> 100MHz

    // ---- Node A ----
    logic       a_link_en=0, a_link_start=0, a_auto_start=0, a_port_reset=0;
    logic [8:0] a_tx_data9=0; logic a_tx_valid=0; logic a_tx_ready;
    logic [8:0] a_rx_data9;   logic a_rx_valid;   logic a_rx_ready=0;
    logic       a_tick_in=0; logic [7:0] a_time_in=0;
    logic       a_tick_out;  logic [7:0] a_time_out;
    logic [2:0] a_link_state;
    logic       a_err_disc, a_err_par, a_err_esc, a_err_credit, a_err_txinv, a_disc;
    logic       a_ds_tx_data, a_ds_tx_strobe;
    logic       a_ds_rx_data, a_ds_rx_strobe; // driven FROM node B

    // ---- Node B ----
    logic       b_link_en=0, b_link_start=0, b_auto_start=0, b_port_reset=0;
    logic [8:0] b_tx_data9=0; logic b_tx_valid=0; logic b_tx_ready;
    logic [8:0] b_rx_data9;   logic b_rx_valid;   logic b_rx_ready=0;
    logic       b_tick_in=0; logic [7:0] b_time_in=0;
    logic       b_tick_out;  logic [7:0] b_time_out;
    logic [2:0] b_link_state;
    logic       b_err_disc, b_err_par, b_err_esc, b_err_credit, b_err_txinv, b_disc;
    logic       b_ds_tx_data, b_ds_tx_strobe;
    logic       b_ds_rx_data, b_ds_rx_strobe; // driven FROM node A

    // 물리 루프백 배선: A의 TX -> B의 RX, B의 TX -> A의 RX
    assign b_ds_rx_data   = a_ds_tx_data;
    assign b_ds_rx_strobe = a_ds_tx_strobe;
    assign a_ds_rx_data   = b_ds_tx_data;
    assign a_ds_rx_strobe = b_ds_tx_strobe;

    spw_top #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .TX_FIFO_DEPTH(TX_FIFO_DEPTH), .RX_FIFO_DEPTH(RX_FIFO_DEPTH)
    ) node_a (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_link_en(a_link_en), .i_link_start(a_link_start), .i_auto_start(a_auto_start), .i_port_reset(a_port_reset),
        .i_ds_rx_data(a_ds_rx_data), .i_ds_rx_strobe(a_ds_rx_strobe),
        .ow_ds_tx_data(a_ds_tx_data), .ow_ds_tx_strobe(a_ds_tx_strobe),
        .i_tx_data9(a_tx_data9), .i_tx_valid(a_tx_valid), .ow_tx_ready(a_tx_ready),
        .ow_rx_data9(a_rx_data9), .ow_rx_valid(a_rx_valid), .i_rx_ready(a_rx_ready),
        .i_tick_in(a_tick_in), .i_time_in(a_time_in), .ow_tick_out(a_tick_out), .ow_time_out(a_time_out),
        .ow_link_state(a_link_state),
        .ow_err_disconnect(a_err_disc), .ow_err_parity(a_err_par), .ow_err_esc(a_err_esc),
        .ow_err_credit(a_err_credit), .ow_err_tx_invalid(a_err_txinv), .ow_disconnect(a_disc)
    );

    spw_top #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .TX_FIFO_DEPTH(TX_FIFO_DEPTH), .RX_FIFO_DEPTH(RX_FIFO_DEPTH)
    ) node_b (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_link_en(b_link_en), .i_link_start(b_link_start), .i_auto_start(b_auto_start), .i_port_reset(b_port_reset),
        .i_ds_rx_data(b_ds_rx_data), .i_ds_rx_strobe(b_ds_rx_strobe),
        .ow_ds_tx_data(b_ds_tx_data), .ow_ds_tx_strobe(b_ds_tx_strobe),
        .i_tx_data9(b_tx_data9), .i_tx_valid(b_tx_valid), .ow_tx_ready(b_tx_ready),
        .ow_rx_data9(b_rx_data9), .ow_rx_valid(b_rx_valid), .i_rx_ready(b_rx_ready),
        .i_tick_in(b_tick_in), .i_time_in(b_time_in), .ow_tick_out(b_tick_out), .ow_time_out(b_time_out),
        .ow_link_state(b_link_state),
        .ow_err_disconnect(b_err_disc), .ow_err_parity(b_err_par), .ow_err_esc(b_err_esc),
        .ow_err_credit(b_err_credit), .ow_err_tx_invalid(b_err_txinv), .ow_disconnect(b_disc)
    );

    int errors = 0;
    int checks = 0;

    task automatic check(string name, logic cond);
        checks++;
        if (!cond) begin errors++; $display("[FAIL] %s @ %0t", name, $time); end
        else $display("[PASS] %s", name);
    endtask

    // RUN = 3'd5 (spw_datalink 상태 인코딩, HO_06 §6.4 표 참조)
    localparam logic [2:0] ST_RUN = 3'd5;

    task automatic wait_for_run(int max_cycles);
        int n;
        n = 0;
        while ((a_link_state != ST_RUN || b_link_state != ST_RUN) && n < max_cycles) begin
            @(posedge i_clk);
            n++;
        end
    endtask

    initial begin : err_monitor_b
        forever begin
            @(posedge i_clk);
            if (b_err_disc || b_err_par || b_err_esc || b_err_credit)
                $display("    [b_err_monitor t=%0t] disc=%b par=%b esc=%b credit=%b state=%0d gotfct=%b gotnchar=%b",
                    $time, b_err_disc, b_err_par, b_err_esc, b_err_credit, b_link_state,
                    node_b.u_spw_datalink.w_got_fct, node_b.u_spw_datalink.w_got_nchar);
        end
    end

    initial begin : rawbit_monitor_b
        int cnt_rb;
        cnt_rb = 0;
        forever begin
            @(posedge i_clk);
            if ($time >= 19_200_000 && cnt_rb < 400) begin
                cnt_rb++;
                $display("    [b_rawbit t=%0t] rx_data_bit=%b rx_strobe_bit=%b rx_state=%0d need=%0d cnt=%0d ds_rx_data=%b ds_rx_strobe=%b",
                    $time, node_b.w_rx_data_bit, node_b.w_rx_strobe_bit,
                    node_b.u_spw_enc.r_rx_state, node_b.u_spw_enc.r_rx_need, node_b.u_spw_enc.r_rx_cnt,
                    b_ds_rx_data, b_ds_rx_strobe);
            end
        end
    end

    initial begin : tx_monitor_a
        forever begin
            @(posedge i_clk);
            if (node_a.u_spw_datalink.ow_tx_char_valid)
                $display("    [a_tx t=%0t] tx_char=%b valid=1 enc_ready=%b esc_pending(cur)=%b esc_kind=%b send_esc=%b send_second=%b",
                    $time, node_a.u_spw_datalink.ow_tx_char, node_a.u_spw_datalink.i_enc_ready,
                    node_a.u_spw_datalink.r_esc_pending, node_a.u_spw_datalink.r_esc_kind,
                    node_a.u_spw_datalink.w_send_esc, node_a.u_spw_datalink.w_send_second);
        end
    end

    initial begin : rxchar_monitor_b
        forever begin
            @(posedge i_clk);
            if (node_b.u_spw_datalink.i_rx_char_valid)
                $display("    [b_rxchar t=%0t] rx_char=%b (flag=%b code/data=%b) parity_err=%b rx_pending_esc(before)=%b",
                    $time, node_b.u_spw_datalink.i_rx_char, node_b.u_spw_datalink.i_rx_char[8],
                    node_b.u_spw_datalink.i_rx_char[7:0], node_b.u_spw_datalink.i_parity_err,
                    node_b.u_spw_datalink.r_rx_pending_esc);
        end
    end

    initial begin
        i_rst_n = 0;
        repeat (5) @(posedge i_clk);
        i_rst_n = 1;
        @(posedge i_clk);

        // ── DECISION-14: 비대칭 콜드부트 — A가 link_start로 개시, B는 auto_start로 응답 ──
        a_link_en = 1; b_link_en = 1;
        b_auto_start = 1;

        // ErrorReset -> ErrorWait -> Ready 전이를 기다린 다음(§4.3 골든모델과 동일하게
        // Ready 도달 이후에 link_start 를 세워야 한다 — 그 전에 세우면 리셋/타이머
        // 경로 중에 펄스가 소실된다), A에 link_start 펄스를 준다.
        begin : wait_ready_a
            int nr;
            nr = 0;
            while (a_link_state != 3'd2 /*ST_READY*/ && nr < 500_000) begin
                @(posedge i_clk); nr++;
            end
        end
        check("node A reached Ready before link_start", a_link_state == 3'd2);

        a_link_start = 1;
        $display("    [debug] a_link_start asserted @ t=%0t, a_link_state=%0d", $time, a_link_state);
        repeat (3) @(posedge i_clk);
        $display("    [debug] after 3 cycles, a_link_state=%0d", a_link_state);
        a_link_start = 0;
        // 세밀 디버그: A STARTED 진입 후 물리 링크로 Null 이 실제로 왕복하는지 추적
        for (int dbg = 0; dbg < 3000; dbg++) begin
            @(posedge i_clk);
            if (dbg % 100 == 0)
                $display("    [dbg t=%0t] a_state=%0d b_state=%0d a_ds_tx=%b/%b b_ds_tx=%b/%b a_null_seen=%b b_null_seen=%b a_gotnull=%b b_gotnull=%b b_disc=%b b_errpar=%b b_erresc=%b",
                    $time, a_link_state, b_link_state,
                    a_ds_tx_data, a_ds_tx_strobe, b_ds_tx_data, b_ds_tx_strobe,
                    node_a.u_spw_datalink.r_null_seen, node_b.u_spw_datalink.r_null_seen,
                    node_a.u_spw_datalink.w_got_null, node_b.u_spw_datalink.w_got_null,
                    b_disc, b_err_par, b_err_esc);
        end
        $display("    [debug] after debug window, a_link_state=%0d b_link_state=%0d", a_link_state, b_link_state);

        $display("--- Waiting for both nodes to reach RUN (state=%0d) ---", ST_RUN);
        wait_for_run(500_000);

        check("both nodes reached RUN state", (a_link_state == ST_RUN) && (b_link_state == ST_RUN));
        $display("    a_link_state=%0d b_link_state=%0d @ t=%0t", a_link_state, b_link_state, $time);

        if (a_link_state != ST_RUN || b_link_state != ST_RUN) begin
            $display("*** RUN 도달 실패 — 이후 데이터 시나리오 스킵 ***");
        end else begin
            // ── 데이터 패킷: A -> B, DATA(0x5A) + EOP ──
            a_rx_ready = 1; b_rx_ready = 1; // 양쪽 다 상시 pop 허용

            @(negedge i_clk);
            a_tx_data9 = 9'h05A; a_tx_valid = 1;
            @(negedge i_clk);
            a_tx_data9 = 9'h100; // EOP
            @(negedge i_clk);
            a_tx_valid = 0;

            // B의 사용자 RX 핀에 DATA(0x5A) 도착 대기
            fork
                begin : wait_data
                    int n2;
                    n2 = 0;
                    while (!(b_rx_valid && b_rx_data9 == 9'h05A) && n2 < 200_000) begin
                        @(posedge i_clk); n2++;
                    end
                    check("node B received DATA 0x5A from node A", b_rx_valid && b_rx_data9 == 9'h05A);
                end
            join

            @(posedge i_clk); // 소비(pop)되도록 한 클럭 더 진행

            // B의 사용자 RX 핀에 EOP(0x100) 도착 대기
            fork
                begin : wait_eop
                    int n3;
                    n3 = 0;
                    while (!(b_rx_valid && b_rx_data9 == 9'h100) && n3 < 200_000) begin
                        @(posedge i_clk); n3++;
                    end
                    check("node B received EOP 0x100 after DATA", b_rx_valid && b_rx_data9 == 9'h100);
                end
            join

            // ── Timecode: A -> B ──
            @(negedge i_clk);
            a_time_in = 8'b10_010101; // flag=2'b10, counter=6'b010101
            a_tick_in = 1;
            @(negedge i_clk);
            a_tick_in = 0;

            fork
                begin : wait_tc
                    int n4;
                    n4 = 0;
                    while (!b_tick_out && n4 < 200_000) begin
                        @(posedge i_clk); n4++;
                    end
                    check("node B ow_tick_out pulsed after node A tick_in", b_tick_out);
                    if (b_tick_out)
                        check("node B ow_time_out matches node A i_time_in", b_time_out == a_time_in);
                end
            join
        end

        $display("\n=====================================================");
        $display(" spw_top loopback TB summary: %0d checks, %0d FAILED", checks, errors);
        $display("=====================================================");
        if (errors == 0) $display(" *** ALL PASS ***");
        else $display(" *** %0d FAILURES ***", errors);
        $finish;
    end

    initial begin
        #20_000_000; // 20ms 안전 타임아웃
        $display("[TIMEOUT] integration test hung");
        $finish;
    end

endmodule
