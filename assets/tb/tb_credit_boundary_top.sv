// =============================================================================
// tb_credit_boundary_top.sv — 2026-09-01 신규: ERRATA-23(안) RTL 확인용
//
// 목적: golden model(spw_ref_model.py) 시나리오 8에서 발견된 "56바이트(=MAX_CREDIT)
// 이상 패킷에서 EOP가 영구 credit 기아 상태에 빠지는" 데드락이 실제 RTL
// (spw_top.sv 2노드 루프백)에서도 재현되는지 확인한다.
//
// tb_spw_top_loopback.sv 를 기반으로, 데이터 페이로드만 1바이트(DATA 0x5A)에서
// 56바이트로 바꾼 축소판이다. EOP 도착 대기에 넉넉한 타임아웃(200,000클럭)을
// 주어, "느리게라도 도착하는지" vs "영구 데드락인지"를 구분한다.
// =============================================================================
`timescale 1ns/1ps

module tb_credit_boundary_top;

    localparam int CLK_FREQ_HZ = 100_000_000;
    localparam int RX_FIFO_DEPTH = 128;
    localparam int TX_FIFO_DEPTH = 128;
    localparam int N_BYTES = 56; // MAX_CREDIT 경계

    logic i_clk = 0;
    logic i_rst_n;
    always #5 i_clk = ~i_clk;

    logic       a_link_en=0, a_link_start=0, a_auto_start=0, a_port_reset=0;
    logic [8:0] a_tx_data9=0; logic a_tx_valid=0; logic a_tx_ready;
    logic [8:0] a_rx_data9;   logic a_rx_valid;   logic a_rx_ready=0;
    logic       a_tick_in=0; logic [7:0] a_time_in=0;
    logic       a_tick_out;  logic [7:0] a_time_out;
    logic [2:0] a_link_state;
    logic       a_err_disc, a_err_par, a_err_esc, a_err_credit, a_err_txinv, a_disc;
    logic       a_ds_tx_data, a_ds_tx_strobe;
    logic       a_ds_rx_data, a_ds_rx_strobe;

    logic       b_link_en=0, b_link_start=0, b_auto_start=0, b_port_reset=0;
    logic [8:0] b_tx_data9=0; logic b_tx_valid=0; logic b_tx_ready;
    logic [8:0] b_rx_data9;   logic b_rx_valid;   logic b_rx_ready=0;
    logic       b_tick_in=0; logic [7:0] b_time_in=0;
    logic       b_tick_out;  logic [7:0] b_time_out;
    logic [2:0] b_link_state;
    logic       b_err_disc, b_err_par, b_err_esc, b_err_credit, b_err_txinv, b_disc;
    logic       b_ds_tx_data, b_ds_tx_strobe;
    logic       b_ds_rx_data, b_ds_rx_strobe;

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

    localparam logic [2:0] ST_RUN = 3'd5;
    task automatic wait_for_run(int max_cycles);
        int n;
        n = 0;
        while ((a_link_state != ST_RUN || b_link_state != ST_RUN) && n < max_cycles) begin
            @(posedge i_clk);
            n++;
        end
    endtask

    int rx_count;
    logic [7:0] rx_bytes [0:N_BYTES-1];
    logic eop_seen;

    initial begin
        i_rst_n = 0;
        repeat (5) @(posedge i_clk);
        i_rst_n = 1;
        @(posedge i_clk);

        a_link_en = 1; b_link_en = 1;
        b_auto_start = 1;

        begin : wait_ready_a
            int nr; nr = 0;
            while (a_link_state != 3'd2 && nr < 500_000) begin @(posedge i_clk); nr++; end
        end
        a_link_start = 1;
        repeat (3) @(posedge i_clk);
        a_link_start = 0;

        wait_for_run(500_000);
        check("both nodes reached RUN", (a_link_state == ST_RUN) && (b_link_state == ST_RUN));

        if (a_link_state == ST_RUN && b_link_state == ST_RUN) begin
            a_rx_ready = 1; b_rx_ready = 1;
            rx_count = 0;
            eop_seen = 0;

            // 수신 캡처 (병렬)
            fork
                begin : capture_rx
                    while (!eop_seen) begin
                        @(posedge i_clk);
                        if (b_rx_valid) begin
                            if (b_rx_data9 == 9'h100) begin
                                eop_seen = 1;
                                $display("[info] EOP received after %0d data bytes @ t=%0t", rx_count, $time);
                            end else begin
                                if (rx_count < N_BYTES) rx_bytes[rx_count] = b_rx_data9[7:0];
                                rx_count++;
                            end
                        end
                    end
                end
            join_none

            // 송신: DATA 0..N_BYTES-1 다음 EOP
            for (int i = 0; i < N_BYTES; i++) begin
                @(negedge i_clk);
                a_tx_data9 = i[7:0];
                a_tx_valid = 1;
                @(posedge i_clk);
                while (!a_tx_ready) @(posedge i_clk);
            end
            @(negedge i_clk);
            a_tx_data9 = 9'h100; // EOP
            @(posedge i_clk);
            while (!a_tx_ready) @(posedge i_clk);
            @(negedge i_clk);
            a_tx_valid = 0;

            // EOP 도착 대기 (넉넉한 타임아웃 -- 데드락이면 여기서 만료됨)
            begin : wait_eop
                int n; n = 0;
                while (!eop_seen && n < 200_000) begin @(posedge i_clk); n++; end
                check($sformatf("%0d바이트 DATA + EOP 전부 수신 (rx_count=%0d)", N_BYTES, rx_count),
                      eop_seen && (rx_count == N_BYTES));
                if (!eop_seen)
                    $display("*** DEADLOCK 재현: EOP 200,000클럭 내 미도착. a_err_credit=%b b_err_credit=%b a_disc=%b b_disc=%b",
                             a_err_credit, b_err_credit, a_disc, b_disc);
            end
        end

        $display("\n===== tb_credit_boundary_top: %0d checks, %0d FAILED =====", checks, errors);
        if (errors == 0) $display("*** ALL PASS ***");
        else $display("*** %0d FAILURES ***", errors);
        $finish;
    end

    initial begin
        #50_000_000; // 안전판 타임아웃 (5ms sim time)
        $display("[FAIL] global timeout");
        $finish;
    end

endmodule
