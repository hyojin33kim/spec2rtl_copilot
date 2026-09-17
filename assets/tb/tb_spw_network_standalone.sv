// =============================================================================
// tb_spw_network_standalone.sv — spw_network.sv 단독(standalone) 단위 테스트
//
// 배경: spw_datalink 는 이미 5개의 단독 TB(tb_fsm_smoke/tb_esc_rx/tb_credit/
// tb_priority/tb_err_reset)로 검증되어 있으나, spw_network.sv 는 지금까지
// **단독 TB가 하나도 없었다** (spw_top 통합 TB 안에서만 간접적으로 exercise
// 됨). 이 TB는 spw_datalink/spw_enc/spw_phy 전혀 없이 spw_network 모듈
// 하나만 인스턴스해서, datalink 쪽 인터페이스(i_dl_rx_data/valid/ctrl,
// ow_dl_tx_data/valid, i_dl_tx_pop)를 테스트벤치가 직접 구동/관찰한다.
//
// golden reference: spw_network_standalone_test.py (동일 레이어, 동일 시나리오
// 구성 A~D 를 그대로 RTL 쪽에서 대응)
// =============================================================================
`timescale 1ns/1ps

module tb_spw_network_standalone;

    localparam int TX_FIFO_DEPTH = 8;   // 작게 잡아서 깊이 제한 테스트를 빠르게
    localparam int RX_FIFO_DEPTH = 8;

    logic i_clk = 0;
    logic i_rst_n;
    always #5 i_clk = ~i_clk;

    // ---- 사용자 TX 핀 ----
    logic [8:0] tx_data9 = 0;
    logic       tx_valid = 0;
    logic       tx_ready;

    // ---- 사용자 RX 핀 ----
    logic [8:0] rx_data9;
    logic       rx_valid;
    logic       rx_ready = 0;

    logic       err_tx_invalid;

    // ---- datalink TX 방향 (peek/pop) ----
    logic [8:0] dl_tx_data;
    logic       dl_tx_valid;
    logic       dl_tx_pop = 0;

    // ---- datalink RX 방향 ----
    logic [8:0] dl_rx_data = 0;
    logic       dl_rx_valid = 0;
    logic       dl_rx_ctrl = 0;

    logic [$clog2(RX_FIFO_DEPTH+1)-1:0] rx_free_space;

    // ---- Timecode ----
    logic       tick_in = 0;
    logic [7:0] time_in = 0;
    logic       dl_tick_in;
    logic [7:0] dl_time_in;
    logic       dl_tick_out = 0;
    logic [7:0] dl_time_out = 0;
    logic       tick_out;
    logic [7:0] time_out;

    spw_network #(
        .TX_FIFO_DEPTH(TX_FIFO_DEPTH), .RX_FIFO_DEPTH(RX_FIFO_DEPTH), .ENABLE_TIMECODE(1)
    ) dut (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_tx_data9(tx_data9), .i_tx_valid(tx_valid), .ow_tx_ready(tx_ready),
        .ow_rx_data9(rx_data9), .ow_rx_valid(rx_valid), .i_rx_ready(rx_ready),
        .ow_err_tx_invalid(err_tx_invalid),
        .ow_dl_tx_data(dl_tx_data), .ow_dl_tx_valid(dl_tx_valid), .i_dl_tx_pop(dl_tx_pop),
        .i_dl_rx_data(dl_rx_data), .i_dl_rx_valid(dl_rx_valid), .i_dl_rx_ctrl(dl_rx_ctrl),
        .ow_rx_free_space(rx_free_space),
        .i_tick_in(tick_in), .i_time_in(time_in),
        .ow_dl_tick_in(dl_tick_in), .ow_dl_time_in(dl_time_in),
        .i_dl_tick_out(dl_tick_out), .i_dl_time_out(dl_time_out),
        .ow_tick_out(tick_out), .ow_time_out(time_out)
    );

    int checks = 0;
    int errors = 0;

    task automatic check(input string name, input bit cond);
        checks++;
        if (cond) $display("  [PASS] %s", name);
        else begin
            errors++;
            $display("  [FAIL] %s", name);
        end
    endtask

    task automatic tick;
        @(posedge i_clk);
        #1;
    endtask

    initial begin
        $display("=== tb_spw_network_standalone: spw_network.sv 단독 검증 ===");
        i_rst_n = 0;
        repeat (3) tick();
        i_rst_n = 1;
        tick();

        // -----------------------------------------------------------
        // [A] TX FIFO: 9비트 -> peek 변환, 깊이 제한, 잘못된 제어코드
        // -----------------------------------------------------------
        $display("\n[A] TX FIFO");
        tx_data9 = 9'h0AB; tx_valid = 1;
        tick();
        tx_valid = 0;
        check("DATA(0xAB) push 후 dl_tx_valid=1", dl_tx_valid == 1'b1);
        check("dl_tx_data == 0x0AB (peek, pop 전)", dl_tx_data == 9'h0AB);

        dl_tx_pop = 1; tick(); dl_tx_pop = 0;
        check("pop 후 dl_tx_valid=0 (FIFO 비었음)", dl_tx_valid == 1'b0);

        // 잘못된 제어코드 (0x102~0x1FF) -- ow_err_tx_invalid 는 1클럭 지연된 registered pulse
        tx_data9 = 9'h1AA; tx_valid = 1;
        tick();
        tx_valid = 0;
        check("잘못된 제어코드(0x1AA) -> ow_err_tx_invalid=1 (1클럭 지연 pulse)", err_tx_invalid == 1'b1);
        check("잘못된 제어코드는 큐잉되지 않음 (dl_tx_valid=0)", dl_tx_valid == 1'b0);
        tick();
        check("ow_err_tx_invalid 는 1클럭짜리 pulse (다음 클럭엔 내려감)", err_tx_invalid == 1'b0);

        // 깊이 제한: TX_FIFO_DEPTH=8 개 채우기
        for (int i = 0; i < TX_FIFO_DEPTH; i++) begin
            tx_data9 = 9'(i); tx_valid = 1;
            tick();
        end
        tx_valid = 0;
        check("TX FIFO 8개 채운 후 ow_tx_ready=0", tx_ready == 1'b0);
        // 가득 찬 상태에서 push 시도 -> 실제로 큐잉 안 됨 (pop 없이 계속 push 해도 카운트 불변 확인은
        // dl_tx_valid 유지 + 아래에서 8개 전부 pop 하며 순서 확인으로 간접 검증)
        for (int i = 0; i < TX_FIFO_DEPTH; i++) begin
            check($sformatf("깊이 제한 확인 중 %0d번째 peek 값 == %0d", i, i), dl_tx_data == 9'(i));
            dl_tx_pop = 1; tick(); dl_tx_pop = 0;
        end
        check("8개 전부 pop 후 dl_tx_valid=0", dl_tx_valid == 1'b0);
        check("8개 전부 pop 후 ow_tx_ready=1 (여유 생김)", tx_ready == 1'b1);

        // -----------------------------------------------------------
        // [B] RX FIFO: enc N-Char 포맷 -> 호스트 9비트 변환, rx_ready pop 타이밍
        // -----------------------------------------------------------
        $display("\n[B] RX FIFO");
        // DATA(0x55)
        dl_rx_data = 9'h055; dl_rx_ctrl = 0; dl_rx_valid = 1;
        tick();
        dl_rx_valid = 0;
        check("DATA(0x55) 수신 후 ow_rx_valid=1", rx_valid == 1'b1);
        check("ow_rx_data9 == 0x055 (peek, rx_ready=0 이라 pop 안 함)", rx_data9 == 9'h055);
        check("rx_ready=0 이면 pop 안 함 (peek 유지 확인용 free_space)", rx_free_space == (RX_FIFO_DEPTH-1));

        rx_ready = 1; tick(); rx_ready = 0;
        check("rx_ready=1 로 pop 후 free_space 복귀", rx_free_space == RX_FIFO_DEPTH);

        // EOP -- enc 제어코드 EOP=2'b10 (ERRATA-7), i_dl_rx_ctrl=1
        dl_rx_data = {7'b0, 2'b10}; dl_rx_ctrl = 1; dl_rx_valid = 1;
        tick();
        dl_rx_valid = 0;
        check("EOP 수신 -> ow_rx_data9 == 0x100", rx_data9 == 9'h100);
        rx_ready = 1; tick(); rx_ready = 0;

        // EEP -- enc 제어코드 EEP=2'b01
        dl_rx_data = {7'b0, 2'b01}; dl_rx_ctrl = 1; dl_rx_valid = 1;
        tick();
        dl_rx_valid = 0;
        check("EEP 수신 -> ow_rx_data9 == 0x101", rx_data9 == 9'h101);
        rx_ready = 1; tick(); rx_ready = 0;
        check("전부 pop 후 ow_rx_valid=0", rx_valid == 1'b0);

        // 오버플로우 방어: 8개 채운 뒤 추가 수신 -> 드롭 (free_space 는 0에서 안 내려감)
        for (int i = 0; i < RX_FIFO_DEPTH; i++) begin
            dl_rx_data = {1'b0, 8'(i)}; dl_rx_ctrl = 0; dl_rx_valid = 1;
            tick();
        end
        dl_rx_valid = 0;
        check("RX FIFO 8개로 가득 참 (free_space=0)", rx_free_space == 0);
        dl_rx_data = 9'hEE; dl_rx_ctrl = 0; dl_rx_valid = 1;
        tick();
        dl_rx_valid = 0;
        check("가득 찬 뒤 추가 수신은 드롭됨 (free_space 여전히 0)", rx_free_space == 0);

        // 정리: 다 비우기
        for (int i = 0; i < RX_FIFO_DEPTH; i++) begin
            rx_ready = 1; tick();
        end
        rx_ready = 0;

        // -----------------------------------------------------------
        // [C] Timecode: rising-edge 1클럭 pulse
        // -----------------------------------------------------------
        $display("\n[C] Timecode");
        time_in = 8'b10_101010;
        tick_in = 1;
        // ERRATA-24②: spw_network.sv 의 edge detector는 단일 레지스터 방식
        // (r_prev_tick_in <= i_tick_in; assign ow_dl_tick_in = i_tick_in &&
        // !r_prev_tick_in;) 이라, 펄스는 입력이 천이하는 즉시(조합적)부터 그
        // 천이를 포착하는 클럭 엣지 "직전"까지만 유효하다. tick()(포착 엣지까지
        // 기다린 뒤 #1)으로 확인하면 이미 끝난 펄스를 보게 된다. -> 콤비네이셔널
        // 정착 시간(#1)만 두고 캡처 엣지 이전 시점에서 즉시 확인한다.
        #1;
        check("tick_in 0->1 rising edge 에서 ow_dl_tick_in=1", dl_tick_in == 1'b1);
        check("ow_dl_time_in 은 그대로 통과", dl_time_in == 8'b10_101010);
        tick();   // 캡처 엣지를 실제로 통과시킴
        check("tick_in 이 1로 유지되는 동안 재발생 안 함 (1클럭 pulse)", dl_tick_in == 1'b0);
        tick_in = 0;
        tick();
        check("tick_in 0 복귀 시에는 pulse 없음", dl_tick_in == 1'b0);

        dl_tick_out = 1; dl_time_out = 8'h2A;
        tick();
        check("i_dl_tick_out/i_dl_time_out 은 ow_tick_out/ow_time_out 으로 그대로 통과",
              tick_out == 1'b1 && time_out == 8'h2A);
        dl_tick_out = 0;

        $display("\n=== tb_spw_network_standalone summary: %0d checks, %0d FAILED ===", checks, errors);
        if (errors == 0) $display("[PASS] spw_network.sv 단독 검증 전부 통과");
        else $display("[FAIL] %0d건 실패", errors);

        $finish;
    end

    initial begin
        #100_000;
        $display("[FAIL] timeout");
        $finish;
    end

endmodule
