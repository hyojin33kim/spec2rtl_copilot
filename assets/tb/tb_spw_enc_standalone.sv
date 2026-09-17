// =============================================================================
// tb_spw_enc_standalone.sv — spw_enc.sv 단독(standalone) 단위 테스트
//
// spw_datalink 없이 spw_enc 모듈 하나만 인스턴스한다. i_tx_char/i_tx_char_valid
// /ow_tx_char_ready 문자 인터페이스를 테스트벤치가 직접 구동하고, encoder 의
// TX D/S 라인을 자기 자신의 RX 입력에 되먹임(self-loopback)해서 ow_rx_char/
// ow_rx_char_valid/ow_parity_err 로 그대로 복원해 관찰한다.
//
// golden reference: spw_encoder_standalone_test.py (동일 시나리오 A~F 를
// 그대로 RTL 쪽에서 대응시킨 것 -- 그 스크립트가 SpWEncoder/SpWDecoder 를
// SpWLink 없이 직접 검증했던 것과 완전히 같은 레이어)
//
// 이전에 만든 tb_esc_enc_handshake.sv 와의 차이: 그건 spw_datalink+spw_enc
// 를 "같이" 물려서 §8.3 handshake 버그를 재현하는 TB였고, 이건 spw_enc
// "하나만" 떼어내서 인코딩/디코딩 자체(비트 조립, parity, LSB-first, 프레이밍
// 복구)가 정확한지만 본다 -- 더 아래 레이어(Layer 0/1 경계) 검증이다.
// =============================================================================
`timescale 1ns/1ps

module tb_spw_enc_standalone;

    // ── 파형 덤프 (wave 보기용) ───────────────────────────────────
    initial begin
        $dumpfile("tb_spw_enc_standalone.vcd");
        $dumpvars(0, tb_spw_enc_standalone);
    end

    localparam int CLK_FREQ_HZ  = 100_000_000;  // 10ns period
    localparam int TX_RATE_MBPS = 10;           // BIT_PERIOD_CYCLES = 10 (기본값)
    localparam int BIT_PERIOD_CYCLES = CLK_FREQ_HZ / (TX_RATE_MBPS * 1_000_000);

    localparam logic [1:0] CODE_FCT = 2'b00;
    localparam logic [1:0] CODE_EEP = 2'b01;
    localparam logic [1:0] CODE_EOP = 2'b10;
    localparam logic [1:0] CODE_ESC = 2'b11;

    logic i_clk = 0;
    logic i_rst_n;
    always #5 i_clk = ~i_clk;

    logic       enc_reset = 0;
    logic [8:0] tx_char = 0;
    logic       tx_char_valid = 0;
    logic       tx_char_ready;

    logic [8:0] rx_char;
    logic       rx_char_valid;
    logic       parity_err;

    logic w_ds_data, w_ds_strobe;

    // ── 내부 전용(관찰용) 신호: 복원된 클럭/데이터 ─────────────────
    // DS(Data-Strobe) 인코딩은 D 와 S 중 반드시 하나는 매 비트마다 토글
    // 되도록 설계되어 있으므로, D XOR S 를 취하면 "매 비트 경계마다 정확히
    // 한 번씩 토글되는" 순수한 복원 클럭(recovered clock)이 나온다
    // (spw_enc.sv 194~197행 w_rx_changed 판정과 동일한 원리).
    // self-loopback 구성이라 TX 라인(w_ds_data/w_ds_strobe)이 곧 RX 라인
    // (i_rx_data_bit/i_rx_strobe_bit)과 같으므로 이 두 신호만으로 충분하다.
    logic w_recovered_clk;
    assign w_recovered_clk = w_ds_data ^ w_ds_strobe;

    // "복원된 데이터" -- D 라인 자체가 이미 비트 경계마다만 값이 바뀌고
    // 그 사이엔 값을 유지하므로(자기클럭 방식 특성상), w_ds_data 를 그대로
    // 별칭(alias)만 붙여서 파형에서 신호명을 명확히 구분되게 만든다.
    logic w_recovered_data;
    assign w_recovered_data = w_ds_data;

    spw_enc #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .TX_RATE_MBPS(TX_RATE_MBPS)
    ) dut (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_enc_reset(enc_reset),
        .i_tx_char(tx_char), .i_tx_char_valid(tx_char_valid), .ow_tx_char_ready(tx_char_ready),
        .ow_rx_char(rx_char), .ow_rx_char_valid(rx_char_valid), .ow_parity_err(parity_err),
        .ow_tx_data_bit(w_ds_data), .ow_tx_strobe_bit(w_ds_strobe),
        .i_rx_data_bit(w_ds_data), .i_rx_strobe_bit(w_ds_strobe)    // ★ self-loopback
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

    // ── 문자 하나를 encoder 에 밀어넣기 (ready/valid 핸드셰이크) ──────
    task automatic send_char(input logic [8:0] ch);
        while (!tx_char_ready) @(posedge i_clk);
        tx_char = ch;
        tx_char_valid = 1;
        @(posedge i_clk);
        #1;
        tx_char_valid = 0;
    endtask

    function automatic logic [8:0] ctrl(input logic [1:0] code);
        return {1'b1, 6'b0, code};
    endfunction
    function automatic logic [8:0] data9(input logic [7:0] val);
        return {1'b0, val};
    endfunction

    // ── decoder 출력 수집 (rx_char_valid 매 클럭 감시) ───────────────
    logic [8:0] rx_q      [0:511];
    bit         rx_perr_q [0:511];
    int         rx_qlen = 0;

    always_ff @(posedge i_clk) begin
        if (rx_char_valid) begin
            rx_q[rx_qlen]      <= rx_char;
            rx_perr_q[rx_qlen] <= parity_err;
            rx_qlen            <= rx_qlen + 1;
        end
    end

    task automatic wait_for_n_chars(input int n, input int max_cycles);
        int c;
        c = 0;
        while (rx_qlen < n && c < max_cycles) begin
            @(posedge i_clk);
            c++;
        end
    endtask

    initial begin
        $display("=== tb_spw_enc_standalone: spw_enc.sv 단독 검증 (self-loopback) ===");
        i_rst_n = 0;
        repeat (3) @(posedge i_clk);
        i_rst_n = 1;
        @(posedge i_clk);

        // -----------------------------------------------------------
        // [A] 단독 제어문자 (FCT/EOP/EEP) 왕복
        // -----------------------------------------------------------
        $display("\n[A] 단독 제어문자 왕복");
        rx_qlen = 0;
        send_char(ctrl(CODE_FCT));
        wait_for_n_chars(1, 200);
        check("FCT 단독 왕복: code 일치", rx_qlen == 1 && rx_q[0][1:0] == CODE_FCT && rx_q[0][8]);
        check("FCT 단독 왕복: parity 무오류", !rx_perr_q[0]);

        rx_qlen = 0;
        send_char(ctrl(CODE_EOP));
        wait_for_n_chars(1, 200);
        check("EOP 단독 왕복: code 일치, parity 무오류", rx_qlen == 1 && rx_q[0][1:0] == CODE_EOP && !rx_perr_q[0]);

        rx_qlen = 0;
        send_char(ctrl(CODE_EEP));
        wait_for_n_chars(1, 200);
        check("EEP 단독 왕복: code 일치, parity 무오류", rx_qlen == 1 && rx_q[0][1:0] == CODE_EEP && !rx_perr_q[0]);

        // -----------------------------------------------------------
        // [B] ESC 원자쌍 (Null: ESC+FCT / TC 페이로드: ESC+DATA) 왕복
        // spw_enc 는 ESC 페어링을 모른다 -- TB 가 그냥 두 문자를 연달아
        // 보내는 것 뿐이다 (원자성 보장은 spw_datalink 의 몫, tb_esc_enc_
        // handshake.sv 에서 별도 검증함).
        // -----------------------------------------------------------
        $display("\n[B] ESC 원자쌍 물리 왕복 (원자성 자체는 datalink 책임, 여기선 비트 정확성만)");
        rx_qlen = 0;
        send_char(ctrl(CODE_ESC));
        send_char(ctrl(CODE_FCT));
        wait_for_n_chars(2, 300);
        check("Null(ESC->FCT) 왕복: 2개 정상 수신", rx_qlen == 2);
        check("Null: 첫 문자 ESC", rx_q[0][8] && rx_q[0][1:0] == CODE_ESC);
        check("Null: 둘째 문자 FCT, parity 무오류", rx_q[1][8] && rx_q[1][1:0] == CODE_FCT && !rx_perr_q[1]);

        rx_qlen = 0;
        send_char(ctrl(CODE_ESC));
        send_char(data9(8'b10_101010));
        wait_for_n_chars(2, 300);
        check("TC페이로드(ESC->DATA) 왕복: 2개 정상 수신, 값 일치",
              rx_qlen == 2 && !rx_q[1][8] && rx_q[1][7:0] == 8'b10_101010 && !rx_perr_q[1]);

        // -----------------------------------------------------------
        // [C] DATA 8비트 전체 스윕 (0x00~0xFF) -- LSB-first 인코딩 정확성
        // -----------------------------------------------------------
        $display("\n[C] DATA 0x00~0xFF 전체 스윕");
        rx_qlen = 0;
        for (int v = 0; v < 256; v++) send_char(data9(8'(v)));
        wait_for_n_chars(256, 256 * 60 + 2000);
        check("DATA 256개 전부 수신됨", rx_qlen == 256);
        begin
            int mismatches;
            mismatches = 0;
            for (int v = 0; v < 256; v++) begin
                if (rx_q[v][8] || rx_q[v][7:0] != 8'(v) || rx_perr_q[v]) mismatches++;
            end
            check($sformatf("DATA 256개 전부 값/parity 일치 (mismatches=%0d)", mismatches), mismatches == 0);
        end

        // -----------------------------------------------------------
        // [D] 혼합 시퀀스 (제어문자 + DATA + ESC쌍, 고정 순서)
        // -----------------------------------------------------------
        $display("\n[D] 혼합 시퀀스 (고정 패턴)");
        rx_qlen = 0;
        send_char(ctrl(CODE_FCT));
        send_char(data9(8'h5A));
        send_char(ctrl(CODE_ESC));
        send_char(ctrl(CODE_FCT));
        send_char(ctrl(CODE_EOP));
        send_char(data9(8'hA5));
        send_char(ctrl(CODE_ESC));
        send_char(data9(8'hC3));
        send_char(ctrl(CODE_EEP));
        wait_for_n_chars(9, 9 * 60 + 2000);
        check("혼합 시퀀스: 9개 전부 수신", rx_qlen == 9);
        check("혼합 시퀀스: 순서/값 전부 일치",
              rx_qlen == 9
              && rx_q[0] == ctrl(CODE_FCT) && !rx_perr_q[0]
              && rx_q[1] == data9(8'h5A)   && !rx_perr_q[1]
              && rx_q[2] == ctrl(CODE_ESC) && !rx_perr_q[2]
              && rx_q[3] == ctrl(CODE_FCT) && !rx_perr_q[3]
              && rx_q[4] == ctrl(CODE_EOP) && !rx_perr_q[4]
              && rx_q[5] == data9(8'hA5)   && !rx_perr_q[5]
              && rx_q[6] == ctrl(CODE_ESC) && !rx_perr_q[6]
              && rx_q[7] == data9(8'hC3)   && !rx_perr_q[7]
              && rx_q[8] == ctrl(CODE_EEP) && !rx_perr_q[8]);

        // -----------------------------------------------------------
        // [E] 전송 중 1비트 반전 주입 -> parity_err 검출 + i_enc_reset 복구
        // -----------------------------------------------------------
        $display("\n[E] 1비트 오류 주입 -> parity_err -> i_enc_reset 복구");
        rx_qlen = 0;
        fork
            send_char(data9(8'hA5));
            begin
                // ERRATA-24①: 주입 시점이 비트 경계(BIT_PERIOD_CYCLES의 배수)와
                // 무관하면(45 mod 10 = 5, 즉 비트 중간) self-clocking 복호 로직이
                // "1비트 값 오류"가 아니라 "경계 밖 스퓨리어스 천이 삽입"으로
                // 해석해 parity_err 가 뜨지 않는다. 또한 force를 1클럭만 유지하면
                // iverilog의 force는 RHS를 실행 시점에 1회만 평가하고 이후 변화를
                // 추종하지 않으므로 값이 곧바로 원래 흐름과 어긋난다.
                // -> 실제 비트 경계(다음 천이)까지 기다렸다가 그 순간 값을 한 번만
                //    캡처하고, D/S 를 함께 반전한 채 정확히 BIT_PERIOD_CYCLES 구간
                //    동안 force 한다. D/S를 같은 구간 동안 함께 반전하면 그 구간
                //    내내 XOR(D,S) 토글 불변식이 유지되어 프레이밍은 깨지지 않고
                //    해당 비트 값만 틀어진다.
                logic cap_d, cap_s;
                @(w_ds_data or w_ds_strobe);
                cap_d = w_ds_data;
                cap_s = w_ds_strobe;
                force dut.i_rx_data_bit   = ~cap_d;
                force dut.i_rx_strobe_bit = ~cap_s;
                repeat (BIT_PERIOD_CYCLES) @(posedge i_clk);
                release dut.i_rx_data_bit;
                release dut.i_rx_strobe_bit;
            end
        join
        wait_for_n_chars(1, 500);
        check("1비트 오류 주입 시 parity_err 발생 (어딘가에서 한 번이라도)",
              rx_qlen >= 1 && rx_perr_q[0]);

        // 실제 시스템에서는 SpWLink 가 parity_error 를 보고 ErrorReset 을
        // 걸고 i_enc_reset 1클럭 pulse 로 encoder/decoder 를 함께 리셋한다.
        // 여기서도 동일하게 흉내내서 복구를 확인한다.
        enc_reset = 1;
        @(posedge i_clk); #1;
        enc_reset = 0;
        rx_qlen = 0;
        send_char(ctrl(CODE_FCT));
        wait_for_n_chars(1, 300);
        check("i_enc_reset 이후 정상 문자(FCT) 복구되어 수신됨",
              rx_qlen == 1 && rx_q[0][1:0] == CODE_FCT && !rx_perr_q[0]);

        $display("\n=== tb_spw_enc_standalone summary: %0d checks, %0d FAILED ===", checks, errors);
        if (errors == 0) $display("[PASS] spw_enc.sv 단독 검증 전부 통과");
        else $display("[FAIL] %0d건 실패", errors);

        $finish;
    end

    initial begin
        #2_000_000;
        $display("[FAIL] timeout");
        $finish;
    end

endmodule
