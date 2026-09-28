// Project-owned ECSS 5.4.6/5.4.7 compliance guard.
// Imported design snapshots under assets/ remain unchanged.
module spw_encoding_compliance (
    input  logic       i_clk,
    input  logic       i_rst_n,
    input  logic       i_rx_enable,
    input  logic       i_rx_data,
    input  logic       i_rx_strobe,
    input  logic       i_raw_parity_error,
    output logic       ow_got_null,
    output logic       ow_parity_error,
    output logic [8:0] ow_null_window,
    output logic [3:0] ow_window_bits
);
    localparam logic [8:0] FIRST_NULL_PATTERN = 9'b011101000;

    logic r_prev_data;
    logic r_prev_strobe;
    logic [8:0] r_null_window;
    logic [3:0] r_window_bits;
    logic w_rx_edge;
    logic [8:0] w_next_window;

    assign w_rx_edge = (i_rx_data != r_prev_data) || (i_rx_strobe != r_prev_strobe);
    assign w_next_window = {r_null_window[7:0], i_rx_data};

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_prev_data   <= 1'b0;
            r_prev_strobe <= 1'b0;
            r_null_window <= 9'b0;
            r_window_bits <= 4'd0;
            ow_got_null   <= 1'b0;
        end else begin
            r_prev_data   <= i_rx_data;
            r_prev_strobe <= i_rx_strobe;

            if (!i_rx_enable) begin
                r_null_window <= 9'b0;
                r_window_bits <= 4'd0;
                ow_got_null   <= 1'b0;
            end else if (w_rx_edge && !ow_got_null) begin
                r_null_window <= w_next_window;
                if (r_window_bits < 4'd9)
                    r_window_bits <= r_window_bits + 1'b1;
                if (r_window_bits >= 4'd8 && w_next_window == FIRST_NULL_PATTERN)
                    ow_got_null <= 1'b1;
            end
        end
    end

    // ECSS 5.4.7: the externally valid error exists only while RX is enabled
    // and the first complete Null has already been detected.
    assign ow_parity_error = i_rx_enable && ow_got_null && i_raw_parity_error;
    assign ow_null_window = r_null_window;
    assign ow_window_bits = r_window_bits;
endmodule
