`timescale 1ns / 1ps

// Per-channel ADC calibration stage for the Red Pitaya fast analog inputs.
//
// The Linux startup service reads the LV (1:1) ADC gain and offset from the
// board EEPROM and writes them through AXI GPIO.  The official Red Pitaya
// conversion is:
//
//     corrected = (raw - offset) * gain / base
//
// The ADC IP has already expanded the signed 14-bit sample to a signed 16-bit
// stream by appending two zero LSBs.  cal_offset therefore uses the EEPROM
// 14-bit offset shifted left by two.  cal_gain is signed Q3.13.
module adc_calibrator #(
    parameter integer DATA_WIDTH     = 16,
    parameter integer GAIN_FRAC_BITS = 13
)(
    input  wire clk,
    input  wire resetn,

    input  wire signed [DATA_WIDTH - 1 : 0] cal_gain,
    input  wire signed [DATA_WIDTH - 1 : 0] cal_offset,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_i TDATA" *)
    input  wire signed [DATA_WIDTH - 1 : 0] data_i_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_i TVALID" *)
    input  wire data_i_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_o TDATA" *)
    output reg signed [DATA_WIDTH - 1 : 0] data_o_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_o TVALID" *)
    output reg data_o_tvalid
);

    localparam integer CENTER_WIDTH  = DATA_WIDTH + 1;
    localparam integer PRODUCT_WIDTH = CENTER_WIDTH + DATA_WIDTH;

    localparam signed [DATA_WIDTH - 1 : 0] MAX_CODE =
        {1'b0, {(DATA_WIDTH - 1){1'b1}}};
    localparam signed [DATA_WIDTH - 1 : 0] MIN_CODE =
        {1'b1, {(DATA_WIDTH - 1){1'b0}}};

    // Stage 1: subtract the EEPROM offset with one guard bit so the
    // intermediate result cannot overflow at either ADC rail.
    reg signed [CENTER_WIDTH - 1 : 0] centered_reg;
    reg valid_s1;

    wire signed [CENTER_WIDTH - 1 : 0] input_extended =
        {data_i_tdata[DATA_WIDTH - 1], data_i_tdata};
    wire signed [CENTER_WIDTH - 1 : 0] offset_extended =
        {cal_offset[DATA_WIDTH - 1], cal_offset};

    // Stage 2: apply the board-specific gain in a DSP-friendly register.
    (* use_dsp = "yes" *) reg signed [PRODUCT_WIDTH - 1 : 0] gain_product_reg;
    reg valid_s2;

    wire signed [PRODUCT_WIDTH - 1 : 0] scaled_value =
        gain_product_reg >>> GAIN_FRAC_BITS;
    wire signed [PRODUCT_WIDTH - 1 : 0] max_extended =
        {{(PRODUCT_WIDTH - DATA_WIDTH){MAX_CODE[DATA_WIDTH - 1]}}, MAX_CODE};
    wire signed [PRODUCT_WIDTH - 1 : 0] min_extended =
        {{(PRODUCT_WIDTH - DATA_WIDTH){MIN_CODE[DATA_WIDTH - 1]}}, MIN_CODE};

    // Stage 3: return to the common signed 16-bit stream and saturate if the
    // calibrated value extends beyond the representable LV input range.
    always @(posedge clk) begin
        if (!resetn) begin
            centered_reg     <= {CENTER_WIDTH{1'b0}};
            gain_product_reg <= {PRODUCT_WIDTH{1'b0}};
            valid_s1         <= 1'b0;
            valid_s2         <= 1'b0;
            data_o_tdata     <= {DATA_WIDTH{1'b0}};
            data_o_tvalid    <= 1'b0;
        end else begin
            centered_reg     <= input_extended - offset_extended;
            valid_s1         <= data_i_tvalid;

            gain_product_reg <= centered_reg * $signed(cal_gain);
            valid_s2         <= valid_s1;

            data_o_tvalid <= valid_s2;
            if (valid_s2) begin
                if (scaled_value > max_extended)
                    data_o_tdata <= MAX_CODE;
                else if (scaled_value < min_extended)
                    data_o_tdata <= MIN_CODE;
                else
                    data_o_tdata <= scaled_value[DATA_WIDTH - 1 : 0];
            end
        end
    end

endmodule
