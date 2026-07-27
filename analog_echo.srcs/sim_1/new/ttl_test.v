`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 18.06.2026 18:19:43
// Design Name: 
// Module Name: ttl_test
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

module tb_offset_scale_ctrl;

    // -------------------------------------------------------------------------
    // Parameter
    // -------------------------------------------------------------------------
    parameter DATA_WIDTH      = 16;
    parameter SCALE_FRAC_BITS = 13;

    // -------------------------------------------------------------------------
    // DUT input
    // -------------------------------------------------------------------------
    reg clk;
    reg resetn;
    reg ttl_en;

    reg signed [DATA_WIDTH - 1 : 0] offset;
    reg signed [DATA_WIDTH - 1 : 0] scale;
    reg signed [DATA_WIDTH - 1 : 0] scale_i;
    reg signed [DATA_WIDTH - 1 : 0] threshold;

    reg signed [DATA_WIDTH - 1 : 0] data_i_tdata;
    reg data_i_tvalid;

    // -------------------------------------------------------------------------
    // DUT output
    // -------------------------------------------------------------------------
    wire signed [DATA_WIDTH - 1 : 0] data_o_tdata;
    wire data_o_tvalid;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    offset_scale_ctrl #(
        .DATA_WIDTH(DATA_WIDTH),
        .SCALE_FRAC_BITS(SCALE_FRAC_BITS)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .ttl_en(ttl_en),

        .offset(offset),
        .scale(scale),

        .scale_i(scale_i),
        .threshold(threshold),

        .data_i_tdata(data_i_tdata),
        .data_i_tvalid(data_i_tvalid),

        .data_o_tdata(data_o_tdata),
        .data_o_tvalid(data_o_tvalid)
    );

    // -------------------------------------------------------------------------
    // 125 MHz clock
    // Red Pitaya ADC clock 기준: 8 ns period
    // -------------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #4 clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Utility task:
    // output 값 검사
    // -------------------------------------------------------------------------
    task check_output;
        input signed [DATA_WIDTH - 1 : 0] expected_value;
        input [255:0] test_name;

        begin
            if (data_o_tdata !== expected_value) begin
                $display("======================================================");
                $display("FAIL : %s", test_name);
                $display("TIME : %0t ns", $time);
                $display("Expected output = %0d", expected_value);
                $display("Actual output   = %0d", data_o_tdata);
                $display("======================================================");
            end
            else begin
                $display("PASS : %s | output = %0d | time = %0t ns",
                         test_name, data_o_tdata, $time);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test
    // -------------------------------------------------------------------------
    initial begin

        // waveform 저장
        $dumpfile("tb_offset_scale_ctrl.vcd");
        $dumpvars(0, tb_offset_scale_ctrl);

        // ---------------------------------------------------------------------
        // Initial state
        // ---------------------------------------------------------------------
        resetn        = 1'b0;
        ttl_en        = 1'b0;

        offset        = 16'sd0;
        scale         = 16'sd0;
        scale_i       = 16'sd0;
        threshold     = 16'sd0;

        data_i_tdata  = 16'sd0;
        data_i_tvalid = 1'b0;

        // reset 유지
        #30;

        // ---------------------------------------------------------------------
        // Reset release
        // ---------------------------------------------------------------------
        @(negedge clk);
        resetn = 1'b1;

        // Kp = 1.0
        // 8192 / 2^13 = 1.0
        offset    = 16'sd1000;
        scale     = 16'sd8192;

        // Ki = 0.0
        // TTL hold만 보기 위해 I항 제거
        scale_i   = 16'sd0;

        // data_i_tdata > threshold 조건을 통과하게 설정
        // 단 Ki=0이므로 I accumulator 값은 변하지 않음
        threshold = -16'sd1;

        data_i_tdata  = 16'sd0;
        data_i_tvalid = 1'b1;

        // ---------------------------------------------------------------------
        // TEST 1:
        // TTL LOW 상태에서는 output이 0으로 hold되어야 함
        // ---------------------------------------------------------------------
        repeat (4) @(posedge clk);
        @(negedge clk);

        check_output(
            16'sd0,
            "TEST 1 : TTL LOW initial output hold"
        );

        // ---------------------------------------------------------------------
        // TEST 2:
        // TTL HIGH
        //
        // 2-stage synchronizer 때문에 실제 servo_en은
        // 약 2~3 clk 뒤 활성화됨.
        //
        // offset = 1000
        // input  = 0
        // Kp     = 1.0
        //
        // expected = 1000 - 0 = 1000
        // ---------------------------------------------------------------------
        @(negedge clk);
        ttl_en = 1'b1;

        repeat (4) @(posedge clk);
        @(negedge clk);

        check_output(
            16'sd1000,
            "TEST 2 : TTL HIGH servo enabled"
        );

        // ---------------------------------------------------------------------
        // TEST 3:
        // TTL HIGH 상태에서 input 변경
        //
        // offset = 1000
        // input  = 500
        // Kp     = 1.0
        //
        // expected = 1000 - 500 = 500
        // ---------------------------------------------------------------------
        @(negedge clk);
        data_i_tdata = 16'sd500;

        repeat (2) @(posedge clk);
        @(negedge clk);

        check_output(
            16'sd500,
            "TEST 3 : Servo updates while TTL HIGH"
        );

        // ---------------------------------------------------------------------
        // TEST 4:
        // TTL LOW로 전환
        //
        // 2-stage synchronizer 때문에 바로 hold되는 것이 아니라
        // 약 2~3 clk 뒤 servo_en이 LOW가 됨.
        //
        // 현재 output = 500을 hold시키는 상태
        // ---------------------------------------------------------------------
        @(negedge clk);
        ttl_en = 1'b0;

        repeat (4) @(posedge clk);
        @(negedge clk);

        check_output(
            16'sd500,
            "TEST 4 : TTL LOW after synchronizer delay"
        );

        // ---------------------------------------------------------------------
        // TEST 5:
        // TTL LOW 상태에서 input을 크게 바꿔도 output은 hold되어야 함
        //
        // offset = 1000
        // input  = -1000
        //
        // servo ON이었다면 output은 2000이 되어야 하지만,
        // TTL LOW이므로 이전 값 500이 유지되어야 함.
        // ---------------------------------------------------------------------
        @(negedge clk);
        data_i_tdata = -16'sd1000;

        repeat (5) @(posedge clk);
        @(negedge clk);

        check_output(
            16'sd500,
            "TEST 5 : TTL LOW holds output despite input change"
        );

        // ---------------------------------------------------------------------
        // TEST 6:
        // TTL HIGH 재인가
        //
        // offset = 1000
        // input  = -1000
        // Kp     = 1.0
        //
        // expected = 1000 - (-1000) = 2000
        // ---------------------------------------------------------------------
        @(negedge clk);
        ttl_en = 1'b1;

        repeat (4) @(posedge clk);
        @(negedge clk);

        check_output(
            16'sd2000,
            "TEST 6 : Servo resumes after TTL HIGH"
        );

        // ---------------------------------------------------------------------
        // TEST 7:
        // TTL HIGH지만 data_i_tvalid = 0이면 output hold
        // ---------------------------------------------------------------------
        @(negedge clk);
        data_i_tvalid = 1'b0;
        data_i_tdata  = 16'sd0;

        repeat (3) @(posedge clk);
        @(negedge clk);

        check_output(
            16'sd2000,
            "TEST 7 : data_i_tvalid LOW holds output"
        );

        // ---------------------------------------------------------------------
        // Finish
        // ---------------------------------------------------------------------
        $display("======================================================");
        $display("TTL ENABLE TESTBENCH FINISHED");
        $display("Check tb_offset_scale_ctrl.vcd in Vivado waveform.");
        $display("======================================================");

        #20;
        $finish;
    end

endmodule
