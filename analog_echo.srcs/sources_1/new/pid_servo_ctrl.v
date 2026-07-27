`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04.05.2026 00:38:34
// Design Name: 
// Module Name: pid_servo_ctrl
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module pid_servo_ctrl #(
    parameter DATA_WIDTH = 16,
    parameter SCALE_FRAC_BITS = 13 // 13비트 소수점 (8192가 1.0을 의미)
)(
    input clk,
    input resetn,
    
    // 제어 파라미터 (Python에서 AXI GPIO를 통해 들어옴)
    input signed [DATA_WIDTH - 1 : 0] offset,    // Setpoint (목표값)
    input signed [DATA_WIDTH - 1 : 0] scale_p,   // Kp (비례 게인)
    input signed [DATA_WIDTH - 1 : 0] scale_i,   // Ki (적분 게인)
    input hold,                                  // Hold 신호 (1이면 적분 멈춤, 0이면 정상 동작)
    
    // 데이터 입출력 (ADC에서 들어오고 DAC로 나감)
    input signed [DATA_WIDTH - 1 : 0] data_i_tdata,
    input data_i_tvalid,
    output reg signed [DATA_WIDTH - 1 : 0] data_o_tdata,
    output reg data_o_tvalid
);

    // 1. 에러 계산 (목표값 - 현재 ADC 값)
    wire signed [DATA_WIDTH : 0] error = offset - data_i_tdata;

    // 2. 비례(P) 제어 연산
    wire signed [(DATA_WIDTH*2) - 1 : 0] p_mult = error * scale_p;
    wire signed [DATA_WIDTH - 1 : 0] p_term = p_mult >>> SCALE_FRAC_BITS;

    // 3. 적분(I) 제어 연산을 위한 내부 레지스터
    // 적분값은 누적되므로 데이터 폭을 크게 잡아줍니다 (오버플로우 방지)
    reg signed [31:0] i_accumulator;
    wire signed [(DATA_WIDTH*2) - 1 : 0] i_mult = error * scale_i;
    wire signed [DATA_WIDTH - 1 : 0] i_term = i_accumulator >>> SCALE_FRAC_BITS;

    // 4. P + I 합산
    wire signed [DATA_WIDTH : 0] sum_res = p_term + i_term;

    // 5. Saturation (포화 방지) 제한값 설정 (14-bit DAC 기준 최대/최소값)
    wire signed [DATA_WIDTH : 0] MAX_VAL = (1 << (DATA_WIDTH-1)) - 1; // 32767
    wire signed [DATA_WIDTH : 0] MIN_VAL = -(1 << (DATA_WIDTH-1));    // -32768

    always @(posedge clk) begin
        if(resetn == 0) begin
            data_o_tdata <= 0;
            data_o_tvalid <= 0;
            i_accumulator <= 0;
        end else begin
            // ----- 적분기 로직 (Hold 기능 포함) -----
            if (hold == 1'b0) begin
                // 레이저가 켜져 있을 때 (hold=0): 에러를 계속 누적합니다.
                
                // 적분기 Saturation (Wind-up 방지)
                // 적분값이 너무 커지거나 작아지지 않도록 제한합니다.
                if (i_accumulator + i_mult > 32'sd1073741823) begin // 임의의 큰 제한값
                    i_accumulator <= 32'sd1073741823;
                end else if (i_accumulator + i_mult < -32'sd1073741824) begin
                    i_accumulator <= -32'sd1073741824;
                end else begin
                    i_accumulator <= i_accumulator + i_mult;
                end
            end
            // hold가 1일 때는 i_accumulator 값이 이전 상태로 유지됩니다.

            // ----- 최종 출력 로직 (P + I) -----
            // 출력값이 DAC 범위를 넘지 않도록 자릅니다.
            if (sum_res > MAX_VAL) begin
                data_o_tdata <= MAX_VAL[DATA_WIDTH-1:0];
            end else if (sum_res < MIN_VAL) begin
                data_o_tdata <= MIN_VAL[DATA_WIDTH-1:0];
            end else begin
                data_o_tdata <= sum_res[DATA_WIDTH-1:0];
            end
            
            data_o_tvalid <= data_i_tvalid;
        end
    end
endmodule