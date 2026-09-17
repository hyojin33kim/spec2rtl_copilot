// =============================================================================
// tb_credit_boundary_multipacket.sv — 2026-09-01 신규: ERRATA-23 누적형 RTL 확인
//
// golden model scenario_12(4패킷 x 40바이트, 각 패킷은 MAX_CREDIT(56) 미만)에서
// 패킷 2부터 credit 이 누적 고갈되어 영구 데드락에 빠지는 것이 발견됐다
// (단일 큰 패킷이 아니라 "여러 개의 작은 패킷 연속 전송"만으로도 재현).
// 이 TB는 동일 패턴(4패킷 x 40바이트)을 실제 RTL(spw_top 2노드 루프백)에
// 흘려 RTL도 같은 누적 데드락을 겪는지 확인한다.
// =============================================================================
`timescale 1ns/1ps

module tb_credit_boundary_multipacket;

    localparam int CLK_FREQ_HZ = 100_000_000;
    localparam int RX_FIFO_DEPTH = 128;
    localparam int TX_FIFO_DEPTH = 128;
    localparam int N_PACKETS = 4;
    localparam int BYTES_PER_PACKET = 40;

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

    spw_top #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .TX_FIFO_DEPTH(TX_FIFO_DEPTH), .RX_FIFO_DEPTH(RX_FIFO_DEPTH)) node_a (
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

    spw_top #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .TX_FIFO_DEPTH(TX_FIFO_DEPTH), .RX_FIFO_DEPTH(RX_FIFO_DEPTH)) node_b (
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
        int n; n = 0;
        while ((a_link_state != ST_RUN || b_link_state != ST_RUN) && n < max_cycles) begin
            @(posedge i_clk); n++;
        end
    endtask

    int rx_count;
    logic eop_seen;
    logic capture_active;

    always @(posedge i_clk) begin
        if (capture_active && b_rx_valid) begin
            if (b_rx_data9 == 9'h100) eop_seen <= 1;
            else rx_count <= rx_count + 1;
        end
    end

    task automatic send_one_packet(int pkt_no);
        rx_count = 0;
        eop_seen = 0;
        capture_active = 1;

        for (int i = 0; i < BYTES_PER_PACKET; i++) begin
            @(negedge i_clk);
            a_tx_data9 = ((pkt_no * 37 + i) & 8'hFF);
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

        begin : wait_eop
            int n; n = 0;
            while (!eop_seen && n < 200_000) begin @(posedge i_clk); n++; end
            check($sformatf("패킷 %0d/%0d (%0dB) 정상 완료 (rx_count=%0d)",
                             pkt_no+1, N_PACKETS, BYTES_PER_PACKET, rx_count),
                  eop_seen && (rx_count == BYTES_PER_PACKET));
            if (!eop_seen)
                $display("*** DEADLOCK: 패킷 %0d 에서 EOP 미도착. a_err_credit=%b b_err_credit=%b",
                         pkt_no+1, a_err_credit, b_err_credit);
        end
        capture_active = 0;
    endtask

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
            for (int p = 0; p < N_PACKETS; p++) begin
                send_one_packet(p);
            end
        end

        $display("\n===== tb_credit_boundary_multipacket: %0d checks, %0d FAILED =====", checks, errors);
        if (errors == 0) $display("*** ALL PASS ***");
        else $display("*** %0d FAILURES ***", errors);
        $finish;
    end

    initial begin
        #80_000_000;
        $display("[FAIL] global timeout");
        $finish;
    end

endmodule
