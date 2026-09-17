// =============================================================================
// spw_enc — SpaceWire Encoding Layer (D-S 인코딩/디코딩, 문자 조립, 패리티)
// ECSS-E-ST-50-12C Rev.1 §5.4 / HO_04_RTL_Design_v3.md §5.2 / HO_03_Checklist_v2.md §4.2
//
// 근거: spw_ref_model.py SpWEncoder(156~220행) / SpWDecoder(226~342행)
//
// [필수 정정, ERRATA-8] checklist 4.2 "Even parity(모든 비트 XOR)" 서술은 stale.
//   실제로는 심볼마다 독립적인 self-contained ODD parity:
//   [P, flag, payload] 전체의 1의 개수가 홀수가 되도록 P 를 정한다.
//   (spw_ref_model.py 194~203행, ECSS Figure 5-15 예제로 교차검증됨)
//
// [필수 정정, ERRATA-7] Control code = FCT:00 EOP:10 EEP:01 ESC:11 (LSB가 code[0]).
//   Data/Control payload 비트 모두 LSB 먼저 송수신.
//
// 인터페이스 명명 정리 (spw_phy 포트와 일치시킴):
//   RX: i_rx_data_bit / i_rx_strobe_bit  <- spw_phy.ow_rx_data_bit/strobe_bit (이미 2FF 동기화됨)
//   TX: ow_tx_data_bit / ow_tx_strobe_bit -> spw_phy.i_tx_data_bit/strobe_bit
//
// 캐릭터 9비트 포맷 (spw_datalink <-> spw_enc 내부 규약):
//   bit[8]=0            : Data-shaped 문자 (DATA 또는 ESC 다음의 Timecode 페이로드), bit[7:0]=값
//   bit[8]=1, bit[1:0]  : Control 문자, code = FCT(00)/EEP(01)/EOP(10)/ESC(11)
// =============================================================================

