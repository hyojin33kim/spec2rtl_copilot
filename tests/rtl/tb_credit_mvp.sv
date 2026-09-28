`timescale 1ns/1ps

module tb_credit_mvp;
    logic clk = 0;
    logic rst_n = 0;
    logic link_en = 0;
    logic link_start = 0;
    logic enc_ready = 0;
    logic port_reset = 0;
    logic parity_err = 0;
    logic disconnect = 0;
    logic [2:0] link_state;
    logic [8:0] rx_char = 0;
    logic rx_char_valid = 0;
    logic [8:0] nchar_data = 9'h05a;
    logic nchar_valid = 0;
    logic nchar_ready;
    logic [7:0] rx_free_space = 0;
    logic err_credit;
    logic err_disconnect;
    logic err_parity;
    logic err_esc;
    logic [8:0] rx_out_data;
    logic rx_out_valid;
    logic rx_out_ctrl;

    logic enc_reset = 0;
    logic [8:0] enc_tx_char = 0;
    logic enc_tx_valid = 0;
    logic enc_tx_ready;
    logic [8:0] enc_rx_char;
    logic enc_rx_valid;
    logic enc_parity_err;
    logic enc_ds_data;
    logic enc_ds_strobe;
    integer enc_ds_transitions = 0;

    logic phy_link_reset = 0;
    logic phy_rx_data = 0;
    logic phy_rx_strobe = 0;
    logic phy_disconnect;

    logic enc_comp_rx_enable = 0;
    logic enc_comp_raw_parity = 0;
    logic enc_comp_got_null;
    logic enc_comp_parity_error;
    logic [8:0] enc_comp_null_window;
    logic [3:0] enc_comp_window_bits;

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
        .i_auto_start(1'b0), .i_port_reset(port_reset),
        .i_rx_char_valid(rx_char_valid), .i_rx_char(rx_char),
        .i_parity_err(parity_err), .i_disconnect(disconnect),
        .ow_tx_char_valid(), .ow_tx_char(), .i_enc_ready(enc_ready),
        .ow_enc_reset(),
        .i_nchar_data(nchar_data), .i_nchar_valid(nchar_valid),
        .ow_nchar_ready(nchar_ready),
        .ow_rx_char_data(rx_out_data), .ow_rx_char_valid(rx_out_valid), .ow_rx_char_ctrl(rx_out_ctrl),
        .i_rx_free_space(rx_free_space),
        .i_tick_in(1'b0), .i_time_in(8'b0),
        .ow_tick_out(), .ow_time_out(),
        .ow_link_state(link_state),
        .ow_err_disconnect(err_disconnect), .ow_err_parity(err_parity), .ow_err_esc(err_esc),
        .ow_err_credit(err_credit), .ow_err_tx_invalid()
    );

    spw_enc enc_dut (
        .i_clk(clk), .i_rst_n(rst_n), .i_enc_reset(enc_reset),
        .i_tx_char(enc_tx_char), .i_tx_char_valid(enc_tx_valid),
        .ow_tx_char_ready(enc_tx_ready),
        .ow_rx_char(enc_rx_char), .ow_rx_char_valid(enc_rx_valid),
        .ow_parity_err(enc_parity_err),
        .ow_tx_data_bit(enc_ds_data), .ow_tx_strobe_bit(enc_ds_strobe),
        .i_rx_data_bit(enc_ds_data), .i_rx_strobe_bit(enc_ds_strobe)
    );

    spw_phy #(
        .CLK_FREQ_HZ(100_000_000), .DISCONNECT_TIMEOUT_NS(850)
    ) phy_dut (
        .i_clk(clk), .i_rst_n(rst_n), .i_link_reset(phy_link_reset),
        .i_ds_rx_data(phy_rx_data), .i_ds_rx_strobe(phy_rx_strobe),
        .ow_ds_tx_data(), .ow_ds_tx_strobe(),
        .ow_rx_data_bit(), .ow_rx_strobe_bit(),
        .i_tx_data_bit(1'b0), .i_tx_strobe_bit(1'b0),
        .ow_disconnect(phy_disconnect)
    );

    spw_encoding_compliance enc_compliance (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_rx_enable(enc_comp_rx_enable),
        .i_rx_data(enc_ds_data), .i_rx_strobe(enc_ds_strobe),
        .i_raw_parity_error(enc_comp_raw_parity),
        .ow_got_null(enc_comp_got_null),
        .ow_parity_error(enc_comp_parity_error),
        .ow_null_window(enc_comp_null_window),
        .ow_window_bits(enc_comp_window_bits)
    );

    always @(enc_ds_data or enc_ds_strobe) enc_ds_transitions = enc_ds_transitions + 1;

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

    task set_rx_credit(input logic [5:0] value);
        @(negedge clk);
        force dut.r_rx_credit = value;
        @(posedge clk); #1;
        release dut.r_rx_credit;
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

    task enc_roundtrip(input logic [8:0] ch, output logic [8:0] observed, output bit received);
        int wait_count;
        while (!enc_tx_ready) tick();
        @(negedge clk);
        enc_tx_char = ch;
        enc_tx_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        enc_tx_valid = 1'b0;
        wait_count = 0;
        while (!enc_rx_valid && wait_count < 240) begin
            tick();
            wait_count++;
        end
        observed = enc_rx_char;
        received = enc_rx_valid;
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
        report_check("REQ-FCT-INIT", dut.r_req_initial_fct === 3'd7,
                     $sformatf("initial_fct_requests=%0d expected=7", dut.r_req_initial_fct));
        enc_ready = 1'b1;
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
        report_check("REQ-LINK-INIT", link_state === 3'd5,
                     $sformatf("link_state=%0d expected=5(Run)", link_state));

        // REQ-FCT-ELIGIBLE: both FIFO space and logical credit bound gate FCT.
        enc_ready = 1'b0;
        force dut.r_eep_pending = 1'b0;
        force dut.r_rx_credit = 6'd0;
        rx_free_space = 8'd7; #1;
        guard = (dut.w_fct_send_ok === 1'b0);
        rx_free_space = 8'd8; #1;
        guard = guard && (dut.w_fct_send_ok === 1'b1);
        force dut.r_rx_credit = 6'd49; #1;
        guard = guard && (dut.w_fct_send_ok === 1'b0);
        report_check("REQ-FCT-ELIGIBLE", guard,
                     $sformatf("space=%0d rx_credit=%0d send_ok=%0b",
                               rx_free_space, dut.r_rx_credit, dut.w_fct_send_ok));
        release dut.r_rx_credit;
        release dut.r_eep_pending;
        rx_free_space = 8'd0;
        enc_ready = 1'b1;

        // REQ-RC-ACCOUNT: received N-Char consumes one granted receive credit.
        set_rx_credit(6'd8);
        send_char({1'b0, 8'h3c});
        guard = (dut.r_rx_credit === 6'd7);
        // An independent FCT sent to the peer grants eight receive credits.
        while (dut.r_esc_pending) tick();
        set_rx_credit(6'd8);
        rx_free_space = 8'd8;
        wait (dut.w_send_fct === 1'b1);
        @(posedge clk); #1;
        guard = guard && (dut.w_send_fct === 1'b1) && (dut.r_rx_credit === 6'd16);
        report_check("REQ-RC-ACCOUNT", guard,
                     $sformatf("send_fct=%0b rx_credit=%0d expected=16",
                               dut.w_send_fct, dut.r_rx_credit));
        rx_free_space = 8'd0;

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

        // REQ-RC-ERR: receiving an N-Char with no granted credit is an error.
        force dut.r_state = 3'd5;
        force dut.r_rx_credit = 6'd0;
        @(negedge clk);
        rx_char = {1'b0, 8'ha5};
        rx_char_valid = 1'b1;
        #1;
        guard = (dut.w_rx_credit_err === 1'b1) && (err_credit === 1'b1)
             && (dut.w_next_state === 3'd0);
        report_check("REQ-RC-ERR", guard,
                     $sformatf("rx_credit_error=%0b credit_error=%0b next_state=%0d",
                               dut.w_rx_credit_err, err_credit, dut.w_next_state));
        rx_char_valid = 1'b0;
        release dut.r_rx_credit;
        release dut.r_state;

        // REQ-LINK-ERROR: disconnect, parity and invalid ESC pairs drive ErrorReset.
        force dut.r_state = 3'd5;
        force dut.r_gotnull_latch = 1'b1;
        disconnect = 1'b1; #1;
        guard = (err_disconnect === 1'b1) && (dut.w_next_state === 3'd0);
        disconnect = 1'b0;
        parity_err = 1'b1; #1;
        guard = guard && (err_parity === 1'b1) && (dut.w_next_state === 3'd0);
        parity_err = 1'b0;
        force dut.r_rx_pending_esc = 1'b1;
        rx_char = {1'b1, 6'b0, 2'b01};
        rx_char_valid = 1'b1; #1;
        guard = guard && (err_esc === 1'b1) && (dut.w_next_state === 3'd0);
        report_check("REQ-LINK-ERROR", guard,
                     $sformatf("disconnect=%0b parity=%0b esc=%0b next_state=%0d",
                               err_disconnect, err_parity, err_esc, dut.w_next_state));
        rx_char_valid = 1'b0;
        release dut.r_rx_pending_esc;
        release dut.r_gotnull_latch;
        release dut.r_state;

        // REQ-PKT-RECOVERY: an interrupted RX packet inserts EEP once space returns.
        force dut.r_state = 3'd5;
        force dut.r_rx_credit = 6'd1;
        rx_free_space = 8'd0;
        send_char({1'b0, 8'h55});
        port_reset = 1'b1;
        tick();
        port_reset = 1'b0;
        guard = (dut.r_eep_pending === 1'b1);
        rx_free_space = 8'd1; #1;
        guard = guard && (dut.w_eep_write_now === 1'b1) && (rx_out_valid === 1'b1)
             && (rx_out_ctrl === 1'b1) && (rx_out_data === 9'h101);
        tick();
        guard = guard && (dut.r_eep_pending === 1'b0);
        release dut.r_rx_credit;
        release dut.r_state;

        // TX side: an interrupted packet is popped and discarded through its terminator.
        force dut.r_state = 3'd5;
        force dut.r_tx_credit = 6'd2;
        rx_free_space = 8'd0;
        while (dut.r_esc_pending) tick();
        @(negedge clk);
        nchar_data = {1'b0, 8'h66};
        nchar_valid = 1'b1;
        wait (dut.w_send_nchar === 1'b1);
        @(posedge clk); #1;
        port_reset = 1'b1;
        @(posedge clk); #1;
        port_reset = 1'b0;
        guard = guard && (dut.r_tx_flushing === 1'b1);
        nchar_data = 9'h100;
        #1;
        guard = guard && (nchar_ready === 1'b1) && (dut.w_send_nchar === 1'b0);
        @(posedge clk); #1;
        guard = guard && (dut.r_tx_flushing === 1'b0);
        report_check("REQ-PKT-RECOVERY", guard,
                     $sformatf("eep_pending=%0b tx_flushing=%0b ready=%0b",
                               dut.r_eep_pending, dut.r_tx_flushing, nchar_ready));
        nchar_valid = 1'b0;
        release dut.r_tx_credit;
        release dut.r_state;

        // REQ-ENC-FIRST-NULL / NULL-DETECT / PARITY-GATE:
        // use the real encoder D/S output and the project compliance guard.
        begin
            logic [8:0] observed;
            bit received;
            bit first_null_ok;
            bit null_detect_ok;
            bit parity_gate_ok;
            bit first_ds_data;
            bit first_ds_strobe;
            logic [8:0] detected_null_window;
            logic [3:0] detected_window_bits;
            integer wait_count;

            enc_reset = 1'b1;
            tick();
            enc_reset = 1'b0;
            enc_comp_rx_enable = 1'b1;
            enc_comp_raw_parity = 1'b1;
            #1;
            parity_gate_ok = (enc_comp_parity_error === 1'b0);
            enc_comp_raw_parity = 1'b0;

            while (!enc_tx_ready) tick();
            first_null_ok = (enc_ds_data === 1'b0) && (enc_ds_strobe === 1'b0);
            @(negedge clk);
            enc_tx_char = {1'b1, 6'b0, CODE_ESC};
            enc_tx_valid = 1'b1;
            @(posedge clk); #1;
            first_ds_data = enc_ds_data;
            first_ds_strobe = enc_ds_strobe;
            first_null_ok = first_null_ok
                         && (first_ds_data === 1'b0) && (first_ds_strobe === 1'b1);
            @(negedge clk);
            enc_tx_valid = 1'b0;
            wait_count = 0;
            while (!enc_rx_valid && wait_count < 100) begin
                tick();
                wait_count++;
            end
            first_null_ok = first_null_ok && enc_rx_valid
                         && (enc_rx_char === {1'b1, 6'b0, CODE_ESC});
            report_check("REQ-ENC-FIRST-NULL", first_null_ok,
                         $sformatf("first_ds=%0b%0b first_symbol=0x%03h",
                                   first_ds_data, first_ds_strobe, enc_rx_char));

            enc_roundtrip({1'b1, 6'b0, CODE_FCT}, observed, received);
            null_detect_ok = received && !enc_comp_got_null
                          && (enc_comp_window_bits === 4'd8);
            enc_roundtrip({1'b1, 6'b0, CODE_ESC}, observed, received);
            null_detect_ok = null_detect_ok && received && enc_comp_got_null
                          && (enc_comp_null_window === 9'b011101000)
                          && (enc_comp_window_bits === 4'd9);
            detected_null_window = enc_comp_null_window;
            detected_window_bits = enc_comp_window_bits;
            repeat (2) tick();
            null_detect_ok = null_detect_ok && enc_comp_got_null;

            enc_comp_raw_parity = 1'b1;
            #1;
            parity_gate_ok = parity_gate_ok && (enc_comp_parity_error === 1'b1);
            @(negedge clk);
            enc_comp_rx_enable = 1'b0;
            @(posedge clk); #1;
            null_detect_ok = null_detect_ok && !enc_comp_got_null
                          && (enc_comp_window_bits === 4'd0);
            parity_gate_ok = parity_gate_ok && (enc_comp_parity_error === 1'b0);
            enc_comp_raw_parity = 1'b0;

            report_check("REQ-ENC-NULL-DETECT", null_detect_ok,
                         $sformatf("pattern=0x%03h bits=%0d cleared=%0b",
                                   detected_null_window, detected_window_bits,
                                   !enc_comp_got_null));
            report_check("REQ-ENC-PARITY-GATE", parity_gate_ok,
                         $sformatf("rx_enable=%0b got_null=%0b valid_error=%0b",
                                   enc_comp_rx_enable, enc_comp_got_null,
                                   enc_comp_parity_error));
        end

        // REQ-ENC-SYMBOL: serialization preserves DATA/control values and order.
        begin
            logic [8:0] observed;
            bit received;
            bit symbol_ok;
            integer transitions_before;
            symbol_ok = 1'b1;
            transitions_before = enc_ds_transitions;
            enc_roundtrip({1'b0, 8'ha5}, observed, received);
            symbol_ok = symbol_ok && received && (observed === {1'b0, 8'ha5}) && !enc_parity_err;
            enc_roundtrip({1'b1, 6'b0, CODE_FCT}, observed, received);
            symbol_ok = symbol_ok && received && (observed === {1'b1, 6'b0, CODE_FCT}) && !enc_parity_err;
            enc_roundtrip({1'b1, 6'b0, 2'b10}, observed, received);
            symbol_ok = symbol_ok && received && (observed === {1'b1, 6'b0, 2'b10}) && !enc_parity_err;
            enc_roundtrip({1'b1, 6'b0, 2'b01}, observed, received);
            symbol_ok = symbol_ok && received && (observed === {1'b1, 6'b0, 2'b01}) && !enc_parity_err;
            enc_roundtrip({1'b1, 6'b0, CODE_ESC}, observed, received);
            symbol_ok = symbol_ok && received && (observed === {1'b1, 6'b0, CODE_ESC}) && !enc_parity_err;
            report_check("REQ-ENC-SYMBOL", symbol_ok,
                         $sformatf("last_char=0x%03h parity=%0b", observed, enc_parity_err));
            report_check("REQ-ENC-DS-CORE",
                         symbol_ok && enc_ds_transitions > transitions_before,
                         $sformatf("ds_transitions=%0d initial_reset=00",
                                   enc_ds_transitions - transitions_before));
        end

        // REQ-ENC-DISCONNECT: suppress before first edge, then detect 850 ns idle.
        guard = (phy_disconnect === 1'b0) && (phy_dut.r_seen_any_transition === 1'b0);
        @(negedge clk); phy_rx_strobe = ~phy_rx_strobe;
        repeat (4) tick();
        guard = guard && (phy_dut.r_seen_any_transition === 1'b1);
        begin
            bit detected;
            integer wait_count;
            detected = 1'b0;
            for (wait_count = 0; wait_count < 100; wait_count++) begin
                tick();
                if (phy_disconnect) detected = 1'b1;
            end
            guard = guard && detected;
            report_check("REQ-ENC-DISCONNECT", guard,
                         $sformatf("seen_edge=%0b detected=%0b timeout_ns=850",
                                   phy_dut.r_seen_any_transition, detected));
        end

        // REQ-ENC-ESC: ESC+ESC/EOP/EEP are invalid only as enabled link errors after gotNull.
        force dut.r_state = 3'd5;
        force dut.r_rx_pending_esc = 1'b1;
        force dut.r_gotnull_latch = 1'b1;
        rx_char_valid = 1'b1;
        rx_char = {1'b1, 6'b0, CODE_ESC}; #1;
        guard = (dut.w_esc_error === 1'b1) && (dut.w_next_state === 3'd0);
        rx_char = {1'b1, 6'b0, 2'b10}; #1;
        guard = guard && (dut.w_esc_error === 1'b1) && (dut.w_next_state === 3'd0);
        rx_char = {1'b1, 6'b0, 2'b01}; #1;
        guard = guard && (dut.w_esc_error === 1'b1) && (dut.w_next_state === 3'd0);
        force dut.r_gotnull_latch = 1'b0; #1;
        guard = guard && (dut.w_esc_error === 1'b1) && (dut.w_next_state === 3'd5);
        report_check("REQ-ENC-ESC", guard,
                     $sformatf("raw_esc_error=%0b gated_next_state=%0d",
                               dut.w_esc_error, dut.w_next_state));
        rx_char_valid = 1'b0;
        release dut.r_gotnull_latch;
        release dut.r_rx_pending_esc;
        release dut.r_state;

        if (errors == 0) begin
            $display("MVP_SUMMARY|PASS|20|0");
            $finish_and_return(0);
        end else begin
            $display("MVP_SUMMARY|FAIL|%0d|%0d", 20-errors, errors);
            $finish_and_return(1);
        end
    end

    initial begin
        #200000;
        $display("MVP_RESULT|TIMEOUT|FAIL|simulation timeout");
        $finish_and_return(3);
    end
endmodule
