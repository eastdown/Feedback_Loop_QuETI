`timescale 1ns / 1ps

module offset_scale_ctrl #(
    parameter DATA_WIDTH = 16,
    parameter SCALE_FRAC_BITS = 13 // 13비트 소수점 (8192가 1.0을 의미)
)(
    input clk,
    input resetn,
    input ttl_en,

    // [채널 1/2용 AXI GPIO 1]
    input signed [DATA_WIDTH - 1 : 0] offset,
    input signed [DATA_WIDTH - 1 : 0] scale,
    
    // [채널 1/2용 AXI GPIO 2]
    input signed [DATA_WIDTH - 1 : 0] scale_i, 
    input signed [DATA_WIDTH - 1 : 0] threshold, 
    
    input signed [DATA_WIDTH - 1 : 0] data_i_tdata,
    input data_i_tvalid,
    
    output reg signed [DATA_WIDTH - 1 : 0] data_o_tdata,
    output reg data_o_tvalid
);

    // -------------------------------------------------------------------------
    // 0. TTL Enable 동기화
    // -------------------------------------------------------------------------
    // ttl_en은 외부 DIO에서 들어오는 비동기 신호이므로
    // FPGA clk에 맞게 2단 플립플롭으로 동기화한다.
    reg ttl_meta;
    reg ttl_sync;
    
    always @(posedge clk) begin
        if (resetn == 0) begin
            ttl_meta <= 1'b0;
            ttl_sync <= 1'b0;
        end else begin
            ttl_meta <= ttl_en;
            ttl_sync <= ttl_meta;
        end
    end
    
    wire servo_en = ttl_sync;

    // 공통 Saturation (포화 방지) 제한값
    // 예: 16비트일 경우 MAX = 32767, MIN = -32768
    wire signed [DATA_WIDTH - 1 : 0] MAX_VAL = (1 << (DATA_WIDTH-1)) - 1;
    wire signed [DATA_WIDTH - 1 : 0] MIN_VAL = -(1 << (DATA_WIDTH-1));

    // -------------------------------------------------------------------------
    // 1. 에러 계산 (오버플로우 방지를 위해 1비트 확장)
    // -------------------------------------------------------------------------
    wire signed [DATA_WIDTH : 0] error = $signed(offset) - $signed(data_i_tdata);

    // -------------------------------------------------------------------------
    // 2. 비례(P) 연산 및 개별 Saturation
    // -------------------------------------------------------------------------
    // DATA_WIDTH가 16일 때, 17bit(error) * 16bit(scale) = 33bit 필요
    wire signed [(DATA_WIDTH*2) : 0] p_mult = error * $signed(scale);
    wire signed [(DATA_WIDTH*2) : 0] p_shifted = p_mult >>> SCALE_FRAC_BITS;
    
    // P항 Saturation (조합 회로)
    wire signed [DATA_WIDTH - 1 : 0] p_sat;
    assign p_sat = (p_shifted > $signed(MAX_VAL)) ? MAX_VAL :
                   (p_shifted < $signed(MIN_VAL)) ? MIN_VAL :
                   p_shifted[DATA_WIDTH-1:0];

    // -------------------------------------------------------------------------
    // 3. 적분(I) 연산 준비 및 Wind-up 제한값 설정
    // -------------------------------------------------------------------------
    reg signed [31:0] i_accumulator;
    wire signed [(DATA_WIDTH*2) : 0] i_mult = error * $signed(scale_i);
    wire signed [DATA_WIDTH - 1 : 0] i_term = i_accumulator >>> SCALE_FRAC_BITS;

    // Accumulator용 최대/최소값 동적 생성 (매직 넘버 제거)
    // i_term이 MAX_VAL을 넘지 않도록 Accumulator 자체의 한계치를 설정
    wire signed [31:0] I_ACCUM_MAX = $signed(MAX_VAL) <<< SCALE_FRAC_BITS;
    wire signed [31:0] I_ACCUM_MIN = $signed(MIN_VAL) <<< SCALE_FRAC_BITS;

    // -------------------------------------------------------------------------
    // 4. 최종 출력 연산 (P + I)
    // -------------------------------------------------------------------------
    wire signed [DATA_WIDTH : 0] sum_res = $signed(p_sat) + $signed(i_term);

    // -------------------------------------------------------------------------
    // 5. 순차 회로 (Sequential Logic)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if(resetn == 0) begin
            data_o_tdata <= 0;
            data_o_tvalid <= 0;
            i_accumulator <= 0;
        end else begin

            // valid는 기존 코드처럼 입력 valid를 따라가게 둔다.
            data_o_tvalid <= data_i_tvalid;

            // -----------------------------------------------------------------
            // Servo ON 상태
            // ttl_en = 1이고, 입력 데이터가 valid일 때만 PI 계산 수행
            // -----------------------------------------------------------------
            if (servo_en && data_i_tvalid) begin
                
                // --- I항 Accumulator 계산 및 Wind-up Saturation ---
                if (data_i_tdata > threshold) begin
                    if (i_accumulator + i_mult > I_ACCUM_MAX) begin
                        i_accumulator <= I_ACCUM_MAX;
                    end else if (i_accumulator + i_mult < I_ACCUM_MIN) begin
                        i_accumulator <= I_ACCUM_MIN;
                    end else begin
                        i_accumulator <= i_accumulator + i_mult;
                    end
                end
                // else: Auto-Hold (i_accumulator 유지)

                // --- 최종 SUM Saturation ---
                if (sum_res > $signed(MAX_VAL)) begin
                    data_o_tdata <= MAX_VAL;
                end else if (sum_res < $signed(MIN_VAL)) begin
                    data_o_tdata <= MIN_VAL;
                end else begin
                    data_o_tdata <= sum_res[DATA_WIDTH-1:0];
                end
            end

            // -----------------------------------------------------------------
            // Servo OFF 상태
            // ttl_en = 0이면 PID 계산 정지
            // I accumulator 유지
            // output도 마지막 값 유지
            // -----------------------------------------------------------------
            else begin
                i_accumulator <= i_accumulator;
                data_o_tdata <= data_o_tdata;
            end
        end
    end
endmodule