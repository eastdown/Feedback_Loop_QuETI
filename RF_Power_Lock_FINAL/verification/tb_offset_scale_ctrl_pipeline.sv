`timescale 1ns / 1ps

module tb_offset_scale_ctrl_pipeline;
    localparam integer DATA_WIDTH = 16;
    localparam integer P_SCALE_FRAC_BITS = 10;
    localparam integer I_SCALE_FRAC_BITS = 13;

    reg clk = 1'b0;
    reg resetn = 1'b0;
    reg ttl_en = 1'b0;
    reg signed [DATA_WIDTH - 1 : 0] offset = 0;
    reg signed [DATA_WIDTH - 1 : 0] scale = 0;
    reg signed [DATA_WIDTH - 1 : 0] scale_i = 0;
    reg signed [DATA_WIDTH - 1 : 0] threshold = 0;
    reg signed [DATA_WIDTH - 1 : 0] data_i_tdata = 0;
    reg data_i_tvalid = 1'b0;

    wire signed [DATA_WIDTH - 1 : 0] data_o_tdata;
    wire data_o_tvalid;
    wire signed [DATA_WIDTH - 1 : 0] no_ttl_data_o_tdata;
    wire no_ttl_data_o_tvalid;

    integer cycle_count = 0;
    integer test_count = 0;
    integer error_count = 0;

    offset_scale_ctrl #(
        .DATA_WIDTH(DATA_WIDTH),
        .P_SCALE_FRAC_BITS(P_SCALE_FRAC_BITS),
        .SCALE_FRAC_BITS(I_SCALE_FRAC_BITS),
        .USE_TTL_ENABLE(1)
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

    // The deployed build uses this mode: ttl_en may remain LOW or unconnected
    // and the PI controller still processes samples continuously.
    offset_scale_ctrl #(
        .DATA_WIDTH(DATA_WIDTH),
        .P_SCALE_FRAC_BITS(P_SCALE_FRAC_BITS),
        .SCALE_FRAC_BITS(I_SCALE_FRAC_BITS),
        .USE_TTL_ENABLE(0)
    ) dut_no_ttl (
        .clk(clk),
        .resetn(resetn),
        .ttl_en(ttl_en),
        .offset(offset),
        .scale(scale),
        .scale_i(scale_i),
        .threshold(threshold),
        .data_i_tdata(data_i_tdata),
        .data_i_tvalid(data_i_tvalid),
        .data_o_tdata(no_ttl_data_o_tdata),
        .data_o_tvalid(no_ttl_data_o_tvalid)
    );

    always #4 clk = ~clk; // 125 MHz

    always @(posedge clk)
        cycle_count <= cycle_count + 1;

    task automatic apply_reset;
        begin
            @(negedge clk);
            resetn = 1'b0;
            ttl_en = 1'b0;
            data_i_tvalid = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            resetn = 1'b1;
        end
    endtask

    task automatic send_and_expect_no_ttl;
        input signed [DATA_WIDTH - 1 : 0] sample;
        input signed [DATA_WIDTH - 1 : 0] expected;
        input integer expected_latency;
        input [8*64 - 1 : 0] name;
        integer accept_cycle;
        integer output_cycle;
        begin
            @(negedge clk);
            data_i_tdata = sample;
            data_i_tvalid = 1'b1;
            accept_cycle = cycle_count + 1;

            @(negedge clk);
            data_i_tvalid = 1'b0;

            wait (no_ttl_data_o_tvalid === 1'b1);
            #1;
            output_cycle = cycle_count;
            test_count = test_count + 1;

            if (no_ttl_data_o_tdata !== expected) begin
                $display("FAIL %-64s expected=%0d actual=%0d",
                         name, expected, no_ttl_data_o_tdata);
                error_count = error_count + 1;
            end else if ((output_cycle - accept_cycle) != expected_latency) begin
                $display("FAIL %-64s expected_latency=%0d actual_latency=%0d",
                         name, expected_latency, output_cycle - accept_cycle);
                error_count = error_count + 1;
            end else begin
                $display("PASS %-64s output=%0d latency=%0d",
                         name, no_ttl_data_o_tdata,
                         output_cycle - accept_cycle);
            end

            @(negedge clk);
        end
    endtask

    task automatic enable_servo;
        begin
            @(negedge clk);
            ttl_en = 1'b1;
            // Two synchronizer registers plus one guard edge before sampling.
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic disable_servo;
        begin
            @(negedge clk);
            ttl_en = 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic send_and_expect;
        input signed [DATA_WIDTH - 1 : 0] sample;
        input signed [DATA_WIDTH - 1 : 0] expected;
        input integer expected_latency;
        input [8*64 - 1 : 0] name;
        integer accept_cycle;
        integer output_cycle;
        begin
            @(negedge clk);
            data_i_tdata = sample;
            data_i_tvalid = 1'b1;
            accept_cycle = cycle_count + 1;

            @(negedge clk);
            data_i_tvalid = 1'b0;

            wait (data_o_tvalid === 1'b1);
            #1;
            output_cycle = cycle_count;
            test_count = test_count + 1;

            if (data_o_tdata !== expected) begin
                $display("FAIL %-64s expected=%0d actual=%0d",
                         name, expected, data_o_tdata);
                error_count = error_count + 1;
            end else if ((output_cycle - accept_cycle) != expected_latency) begin
                $display("FAIL %-64s expected_latency=%0d actual_latency=%0d",
                         name, expected_latency, output_cycle - accept_cycle);
                error_count = error_count + 1;
            end else begin
                $display("PASS %-64s output=%0d latency=%0d",
                         name, data_o_tdata, output_cycle - accept_cycle);
            end

            @(negedge clk);
        end
    endtask

    initial begin
        // In standalone mode, ttl_en stays LOW but samples must still be
        // processed.  This is the mode compiled into the temporary build.
        apply_reset();
        offset = 16'sd1000;
        scale = 16'sd1024;
        scale_i = 16'sd0;
        threshold = -16'sd1;
        send_and_expect_no_ttl(16'sd250, 16'sd750, 4,
                               "TTL bypass processes sample while ttl_en LOW");

        apply_reset();
        enable_servo();

        // P-only arithmetic and both output saturation limits.
        offset = 16'sd1000;
        scale = 16'sd1024;
        scale_i = 16'sd0;
        threshold = -16'sd1;
        send_and_expect(16'sd250, 16'sd750, 4,
                        "P gain 1.0: 1000 - 250");

        offset = -16'sd1000;
        send_and_expect(16'sd500, -16'sd1500, 4,
                        "signed negative P result");

        offset = 16'sd32767;
        send_and_expect(-16'sd32768, 16'sd32767, 4,
                        "positive P saturation");

        offset = -16'sd32768;
        send_and_expect(16'sd32767, -16'sd32768, 4,
                        "negative P saturation");

        offset = 16'sd1000;
        scale = 16'sd512;
        send_and_expect(16'sd0, 16'sd500, 4,
                        "Q6.10 Kp 0.5");

        // Values outside the former Q3.13 range must now be representable.
        offset = 16'sd100;
        scale = 16'sd16384;
        send_and_expect(16'sd0, 16'sd1600, 4,
                        "expanded Q6.10 Kp +16");
        scale = -16'sd16384;
        send_and_expect(16'sd0, -16'sd1600, 4,
                        "expanded Q6.10 Kp -16");

        // Integral term uses the accumulator value from before each update,
        // matching the original nonblocking-assignment behavior.
        apply_reset();
        enable_servo();
        offset = 16'sd100;
        scale = 16'sd0;
        scale_i = 16'sd8192;
        threshold = -16'sd1;
        send_and_expect(16'sd0, 16'sd0, 4,
                        "I sample 1 uses prior accumulator");
        send_and_expect(16'sd0, 16'sd100, 4,
                        "I sample 2 sees first accumulation");
        send_and_expect(16'sd0, 16'sd200, 4,
                        "I sample 3 sees second accumulation");

        // When the threshold condition is false, the accumulator must hold.
        threshold = 16'sd10;
        send_and_expect(16'sd0, 16'sd300, 4,
                        "threshold false exposes but does not change I state");
        send_and_expect(16'sd0, 16'sd300, 4,
                        "threshold auto-hold remains stable");

        // Exercise the corrected full-width anti-windup calculations.
        apply_reset();
        enable_servo();
        offset = 16'sd32767;
        scale = 16'sd0;
        scale_i = 16'sd32767;
        threshold = -16'sd32768;
        send_and_expect(-16'sd32767, 16'sd0, 4,
                        "positive I clamp update");
        send_and_expect(-16'sd32767, 16'sd32767, 4,
                        "positive I clamp result");

        apply_reset();
        enable_servo();
        offset = -16'sd32768;
        scale = 16'sd0;
        scale_i = 16'sd32767;
        threshold = 16'sd0;
        send_and_expect(16'sd32767, 16'sd0, 4,
                        "negative I clamp update");
        send_and_expect(16'sd32767, -16'sd32768, 4,
                        "negative I clamp result");

        // TTL LOW must clear both the physical output command and the integral
        // state, rather than retaining values from the preceding acquisition.
        disable_servo();
        #1;
        test_count = test_count + 1;
        if ((data_o_tdata !== 16'sd0) ||
            (dut.i_accumulator !== 32'sd0)) begin
            $display("FAIL %-64s output=%0d accumulator=%0d",
                     "servo disable clears output and accumulator",
                     data_o_tdata, dut.i_accumulator);
            error_count = error_count + 1;
        end else begin
            $display("PASS %-64s output=%0d accumulator=%0d",
                     "servo disable clears output and accumulator",
                     data_o_tdata, dut.i_accumulator);
        end

        offset = 16'sd1234;
        scale = 16'sd1024;
        scale_i = 16'sd0;
        send_and_expect(16'sd0, 16'sd0, 4,
                        "servo disabled output remains zero");

        // Re-enabling after the reset must restart the integral term from zero.
        enable_servo();
        offset = 16'sd100;
        scale = 16'sd0;
        scale_i = 16'sd8192;
        threshold = -16'sd1;
        send_and_expect(16'sd0, 16'sd0, 4,
                        "re-enabled I sample 1 starts from zero");
        send_and_expect(16'sd0, 16'sd100, 4,
                        "re-enabled I sample 2 sees fresh accumulation");

        if (error_count == 0) begin
            $display("PIPELINE_TEST_PASS tests=%0d", test_count);
            $finish;
        end else begin
            $fatal(1, "PIPELINE_TEST_FAIL errors=%0d tests=%0d",
                   error_count, test_count);
        end
    end

    initial begin
        #20000;
        $fatal(1, "PIPELINE_TEST_TIMEOUT");
    end
endmodule
