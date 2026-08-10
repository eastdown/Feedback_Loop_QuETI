`timescale 1ns / 1ps

// Per-channel DAC calibration stage.
//
// The Linux startup program reads the factory/user DAC calibration values from
// the Red Pitaya EEPROM and writes them to cal_gain and cal_offset through AXI
// GPIO registers.  cal_gain is signed Q3.13 by default.  cal_offset uses the
// same signed 16-bit word format as the internal DAC stream.
//
// This block is deliberately independent of the controller/PID block so the
// calibration remains in the final high-rate FPGA data path.
module dac_calibrator #(
    parameter DATA_WIDTH = 16,
    parameter GAIN_FRAC_BITS = 13
)(
    input  wire clk,
    input  wire resetn,
    
    //GAIN & OFFSET
    input  wire signed [DATA_WIDTH - 1 : 0] cal_gain,
    input  wire signed [DATA_WIDTH - 1 : 0] cal_offset,

    //보정 전 데이터 입력
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_i TDATA" *)
    input  wire signed [DATA_WIDTH - 1 : 0] data_i_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_i TVALID" *)
    input  wire data_i_tvalid,

    //보정 후 데이터 출력
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_o TDATA" *)
    output reg  signed [DATA_WIDTH - 1 : 0] data_o_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_o TVALID" *)
    output reg  data_o_tvalid
);
    localparam PRODUCT_WIDTH = DATA_WIDTH * 2;
    localparam signed [PRODUCT_WIDTH : 0] MAX_CODE =
        (1 <<< (DATA_WIDTH - 1)) - 1;
    localparam signed [PRODUCT_WIDTH : 0] MIN_CODE =
        -(1 <<< (DATA_WIDTH - 1));
    
    // 보정 전 입력값 * gain
    reg signed [PRODUCT_WIDTH - 1 : 0] gain_product_reg;
    //offset
    reg signed [DATA_WIDTH - 1 : 0] offset_reg;
    //곱셈 결과 유효한지
    reg product_valid_reg;
    
    //곱셈 결과를 13자리 옆으로 옮김. 즉, 2^13으로 나눔.
    wire signed [PRODUCT_WIDTH - 1 : 0] scaled_value =
        gain_product_reg >>> GAIN_FRAC_BITS;
    
    //gain 계산 결과 32비트에서 33비트로 연장 후 부호 추가
    wire signed [PRODUCT_WIDTH : 0] scaled_extended =
        {scaled_value[PRODUCT_WIDTH - 1], scaled_value};
    
    //offset의 부호 확장 (33비트로 확장)
    wire signed [PRODUCT_WIDTH : 0] offset_extended =
        {{(DATA_WIDTH + 1){offset_reg[DATA_WIDTH - 1]}}, offset_reg};
    
    //offset + 곱셈 결과
    wire signed [PRODUCT_WIDTH : 0] calibrated_value =
        scaled_extended + offset_extended;

    always @(posedge clk) begin
        if (!resetn) begin
            gain_product_reg <= {PRODUCT_WIDTH{1'b0}};
            offset_reg       <= {DATA_WIDTH{1'b0}};
            product_valid_reg <= 1'b0;
            data_o_tdata     <= {DATA_WIDTH{1'b0}};
            data_o_tvalid    <= 1'b0;
        end else begin
            // Pipeline stage 1: signed gain multiplication.
            gain_product_reg <= $signed(data_i_tdata) * $signed(cal_gain);
            offset_reg       <= cal_offset;
            product_valid_reg <= data_i_tvalid;

            // Pipeline stage 2: offset addition and signed saturation.
            data_o_tvalid <= product_valid_reg;
            if (product_valid_reg) begin
                if (calibrated_value > MAX_CODE) begin
                    data_o_tdata <= MAX_CODE[DATA_WIDTH - 1 : 0];
                end else if (calibrated_value < MIN_CODE) begin
                    data_o_tdata <= MIN_CODE[DATA_WIDTH - 1 : 0];
                end else begin
                    data_o_tdata <= calibrated_value[DATA_WIDTH - 1 : 0];
                end
            end
        end
    end

endmodule
