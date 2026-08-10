`timescale 1ns / 1ps

// Pipelined proportional-integral controller for the 125 MHz Red Pitaya path.
//
// The original controller placed error subtraction, two multiplications,
// scaling, saturation, addition, and final saturation in one clock path.  This
// version separates that work with registers:
//
//   S1  capture controls, calculate error, compare threshold
//   S2  calculate the P and I products
//   S3  register both products
//   S4  scale/saturate P, update the I accumulator, capture the prior I term
//   S5  add P+I, saturate, and register the output
//
// A sample accepted at rising edge N appears at the output at rising edge N+4.
// In other words, there are five registered processing stages and four full
// clock periods between the input-capture edge and the output edge.
module offset_scale_ctrl #(
    parameter integer DATA_WIDTH      = 16,
    // Kp uses signed Q6.10: -32.0 to +31.9990234375.
    parameter integer P_SCALE_FRAC_BITS = 10,
    // Ki remains signed Q3.13 to preserve fine integral-gain resolution.
    // Keep the legacy parameter name so existing Vivado module-reference
    // wrappers continue to regenerate without a block-design migration.
    parameter integer SCALE_FRAC_BITS = 13,
    // Temporary standalone mode: 0 keeps the servo enabled without an
    // external TTL cable.  Set this back to 1 to restore TTL gating.
    parameter integer USE_TTL_ENABLE  = 0
)(
    input  wire clk,
    input  wire resetn,
    input  wire ttl_en,

    input  wire signed [DATA_WIDTH - 1 : 0] offset,
    input  wire signed [DATA_WIDTH - 1 : 0] scale,
    input  wire signed [DATA_WIDTH - 1 : 0] scale_i,
    input  wire signed [DATA_WIDTH - 1 : 0] threshold,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_i TDATA" *)
    input  wire signed [DATA_WIDTH - 1 : 0] data_i_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_i TVALID" *)
    input  wire data_i_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_o TDATA" *)
    output reg signed [DATA_WIDTH - 1 : 0] data_o_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 data_o TVALID" *)
    output reg data_o_tvalid
);

    localparam integer ERROR_WIDTH    = DATA_WIDTH + 1;
    localparam integer MULT_WIDTH     = ERROR_WIDTH + DATA_WIDTH;
    localparam integer ACCUM_WIDTH    = 32;
    localparam integer ACC_SUM_WIDTH  =
        (MULT_WIDTH > ACCUM_WIDTH ? MULT_WIDTH : ACCUM_WIDTH) + 1;
    localparam integer OUTPUT_LATENCY = 4;

    localparam signed [DATA_WIDTH - 1 : 0] MAX_VAL =
        {1'b0, {(DATA_WIDTH - 1){1'b1}}};
    localparam signed [DATA_WIDTH - 1 : 0] MIN_VAL =
        {1'b1, {(DATA_WIDTH - 1){1'b0}}};

    // ttl_en originates outside this clock domain.  The ASYNC_REG attribute
    // tells Vivado to keep the two synchronizer flip-flops close together.
    (* ASYNC_REG = "TRUE" *) reg ttl_meta;
    (* ASYNC_REG = "TRUE" *) reg ttl_sync;

    always @(posedge clk) begin
        if (!resetn) begin
            ttl_meta <= 1'b0;
            ttl_sync <= 1'b0;
        end else begin
            ttl_meta <= ttl_en;
            ttl_sync <= ttl_meta;
        end
    end

    wire servo_en = USE_TTL_ENABLE ? ttl_sync : 1'b1;

    // Track input-valid and the enable state belonging to each sample.  These
    // bits use the same four-edge delay as the sample data.  Clear all pending
    // enabled samples while the servo is disabled so a later rising edge
    // cannot release a result left in the pipeline by the previous run.
    reg [OUTPUT_LATENCY - 1 : 0] valid_pipe;
    reg [OUTPUT_LATENCY - 1 : 0] enable_pipe;

    always @(posedge clk) begin
        if (!resetn) begin
            valid_pipe  <= {OUTPUT_LATENCY{1'b0}};
            enable_pipe <= {OUTPUT_LATENCY{1'b0}};
        end else begin
            valid_pipe  <= {valid_pipe[OUTPUT_LATENCY - 2 : 0], data_i_tvalid};
            if (!servo_en)
                enable_pipe <= {OUTPUT_LATENCY{1'b0}};
            else
                enable_pipe <= {enable_pipe[OUTPUT_LATENCY - 2 : 0],
                                data_i_tvalid};
        end
    end

    // S1: capture one complete input sample and its control values.
    wire signed [ERROR_WIDTH - 1 : 0] offset_extended =
        {offset[DATA_WIDTH - 1], offset};
    wire signed [ERROR_WIDTH - 1 : 0] input_extended =
        {data_i_tdata[DATA_WIDTH - 1], data_i_tdata};

    reg signed [ERROR_WIDTH - 1 : 0] error_r;
    reg signed [DATA_WIDTH - 1 : 0] scale_r;
    reg signed [DATA_WIDTH - 1 : 0] scale_i_r;
    reg over_threshold_r;

    always @(posedge clk) begin
        if (!resetn) begin
            error_r          <= {ERROR_WIDTH{1'b0}};
            scale_r          <= {DATA_WIDTH{1'b0}};
            scale_i_r        <= {DATA_WIDTH{1'b0}};
            over_threshold_r <= 1'b0;
        end else begin
            error_r          <= offset_extended - input_extended;
            scale_r          <= scale;
            scale_i_r        <= scale_i;
            over_threshold_r <= ($signed(data_i_tdata) > $signed(threshold));
        end
    end

    // S2 and S3: register the multiplier inputs and outputs so Vivado can map
    // the arithmetic to pipelined DSP48 resources.
    (* use_dsp = "yes" *) reg signed [MULT_WIDTH - 1 : 0] p_product_s2;
    (* use_dsp = "yes" *) reg signed [MULT_WIDTH - 1 : 0] i_product_s2;
    reg signed [MULT_WIDTH - 1 : 0] p_product_s3;
    reg signed [MULT_WIDTH - 1 : 0] i_product_s3;
    reg over_threshold_s2;
    reg over_threshold_s3;

    always @(posedge clk) begin
        if (!resetn) begin
            p_product_s2     <= {MULT_WIDTH{1'b0}};
            i_product_s2     <= {MULT_WIDTH{1'b0}};
            p_product_s3     <= {MULT_WIDTH{1'b0}};
            i_product_s3     <= {MULT_WIDTH{1'b0}};
            over_threshold_s2 <= 1'b0;
            over_threshold_s3 <= 1'b0;
        end else begin
            p_product_s2      <= error_r * scale_r;
            i_product_s2      <= error_r * scale_i_r;
            p_product_s3      <= p_product_s2;
            i_product_s3      <= i_product_s2;
            over_threshold_s2 <= over_threshold_r;
            over_threshold_s3 <= over_threshold_s2;
        end
    end

    // S4: proportional scaling/saturation and integral accumulation.
    wire signed [MULT_WIDTH - 1 : 0] p_shifted =
        p_product_s3 >>> P_SCALE_FRAC_BITS;
    wire signed [MULT_WIDTH - 1 : 0] max_mult_width =
        {{(MULT_WIDTH - DATA_WIDTH){MAX_VAL[DATA_WIDTH - 1]}}, MAX_VAL};
    wire signed [MULT_WIDTH - 1 : 0] min_mult_width =
        {{(MULT_WIDTH - DATA_WIDTH){MIN_VAL[DATA_WIDTH - 1]}}, MIN_VAL};

    reg signed [DATA_WIDTH - 1 : 0] p_saturated_s4;
    reg signed [ACCUM_WIDTH - 1 : 0] i_accumulator;
    reg signed [DATA_WIDTH - 1 : 0] i_term_s4;

    // Extend before shifting.  Shifting MAX_VAL/MIN_VAL while they are still
    // DATA_WIDTH bits wide would discard their upper bits in Verilog.
    wire signed [ACCUM_WIDTH - 1 : 0] max_accum_base =
        {{(ACCUM_WIDTH - DATA_WIDTH){MAX_VAL[DATA_WIDTH - 1]}}, MAX_VAL};
    wire signed [ACCUM_WIDTH - 1 : 0] min_accum_base =
        {{(ACCUM_WIDTH - DATA_WIDTH){MIN_VAL[DATA_WIDTH - 1]}}, MIN_VAL};
    wire signed [ACCUM_WIDTH - 1 : 0] I_ACCUM_MAX =
        max_accum_base <<< SCALE_FRAC_BITS;
    wire signed [ACCUM_WIDTH - 1 : 0] I_ACCUM_MIN =
        min_accum_base <<< SCALE_FRAC_BITS;

    // Extend both addends before adding.  This preserves the carry/sign bit
    // needed to make the anti-windup comparisons reliable.
    wire signed [ACC_SUM_WIDTH - 1 : 0] accumulator_extended =
        {{(ACC_SUM_WIDTH - ACCUM_WIDTH){i_accumulator[ACCUM_WIDTH - 1]}},
         i_accumulator};
    wire signed [ACC_SUM_WIDTH - 1 : 0] i_product_extended =
        {{(ACC_SUM_WIDTH - MULT_WIDTH){i_product_s3[MULT_WIDTH - 1]}},
         i_product_s3};
    wire signed [ACC_SUM_WIDTH - 1 : 0] accum_max_extended =
        {{(ACC_SUM_WIDTH - ACCUM_WIDTH){I_ACCUM_MAX[ACCUM_WIDTH - 1]}},
         I_ACCUM_MAX};
    wire signed [ACC_SUM_WIDTH - 1 : 0] accum_min_extended =
        {{(ACC_SUM_WIDTH - ACCUM_WIDTH){I_ACCUM_MIN[ACCUM_WIDTH - 1]}},
         I_ACCUM_MIN};
    wire signed [ACC_SUM_WIDTH - 1 : 0] accumulator_next =
        accumulator_extended + i_product_extended;
    wire signed [ACCUM_WIDTH - 1 : 0] i_term_shifted =
        i_accumulator >>> SCALE_FRAC_BITS;

    always @(posedge clk) begin
        if (!resetn) begin
            p_saturated_s4 <= {DATA_WIDTH{1'b0}};
            i_accumulator  <= {ACCUM_WIDTH{1'b0}};
            i_term_s4      <= {DATA_WIDTH{1'b0}};
        end else if (!servo_en) begin
            // TTL LOW starts every acquisition from a known state.  Clear the
            // persistent integral memory as well as the registered P/I terms.
            p_saturated_s4 <= {DATA_WIDTH{1'b0}};
            i_accumulator  <= {ACCUM_WIDTH{1'b0}};
            i_term_s4      <= {DATA_WIDTH{1'b0}};
        end else begin
            if (p_shifted > max_mult_width)
                p_saturated_s4 <= MAX_VAL;
            else if (p_shifted < min_mult_width)
                p_saturated_s4 <= MIN_VAL;
            else
                p_saturated_s4 <= p_shifted[DATA_WIDTH - 1 : 0];

            // Preserve the original controller behavior: the current output
            // uses the accumulator value from before this sample is integrated.
            i_term_s4 <= i_term_shifted[DATA_WIDTH - 1 : 0];

            // enable_pipe[2] is aligned with the S3 product at this edge.
            if (enable_pipe[2] && over_threshold_s3) begin
                if (accumulator_next > accum_max_extended)
                    i_accumulator <= I_ACCUM_MAX;
                else if (accumulator_next < accum_min_extended)
                    i_accumulator <= I_ACCUM_MIN;
                else
                    i_accumulator <= accumulator_next[ACCUM_WIDTH - 1 : 0];
            end
        end
    end

    // S5: add the P and I terms using explicit sign extension, then saturate.
    wire signed [DATA_WIDTH : 0] p_sum_extended =
        {p_saturated_s4[DATA_WIDTH - 1], p_saturated_s4};
    wire signed [DATA_WIDTH : 0] i_sum_extended =
        {i_term_s4[DATA_WIDTH - 1], i_term_s4};
    wire signed [DATA_WIDTH : 0] sum_result =
        p_sum_extended + i_sum_extended;
    wire signed [DATA_WIDTH : 0] max_sum_value =
        {MAX_VAL[DATA_WIDTH - 1], MAX_VAL};
    wire signed [DATA_WIDTH : 0] min_sum_value =
        {MIN_VAL[DATA_WIDTH - 1], MIN_VAL};

    always @(posedge clk) begin
        if (!resetn) begin
            data_o_tdata  <= {DATA_WIDTH{1'b0}};
            data_o_tvalid <= 1'b0;
        end else begin
            data_o_tvalid <= valid_pipe[OUTPUT_LATENCY - 1];

            // TTL LOW commands zero output instead of retaining the value from
            // the preceding acquisition.  The downstream DAC calibration block
            // then converts this requested zero to the board's calibrated 0 V.
            if (!servo_en) begin
                data_o_tdata <= {DATA_WIDTH{1'b0}};
            end else if (enable_pipe[OUTPUT_LATENCY - 1]) begin
                if (sum_result > max_sum_value)
                    data_o_tdata <= MAX_VAL;
                else if (sum_result < min_sum_value)
                    data_o_tdata <= MIN_VAL;
                else
                    data_o_tdata <= sum_result[DATA_WIDTH - 1 : 0];
            end
        end
    end

endmodule
