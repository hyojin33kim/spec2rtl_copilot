`timescale 1ns/1ps

module tb_credit_mvp;
    logic clk = 0;
    logic rst_n = 0;
    logic link_en = 0;
    logic link_start = 0;
    logic enc_ready = 1;
    logic [2:0] link_state;
    logic [8:0] rx_char = 0;
    logic rx_char_valid = 0;
    logic [8:0] nchar_data = 9'h05a;
    logic nchar_valid = 0;
    logic nchar_ready;
    logic [7:0] rx_free_space = 0;
    logic err_credit;

    localparam [1:0] CODE_FCT = 2'b00;
    localparam [1:0] CODE_ESC = 2'b11;

    always #5 clk = ~clk;

    spw_datalink #(
        .RX_FIFO_DEPTH(128),
        .MAX_CREDIT(56),
        .CNT_6US(8),
        .CNT_12US(16)
    ) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_link_en(link_en), .i_link_start(link_start),
        .i_auto_start(1'b0), .i_port_reset(1'b0),
        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char),
        .i_parity_err(1'b0), .i_disconnect(1'b0),
        .ow_tx_char_valid(), .ow_tx_char(), .i_enc_ready(enc_ready),
        .ow_enc_reset(),
        .i_nchar_data(nchar_data), .i_nchar_valid(nchar_valid),
        .ow_nchar_ready(nchar_ready),
        .ow_rx_char_data(), .ow_rx_char_valid(), .ow_rx_char_ctrl(),
        .i_rx_free_space(rx_free_space),
        .i_tick_in(1'b0), .i_time_in(8'b0),
        .ow_tick_out(), .ow_time_out(),
        .ow_link_state(link_state),
        .ow_err_disconnect(), .ow_err_parity(), .ow_err_esc(),
        .ow_err_credit(err_credit), .ow_err_tx_invalid()
    );

    int errors = 0;
    int guard;

    task tick;
        @(posedge clk); #1;
    endtask

    task send_char(input logic [8:0] ch);
        @(negedge clk);
        rx_char = ch;
        rx_char_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rx_char_valid = 1'b0;
        #1;
    endtask

    task set_tx_credit(input logic [5:0] value);
        @(negedge clk);
        force dut.r_tx_credit = value;
        @(posedge clk); #1;
        release dut.r_tx_credit;
        #1;
    endtask

    task report_check(input string id, input bit passed, input string detail);
        if (passed) begin
            $display("MVP_RESULT|%s|PASS|%s", id, detail);
        end else begin
            errors++;
            $display("MVP_RESULT|%s|FAIL|%s", id, detail);
        end
    endtask

    initial begin
        $dumpfile("waveform.vcd");
        $dumpvars(0, tb_credit_mvp);

        if ($test$plusargs("MVP_FORCE_FAIL")) begin
            $display("MVP_RESULT|REQ-FC-E1|FAIL|acceptance simulation fault injected");
            $display("MVP_SUMMARY|FAIL|0|1");
            #1;
            $finish_and_return(1);
        end

        repeat (3) tick();
        rst_n = 1'b1;
        link_en = 1'b1;
        repeat (10) tick();
        repeat (20) tick();
        if (link_state !== 3'd2) begin
            $display("MVP_RESULT|SETUP|FAIL|Ready state not reached");
            $finish_and_return(2);
        end

        link_start = 1'b1;
        tick();
        link_start = 1'b0;
        send_char({1'b1, 6'b0, CODE_ESC});
        send_char({1'b1, 6'b0, CODE_FCT});

        if (link_state !== 3'd4) begin
            $display("MVP_RESULT|SETUP|FAIL|Connecting state not reached");
            $finish_and_return(2);
        end
        // Connecting needs one independent received FCT as well as one sent FCT.
        send_char({1'b1, 6'b0, CODE_FCT});

        guard = 0;
        while (link_state != 3'd5 && guard < 12) begin
            tick();
            guard++;
        end
        if (link_state !== 3'd5) begin
            $display("MVP_RESULT|SETUP|FAIL|Run state not reached");
            $finish_and_return(2);
        end

        // REQ-FC-E1: independent FCT increments transmit credit by eight.
        set_tx_credit(6'd8);
        send_char({1'b1, 6'b0, CODE_FCT});
        report_check("REQ-FC-E1", dut.r_tx_credit === 6'd16,
                     $sformatf("tx_credit=%0d expected=16", dut.r_tx_credit));

        // REQ-FC-E2: an accepted N-Char consumes one transmit credit.
        set_tx_credit(6'd5);
        @(negedge clk);
        nchar_valid = 1'b1;
        @(posedge clk); #1;
        report_check("REQ-FC-E2",
                     dut.w_send_nchar === 1'b1 && dut.r_tx_credit === 6'd4,
                     $sformatf("send=%0b tx_credit=%0d expected=4",
                               dut.w_send_nchar, dut.r_tx_credit));
        @(negedge clk); nchar_valid = 1'b0;

        // REQ-FC-F: zero credit blocks the pending N-Char.
        set_tx_credit(6'd0);
        @(negedge clk);
        nchar_valid = 1'b1;
        @(posedge clk); #1;
        report_check("REQ-FC-F",
                     dut.w_send_nchar === 1'b0 && nchar_ready === 1'b0
                         && dut.r_tx_credit === 6'd0,
                     $sformatf("send=%0b ready=%0b tx_credit=%0d",
                               dut.w_send_nchar, nchar_ready, dut.r_tx_credit));
        @(negedge clk); nchar_valid = 1'b0;

        // Approved cross-event contract: +8 and -1 apply together (net +7).
        set_tx_credit(6'd10);
        // Align to a slot where an idle Null's second character is not pending;
        // an in-flight ESC pair has higher priority than both FCT and N-Char.
        while (dut.r_esc_pending) tick();
        @(negedge clk);
        nchar_valid = 1'b1;
        rx_char = {1'b1, 6'b0, CODE_FCT};
        rx_char_valid = 1'b1;
        @(posedge clk); #1;
        report_check("DEC-FC-SIMULTANEOUS-001",
                     dut.w_got_fct === 1'b1 && dut.w_send_nchar === 1'b1
                         && dut.r_tx_credit === 6'd17,
                     $sformatf("got_fct=%0b send=%0b tx_credit=%0d expected=17",
                               dut.w_got_fct, dut.w_send_nchar, dut.r_tx_credit));
        @(negedge clk);
        nchar_valid = 1'b0;
        rx_char_valid = 1'b0;

        // REQ-FC-HJ: an FCT beyond 56 raises credit_error without increment.
        force dut.r_state = 3'd4;
        set_tx_credit(6'd56);
        @(negedge clk);
        rx_char = {1'b1, 6'b0, CODE_FCT};
        rx_char_valid = 1'b1;
        #1;
        report_check("REQ-FC-HJ-COMB",
                     err_credit === 1'b1 && dut.w_tx_credit_err === 1'b1,
                     $sformatf("credit_error=%0b overflow=%0b",
                               err_credit, dut.w_tx_credit_err));
        @(posedge clk); #1;
        report_check("REQ-FC-HJ-STATE",
                     dut.r_tx_credit === 6'd56,
                     $sformatf("tx_credit=%0d expected=56", dut.r_tx_credit));
        @(negedge clk);
        rx_char_valid = 1'b0;
        release dut.r_state;

        if (errors == 0) begin
            $display("MVP_SUMMARY|PASS|6|0");
            $finish_and_return(0);
        end else begin
            $display("MVP_SUMMARY|FAIL|%0d|%0d", 6-errors, errors);
            $finish_and_return(1);
        end
    end

    initial begin
        #200000;
        $display("MVP_RESULT|TIMEOUT|FAIL|simulation timeout");
        $finish_and_return(3);
    end
endmodule