module spw_enc #(
    parameter int CLK_FREQ_HZ  = 100_000_000,
    parameter int TX_RATE_MBPS = 10
) (
    input  logic i_clk,
    input  logic i_rst_n,

    // ── Link(spw_datalink) 제어 ──────────────────────────────────
    // [정정, HO_01_Encoding_Layer_DeepDive.md 부록A 반영] Enable 레벨 신호가
    // 아니라, ErrorReset 진입 그 클럭에만 1클럭 assert 되는 pulse 리셋이다.
    // enc/dec 는 그 외엔 항상 동작한다 — Started/Connecting 단계에서도
    // gotNull/gotFCT 감지를 위해 문자 디코딩이 계속 이뤄져야 하므로,
    // "Run 상태에서만 enable" 식의 레벨 게이팅은 링크 수립 자체를 막는다.
    input  logic i_enc_reset,   // datalink 가 ErrorReset 진입 시 1클럭 pulse

    // ── TX 캐릭터 인터페이스 (spw_datalink -> spw_enc) ────────────
    input  logic [8:0] i_tx_char,
    input  logic        i_tx_char_valid,
    output logic        ow_tx_char_ready,

    // ── RX 캐릭터 인터페이스 (spw_enc -> spw_datalink) ────────────
    output logic [8:0] ow_rx_char,
    output logic        ow_rx_char_valid,
    output logic        ow_parity_err,

    // ── spw_phy 인터페이스 ─────────────────────────────────────────
    output logic ow_tx_data_bit,
    output logic ow_tx_strobe_bit,
    input  logic i_rx_data_bit,
    input  logic i_rx_strobe_bit
);

    // ── Control code (ERRATA-7) ───────────────────────────────────
    localparam logic [1:0] CODE_FCT = 2'b00;
    localparam logic [1:0] CODE_EEP = 2'b01;
    localparam logic [1:0] CODE_EOP = 2'b10;
    localparam logic [1:0] CODE_ESC = 2'b11;

    // ── TX bit-period divider ────────────────────────────────────
    localparam int BIT_PERIOD_CYCLES = CLK_FREQ_HZ / (TX_RATE_MBPS * 1_000_000);
    localparam int BPC_W = (BIT_PERIOD_CYCLES <= 1) ? 1 : $clog2(BIT_PERIOD_CYCLES);

    // =================================================================
    // TX 측 — 문자 조립 + parity 생성 + 직렬화
    // =================================================================

    // ── 내부 comb wire ───────────────────────────────────────────
    logic       w_tx_flag;
    logic [7:0] w_tx_payload8;      // DATA 인 경우 그대로 8비트 (이미 LSB-first)
    logic [1:0] w_tx_code;          // Control 인 경우 코드
    logic       w_tx_parity_ones;   // flag + payload 1의 개수 패리티(홀/짝)
    logic       w_tx_p_bit;         // 계산된 parity 비트
    logic [3:0] w_tx_len;           // 이번 심볼 총 비트수 (control:4, data:10)
    logic [9:0] w_tx_load_bits;     // [0]=P [1]=flag [2+:8]=payload(control 은 [2:3]만 유효)
    logic       w_tx_load;          // 새 문자 로드 pulse (accept)

    logic [9:0] r_tx_shift;         // 남은 비트, LSB(r_tx_shift[0]) 가 다음에 나갈 비트
    logic [3:0] r_tx_bits_left;
    logic [BPC_W-1:0] r_tx_cyc_cnt;

    logic r_prev_tx_bit_d, r_prev_tx_bit_s;   // self-clocking 용 이전 D/S 값
    logic or_tx_data_bit, or_tx_strobe_bit;

    always_comb begin
        w_tx_flag     = i_tx_char[8];
        w_tx_payload8 = i_tx_char[7:0];
        w_tx_code     = i_tx_char[1:0];

        // ones(payload) : DATA=8비트 popcount, Control=2비트 popcount
        w_tx_parity_ones = w_tx_flag
                            ? (w_tx_code[0] ^ w_tx_code[1])
                            : (^w_tx_payload8);
        // 전체(P 포함) 1의 개수가 홀수가 되도록 P 선택 [ERRATA-8]
        w_tx_p_bit = ~(w_tx_flag ^ w_tx_parity_ones);

        w_tx_len = w_tx_flag ? 4'd4 : 4'd10;

        // 로드 비트 순서: [0]=P [1]=flag [2]=payload bit0 ... LSB 먼저 [ERRATA-7]
        // (concat 한 번으로 전체 계산 — always_comb 내 부분 비트 대입은 피함)
        if (w_tx_flag) begin
            w_tx_load_bits = {6'b0, w_tx_code[1], w_tx_code[0], w_tx_flag, w_tx_p_bit};
        end else begin
            w_tx_load_bits = {w_tx_payload8, w_tx_flag, w_tx_p_bit};
        end

        w_tx_load = i_tx_char_valid && (r_tx_bits_left == 4'd0) && !i_enc_reset;
    end

    assign ow_tx_char_ready = (r_tx_bits_left == 4'd0) && !i_enc_reset;

    // ── TX shift-out FF ───────────────────────────────────────────
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_tx_shift     <= '0;
            r_tx_bits_left <= '0;
            r_tx_cyc_cnt   <= '0;
        end else if (i_enc_reset) begin
            // sync reset: 진행 중이던 부분 문자 폐기 (encoder.reset() 과 동일 취지,
            // datalink 가 ErrorReset 진입하는 그 클럭에 1클럭만 assert)
            r_tx_shift     <= '0;
            r_tx_bits_left <= '0;
            r_tx_cyc_cnt   <= '0;
        end else begin
            if (w_tx_load) begin
                // 이번 클럭에 bit0(P) 를 이미 내보내므로(w_tx_pop), 레지스터도
                // 그만큼 미리 shift 하고 남은 길이도 1 줄여서 로드한다.
                // (이렇게 안 하면 P 비트가 중복 전송되어 심볼이 1비트 밀림)
                r_tx_shift     <= w_tx_load_bits >> 1;
                r_tx_bits_left <= w_tx_len - 4'd1;
                r_tx_cyc_cnt   <= '0;
            end else if (r_tx_bits_left != 4'd0) begin
                if (r_tx_cyc_cnt == BPC_W'(BIT_PERIOD_CYCLES - 1)) begin
                    r_tx_cyc_cnt   <= '0;
                    r_tx_shift     <= r_tx_shift >> 1;
                    r_tx_bits_left <= r_tx_bits_left - 4'd1;
                end else begin
                    r_tx_cyc_cnt <= r_tx_cyc_cnt + 1'b1;
                end
            end
        end
    end

    // 이번 클럭에 새 비트를 내보내는 시점(pop) 인지: 로드 직후 또는 divider 만료 시
    logic w_tx_pop;
    assign w_tx_pop = w_tx_load || (!i_enc_reset && (r_tx_bits_left != 4'd0)
                                     && (r_tx_cyc_cnt == BPC_W'(BIT_PERIOD_CYCLES - 1)));

    logic w_tx_next_bit;
    assign w_tx_next_bit = w_tx_load ? w_tx_load_bits[0] : r_tx_shift[0];

    // ── DS self-clocking 인코딩: S(n) = NOT(D(n) XOR D(n-1) XOR S(n-1)) ───
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            or_tx_data_bit   <= 1'b0;
            or_tx_strobe_bit <= 1'b0;
            r_prev_tx_bit_d  <= 1'b0;
            r_prev_tx_bit_s  <= 1'b0;
        end else if (w_tx_pop) begin
            or_tx_data_bit   <= w_tx_next_bit;
            or_tx_strobe_bit <= ~(w_tx_next_bit ^ r_prev_tx_bit_d ^ r_prev_tx_bit_s);
            r_prev_tx_bit_d  <= w_tx_next_bit;
            r_prev_tx_bit_s  <= ~(w_tx_next_bit ^ r_prev_tx_bit_d ^ r_prev_tx_bit_s);
        end
        // pop 이 없는 사이클엔 라인 값 유지 (자기 클럭 방식 — 값이 유지돼야 수신측이 무변화로 판단)
    end

    assign ow_tx_data_bit   = or_tx_data_bit;
    assign ow_tx_strobe_bit = or_tx_strobe_bit;

    // =================================================================
    // RX 측 — 변화 감지 + 문자 파싱 + parity 검사
    // =================================================================

    typedef enum logic [1:0] {
        RX_WAIT_PARITY = 2'd0,
        RX_WAIT_FLAG   = 2'd1,
        RX_WAIT_BITS   = 2'd2
    } rx_state_e;

    rx_state_e r_rx_state;
    logic       r_rx_prev_data, r_rx_prev_strobe;
    logic       r_rx_parity_bit;
    logic       r_rx_flag;
    logic [3:0] r_rx_need;
    logic [3:0] r_rx_cnt;
    logic [7:0] r_rx_acc;

    logic       w_rx_changed;
    logic       w_rx_bit;

    always_comb begin
        w_rx_changed = (i_rx_data_bit != r_rx_prev_data) || (i_rx_strobe_bit != r_rx_prev_strobe);
        w_rx_bit     = i_rx_data_bit;   // 변화 시점의 Data 라인 값 = 수신 비트
    end

    logic       or_rx_char_valid;
    logic [8:0] or_rx_char;
    logic       or_parity_err;

    logic       w_rx_finish;
    logic [3:0] w_rx_need_next;
    logic       w_rx_ones_parity;

    assign w_rx_finish    = w_rx_changed && (r_rx_state == RX_WAIT_BITS) && (r_rx_cnt + 4'd1 == r_rx_need);
    assign w_rx_need_next = w_rx_bit ? 4'd2 : 4'd8;   // WAIT_FLAG 에서 다음 필요 비트수 계산용

    // ones(parity 포함) — WAIT_BITS 완료 시점, 방금 들어온 비트까지 포함해서 계산
    logic [7:0] w_rx_acc_next;
    assign w_rx_acc_next    = r_rx_acc | (8'(w_rx_bit) << r_rx_cnt);
    assign w_rx_ones_parity = r_rx_parity_bit ^ r_rx_flag ^ (^w_rx_acc_next);

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_rx_prev_data   <= 1'b0;
            r_rx_prev_strobe <= 1'b0;
            r_rx_state       <= RX_WAIT_PARITY;
            r_rx_parity_bit  <= 1'b0;
            r_rx_flag        <= 1'b0;
            r_rx_need        <= 4'd0;
            r_rx_cnt         <= 4'd0;
            r_rx_acc         <= 8'd0;
            or_rx_char_valid <= 1'b0;
            or_rx_char       <= 9'd0;
            or_parity_err    <= 1'b0;
        end else begin
            // 매 클럭 1클럭 pulse 신호들은 기본적으로 내림
            or_rx_char_valid <= 1'b0;
            or_parity_err    <= 1'b0;

            // 라인 레벨 변화 추적은 framing_reset 과 무관하게 항상 계속한다
            // (DeepDive 부록A: prev_data/prev_strobe 는 i_rst_n 으로만 초기화)
            r_rx_prev_data   <= i_rx_data_bit;
            r_rx_prev_strobe <= i_rx_strobe_bit;

            if (i_enc_reset) begin
                // sync reset: 프레이밍 상태만 초기화 (reset_framing() 과 동일 취지).
                // ErrorReset 진입 그 클럭에 1클럭만 assert.
                r_rx_state <= RX_WAIT_PARITY;
                r_rx_need  <= 4'd0;
                r_rx_cnt   <= 4'd0;
                r_rx_acc   <= 8'd0;
            end else begin
                if (w_rx_changed) begin
                    unique case (r_rx_state)
                        RX_WAIT_PARITY: begin
                            r_rx_parity_bit <= w_rx_bit;
                            r_rx_state      <= RX_WAIT_FLAG;
                        end
                        RX_WAIT_FLAG: begin
                            r_rx_flag  <= w_rx_bit;
                            r_rx_need  <= w_rx_bit ? 4'd2 : 4'd8;
                            r_rx_cnt   <= 4'd0;
                            r_rx_acc   <= 8'd0;
                            r_rx_state <= RX_WAIT_BITS;
                        end
                        RX_WAIT_BITS: begin
                            if (w_rx_finish) begin
                                // 문자 완성 — parity 검사 + 조립
                                or_parity_err    <= ~w_rx_ones_parity;   // 홀수여야 정상
                                or_rx_char_valid <= 1'b1;
                                if (r_rx_flag) begin
                                    or_rx_char <= {1'b1, 6'd0, w_rx_acc_next[1:0]};
                                end else begin
                                    or_rx_char <= {1'b0, w_rx_acc_next};
                                end
                                r_rx_state <= RX_WAIT_PARITY;
                                r_rx_cnt   <= 4'd0;
                                r_rx_acc   <= 8'd0;
                            end else begin
                                r_rx_acc <= w_rx_acc_next;
                                r_rx_cnt <= r_rx_cnt + 4'd1;
                            end
                        end
                        default: r_rx_state <= RX_WAIT_PARITY;
                    endcase
                end
            end
        end
    end

    assign ow_rx_char_valid = or_rx_char_valid;
    assign ow_rx_char       = or_rx_char;
    assign ow_parity_err    = or_parity_err;

endmodule
