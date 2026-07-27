`timescale 1ns / 1ps

module tb_real_osc_match();

    parameter DATA_WIDTH = 16;
    parameter SCALE_FRAC_BITS = 13;

    reg clk;
    reg resetn;

    reg signed [DATA_WIDTH - 1 : 0] offset;
    reg signed [DATA_WIDTH - 1 : 0] scale;
    reg signed [DATA_WIDTH - 1 : 0] scale_i;
    reg signed [DATA_WIDTH - 1 : 0] threshold;

    reg signed [DATA_WIDTH - 1 : 0] data_i_tdata;
    reg data_i_tvalid;

    wire signed [DATA_WIDTH - 1 : 0] data_o_tdata;
    wire data_o_tvalid;

    // DUT 연결
    offset_scale_ctrl #(
        .DATA_WIDTH(DATA_WIDTH),
        .SCALE_FRAC_BITS(SCALE_FRAC_BITS)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .offset(offset),
        .scale(scale),
        .scale_i(scale_i),
        .threshold(threshold),
        .data_i_tdata(data_i_tdata),
        .data_i_tvalid(data_i_tvalid),
        .data_o_tdata(data_o_tdata),
        .data_o_tvalid(data_o_tvalid)
    );

    // 125MHz 클럭 (8ns)
    initial begin
        clk = 0;
        forever #4 clk = ~clk; 
    end

    // =========================================================
    // ★ 실제 오실로스코프 1:1 모사 시나리오 ★
    // =========================================================
    initial begin
        resetn = 0;
        data_i_tvalid = 0;
        data_i_tdata = 0;

        offset = 0;             // Setpoint = 0
        scale = 8192;           // Kp = 1.0 (P제어 1배율, 수직낙하용)
        scale_i = 100;          // Ki (적분기 기울기 조절용)
        threshold = -32768;     // 문턱값 무력화 (항상 연산 수행)

        #100 resetn = 1; data_i_tvalid = 1;

        // 실제 오실로스코프 주기가 1ms (OFF 500us, ON 500us)
        // 500us = 500,000 ns
        repeat(5) begin
            // [구간 1] 레이저 OFF (파란색 바닥 구간)
            // 오실로스코프 Vmin2(-4.3mV)처럼 미세한 음수 입력.
            // 에러가 미세 양수이므로, 적분기가 천천히 차오름 (완만한 우상향 사선)
            data_i_tdata = -50; 
            #500000;  // 500us (500,000ns) 동안 유지

            // [구간 2] 레이저 ON (파란색 펄스 하이 구간)
            // 오실로스코프 Vmax2(101.7mV)처럼 확실한 양수 펄스 입력.
            // 에러가 큰 음수이므로, P 수직 낙하 후 적분기가 급격히 물을 버림.
            // 시간이 500us나 되므로, 물통이 다 비워지고 0에서 '평행선'을 긋게 됨.
            data_i_tdata = 1000;
            #500000;  // 500us (500,000ns) 동안 유지
        end

        $finish;
    end

endmodule