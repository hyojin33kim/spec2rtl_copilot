// =============================================================================
// tb_decision17_tc_starvation.sv — DECISION-17 Option B 워스트케이스 RTL 검증
//
// 목적: golden model scenario_24(spw_ref_model_test_v5.py)가 실측한 문제를
// RTL(spw_top.sv 2노드 루프백)에서도 동일하게 재현/해결 확인한다 -- 노드 A가
// i_tick_in을 물리적으로 가능한 최대 속도(매 클럭 0/1 반전)로 계속 재무장하는
// 동안, 노드 B가 대용량 N-Char 패킷을 A로 송신. Option B(TC_STARVE_THRESHOLD
// throttle, spw_datalink_v2.sv) 적용 전에는 credit 고갈 후 완전 정체가
// 재현됐고(수동 확인, 아래 이력 참조), 적용 후에는 유한 시간 내 완주해야 한다.
//
// tb_credit_boundary_top.sv를 기반으로, 데이터 방향(A/B 역할)과 tick_in 스트레스
// 부분만 추가했다.
// =============================================================================
`timescale 1ns/1ps

module tb_decision17_tc_starvation;

    localparam int CLK_FREQ_HZ = 100_000_000;
    localparam int RX_FIFO_DEPTH = 128;
    localparam int TX_FIFO_DEPTH = 128;
    localparam int N_BYTES = 300;

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
    int tick_out_count;
    logic eop_seen;
    time run_reached_at;
    time eop_at;

    // ── A: 물리적으로 가능한 최대 속도 tick_in 재무장 (매 클럭 0/1 반전) ──
    // golden model scenario_24의 `a.i.tick_in = 1 if (cyc % 2 == 0) else 0`
    // 와 동일한 패턴. RUN 이전에도 그냥 돌지만 r_tc_pending은 RUN에서만
    // 래치되므로(ERRATA-19) 해가 되지 않는다 -- 별도 start 트리거 불필요.
    initial begin : tc_stress
        a_tick_in = 0;
        forever begin
            @(negedge i_clk);
            a_tick_in = ~a_tick_in;
            if (a_tick_in) a_time_in = a_time_in + 8'd1;
        end
    end

    initial begin : tick_out_monitor
        tick_out_count = 0;
        forever begin
            @(posedge i_clk);
            if (b_tick_out) tick_out_count++;
        end
    end

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
        check("both nodes reached RUN (tick_in stress already running on A)",
              (a_link_state == ST_RUN) && (b_link_state == ST_RUN));
        run_reached_at = $time;

        if (a_link_state == ST_RUN && b_link_state == ST_RUN) begin
            a_rx_ready = 1; b_rx_ready = 1;
            rx_count = 0;
            eop_seen = 0;

            // B -> A 로 N_BYTES 송신, A가 수신 (golden model과 동일한 방향)
            fork
                begin : capture_rx
                    while (!eop_seen) begin
                        @(posedge i_clk);
                        if (a_rx_valid) begin
                            if (a_rx_data9 == 9'h100) begin
                                eop_seen = 1;
                                eop_at = $time;
                                $display("[info] EOP received after %0d data bytes @ t=%0t (elapsed=%0t since RUN)",
                                         rx_count, $time, $time - run_reached_at);
                            end else begin
                                rx_count++;
                            end
                        end
                    end
                end
            join_none

            // baseline(다른 RTL TB들의 정상 100클럭/byte 실측)의 4배 이내를
            // "유한 상한이 걸린다"는 기준으로 삼는다 -- golden model scenario_24와
            // 동일한 기준(1.44배 실측, 4배는 여유치). N_BYTES*100은 baseline
            // 근사, +20000은 RUN 도달 및 배선 지연 여유.
            begin : push_and_wait
                int bound;
                int push_idx;
                int push_n;
                logic push_stalled;
                bound = N_BYTES * 100 * 4 + 20_000;

                // [중요] b_tx_ready를 무제한 `while`로 기다리면, RTL이 실제로
                // 완전 정체에 빠졌을 때(회귀 발생 시) 이 루프가 영원히 안 끝나
                // 아래 200ms 글로벌 안전판(20,000,000클럭)까지 그대로 흘러가
                // 실패를 관측하는 데만 수 분이 걸린다(실측: throttle을 일부러
                // 끈 상태로 재현 시도했을 때 90초 타임아웃으로도 도달 못 함).
                // bound 로 상한을 걸어 "얼마나 못 갔는지" 즉시 진단한다.
                push_idx = 0;
                push_n = 0;
                push_stalled = 0;
                while (push_idx <= N_BYTES && push_n < bound) begin
                    @(negedge i_clk);
                    b_tx_data9 = (push_idx < N_BYTES) ? push_idx[7:0] : 9'h100; // 마지막은 EOP
                    b_tx_valid = 1;
                    @(posedge i_clk);
                    if (b_tx_ready) push_idx++;
                    push_n++;
                end
                b_tx_valid = 0;
                if (push_idx <= N_BYTES) begin
                    push_stalled = 1;
                    $display("*** STALL during TX push: %0d cycles 내에 %0d/%0d 문자(EOP 포함)만 accept됨",
                             bound, push_idx, N_BYTES + 1);
                end

                // push가 다 끝났어도 wire 전송이 아직 안 끝났을 수 있으니, EOP
                // 도착까지 남은 예산으로 마저 대기 (push_n 만큼 이미 소모됨).
                if (!push_stalled) begin
                    while (!eop_seen && push_n < bound) begin @(posedge i_clk); push_n++; end
                end

                check($sformatf("[DECISION-17 Option B] tick_in 물리적 최대 재무장 중에도 %0d바이트 DATA+EOP 전량 도착 (완전 정체 없음)",
                                 N_BYTES),
                      !push_stalled && eop_seen && (rx_count == N_BYTES));
                if (push_stalled || !eop_seen)
                    $display("*** STALL: EOP %0d클럭 예산 내 미도착 (완전 정체 재발 의심). a_err_credit=%b b_err_credit=%b a_disc=%b b_disc=%b rx_count=%0d",
                             bound, a_err_credit, b_err_credit, a_disc, b_disc, rx_count);
                else
                    check($sformatf("[DECISION-17 Option B] 지연이 유한하게 상한 걸림 (bound=%0d클럭 이내, 실측=%0t)",
                                     bound, (eop_at - run_reached_at) / 10),
                          1'b1); // 도달 자체가 이미 위 while 조건(push_n<bound)으로 검증됨 -- 실측값 기록용
            end

            check("[DECISION-17 Option B] credit_error 없음 (양쪽)", !a_err_credit && !b_err_credit);
            check("[DECISION-17 Option B] esc_error 없음 (양쪽)", !a_err_esc && !b_err_esc);
            check($sformatf("[DECISION-17 Option B] Timecode 자체는 여전히 다수 정상 전달됨 (tick_out_count=%0d)",
                            tick_out_count),
                  tick_out_count > 50);
        end

        $display("\n===== tb_decision17_tc_starvation: %0d checks, %0d FAILED =====", checks, errors);
        if (errors == 0) $display("*** ALL PASS ***");
        else $display("*** %0d FAILURES ***", errors);
        $finish;
    end

    initial begin
        #200_000_000; // 안전판 타임아웃 (20ms sim time)
        $display("[FAIL] global timeout");
        $finish;
    end

endmodule
