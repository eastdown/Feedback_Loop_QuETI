`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08.05.2026 15:45:16
// Design Name: 
// Module Name: tb_wf
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

module tb_pure_integrator_check();

    parameter DATA_WIDTH = 16;
    parameter SCALE_FRAC_BITS = 13;

    reg clk;
    reg resetn;

    // PID 컨트롤러 설정 레지스터
    reg signed [DATA_WIDTH - 1 : 0] offset;    // Setpoint
    reg signed [DATA_WIDTH - 1 : 0] scale;     // Kp
    reg signed [DATA_WIDTH - 1 : 0] scale_i;   // Ki
    reg signed [DATA_WIDTH - 1 : 0] threshold; // Auto-hold 문턱값

    // ADC 입력 (가상 함수발생기 사각파) 및 DAC 출력
    reg signed [DATA_WIDTH - 1 : 0] data_i_tdata; 
    reg data_i_tvalid;
    wire signed [DATA_WIDTH - 1 : 0] data_o_tdata;
    wire data_o_tvalid;

    // DUT (내가 만든 제어기) 연결
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

    // 125MHz 클럭 생성 (8ns 주기)
    initial begin
        clk = 0;
        forever #4 clk = ~clk; 
    end

    // =========================================================
    initial begin
        // 1. 초기화 및 세팅
        resetn = 0;
        data_i_tvalid = 0;
        data_i_tdata = 0;

        offset = 0;             // Setpoint = 0
        scale = 16384;           // Kp = 1.0 (비례제어 1배)
        scale_i = 0;           // Ki = 적분기가 서서히 쌓이는 걸 보기 위해 작은 값 부여
        
        // ★ Threshold 무력화 (TTL 제어 대비) ★
        // 16비트 signed 정수의 최소값을 넣어 "입력 > 문턱값"이 무조건 참이 되도록 만듦
        threshold = -32768;     

        #100 resetn = 1; data_i_tvalid = 1;

        // 2. 가상의 함수발생기(FG) 사각파 쏘기
        // 오실로스코프에서 봤던 파란색 파형을 흉내냅니다.

        // 주파수를 확 높임! (예: 1주기를 10us로 단축 = 100kHz 펄스)
        repeat(25) begin
            // [구간 1] 레이저 OFF 
            data_i_tdata = 0; 
            #5000;  // 500,000ns 였던 것을 5,000ns(5us)로 확 줄임

            // [구간 2] 레이저 ON 
            data_i_tdata = -20000;
            #5000;  // 여기도 5,000ns(5us)로 확 줄임
        end
        
        $display("시뮬레이션 완료. Waveform을 확인하세요.");
        $finish;
    end
endmodule