`timescale 1ns / 1ps

module tb_adc_calibrator;
    localparam integer DATA_WIDTH = 16;

    reg clk = 1'b0;
    reg resetn = 1'b0;
    reg signed [15:0] cal_gain = 16'sd8192;
    reg signed [15:0] cal_offset = 16'sd0;
    reg signed [15:0] data_i_tdata = 16'sd0;
    reg data_i_tvalid = 1'b0;
    wire signed [15:0] data_o_tdata;
    wire data_o_tvalid;

    integer checks = 0;
    integer failures = 0;

    always #4 clk = ~clk;

    adc_calibrator dut (
        .clk(clk),
        .resetn(resetn),
        .cal_gain(cal_gain),
        .cal_offset(cal_offset),
        .data_i_tdata(data_i_tdata),
        .data_i_tvalid(data_i_tvalid),
        .data_o_tdata(data_o_tdata),
        .data_o_tvalid(data_o_tvalid)
    );

    task automatic check_sample(
        input signed [15:0] sample,
        input signed [15:0] expected,
        input [255:0] label_text
    );
        begin
            @(negedge clk);
            data_i_tdata = sample;
            data_i_tvalid = 1'b1;
            @(negedge clk);
            data_i_tvalid = 1'b0;
            wait (data_o_tvalid === 1'b1);
            #1;
            checks = checks + 1;
            if ($signed(data_o_tdata) !== expected) begin
                failures = failures + 1;
                $display("FAIL %0s: sample=%0d expected=%0d got=%0d",
                         label_text, sample, expected, $signed(data_o_tdata));
            end else begin
                $display("PASS %0s: %0d", label_text, expected);
            end
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        resetn = 1'b1;

        check_sample(16'sd12344, 16'sd12344, "unity");
        check_sample(-16'sd12344, -16'sd12344, "unity negative");

        // Actual board IN1-LV values: gain Q13=8656 and offset=-71 ADC
        // counts, represented as -284 in the 16-bit left-shifted stream.
        cal_gain = 16'sd8656;
        cal_offset = -16'sd284;
        check_sample(-16'sd284, 16'sd0, "offset removal");
        check_sample(16'sd0, 16'sd300, "zero with board calibration");
        check_sample(16'sd15072, 16'sd16225, "positive gain correction");
        check_sample(-16'sd15072, -16'sd15626, "negative gain correction");
        check_sample(16'sd32764, 16'sd32767, "positive saturation");

        cal_offset = 16'sd284;
        check_sample(-16'sd32768, -16'sd32768, "negative saturation");

        if (failures == 0)
            $display("ADC_CALIBRATOR_RESULT: PASS (%0d/%0d)", checks, checks);
        else
            $display("ADC_CALIBRATOR_RESULT: FAIL (%0d failures of %0d)",
                     failures, checks);
        $finish;
    end
endmodule
