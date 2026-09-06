# RF Power Lock v1

Red Pitaya STEMlab 125-14용 RF power PI lock 설계입니다. 기존 `analog_echo`
폴더는 수정하지 않았으며, 이 폴더는 독립적으로 열고 빌드할 수 있는 복사본입니다.

## 이번 버전의 핵심 변경

- PI 제어기 계산을 여러 클럭 단계로 나눠 125 MHz에서 한 클럭에 몰리던 긴 계산 경로를 제거했습니다.
- 비동기 TTL enable 입력에 2단 동기화 회로를 넣었습니다.
- signed 덧셈, 곱셈, 비트 확장과 포화 처리를 명시해 경계값에서 잘못 잘리는 문제를 막았습니다.
- Kp를 signed Q6.10으로 확장해 `-32 ~ +31.999`를 사용할 수 있게 했고, Ki는 정밀도를 위해 Q3.13을 유지했습니다.
- EEPROM DAC gain/offset 보정을 유지하고, LV 입력용 ADC gain/offset 보정도 PI 제어기 앞단에 추가했습니다.
- 간소화된 보드 XDC에서 누락됐던 Red Pitaya 공식 ADC clock false-path 제약을 복원했습니다.

PI 제어기 자체의 지연은 4 clock(32 ns)이며, ADC 보정기는 offset 제거와 gain
적용을 2개의 추가 파이프라인 단계로 처리합니다.

## 주요 파일

- Vivado project: `analog_echo.xpr`
- PI controller RTL: `analog_echo.srcs/sources_1/imports/hdl/offset_ctrl.v`
- ADC calibration RTL: `analog_echo.srcs/sources_1/imports/hdl/adc_calibrator.v`
- DAC calibration RTL: `analog_echo.srcs/sources_1/imports/hdl/dac_calibrator.v`
- Red Pitaya constraints: `analog_echo.srcs/constrs_1/imports/FPGA proj/redpitaya-125-14.xdc`
- Self-checking simulation: `verification/tb_offset_scale_ctrl_pipeline.sv`
- Full build script: `build_rf_power_lock_v1.tcl`
- Generated bitstream: `output/rf_power_lock_v1.bit`
- Hardware handoff: `output/rf_power_lock_v1.hwh`

## 검증 결과

- PI pipeline behavioral checks: 21/21 pass
- ADC calibration behavioral checks: 8/8 pass
- Post-route setup WNS: +1.213 ns
- Post-route hold WHS: +0.048 ns
- Setup/hold failing endpoints: 0/0
- Controller resource use: channel당 DSP48E1 2개

자세한 결과는 `reports/timing_summary_routed.rpt`와
`reports/utilization_hierarchical.rpt`에서 확인할 수 있습니다.

## 다시 빌드하기

Vivado 2025.2 Tcl shell에서 다음 스크립트를 실행합니다.

```tcl
source {D:/path/to/Feedback_Loop_QuETI/RF_Power_Lock_FINAL/prepare_safe_build_copy.tcl}
```

프로젝트 경로의 `[FINAL]`을 Vivado 2025.2 내부 IP 생성기가 Tcl 명령으로 잘못
해석하는 문제가 있어, 위 스크립트는 먼저 저장소 옆의
`RF_Power_Lock_ADC_BUILD` 경로에 빌드용 복사본을 만든 뒤
전체 빌드를 실행합니다. 빌드 스크립트는 제어기 OOC 합성을 포함해 전체 설계를 새로 빌드하고, setup 또는
hold 여유가 음수이면 실패로 종료합니다. 성공하면 `output` 폴더의 `.bit`와
`.hwh`를 갱신합니다.

공식 제약 참고:
https://github.com/RedPitaya/RedPitaya-FPGA/blob/master/sdc/red_pitaya.xdc

## Red Pitaya 자동실행

2026-07-29에 보드의 다음 경로로 배포했습니다.

```text
/home/xilinx/jupyter_notebooks/RF_Power_Lock/
```

`rf-power-lock.service`가 부팅할 때 새 bitstream을 로드하고 EEPROM의 LV ADC와
DAC gain/offset을 모두 적용합니다. 실험 조건을 모르는 상태에서 임의의 출력을 만들지
않도록 offset, P gain, I gain, threshold는 두 채널 모두 0으로 시작합니다.
이 값들은 overlay가 올라온 뒤 AXI GPIO 0~3을 통해 설정할 수 있습니다.

기존 `dac-voltage-cycle.service`는 중지 및 비활성화했으며, 교체 전 파일은
보드의 다음 폴더에 보존했습니다.

```text
/home/xilinx/jupyter_notebooks/DAC_voltage_test/backups/pre_rf_power_lock_20260729_170435/
```
