# Feedback Loop QuETI

Red Pitaya STEMlab 125-14 기반 RF power feedback 프로젝트입니다.

현재 Red Pitaya `10.0.133.45`에 배포된 최종 FPGA 및 runtime snapshot은
[`RF_Power_Lock_FINAL`](RF_Power_Lock_FINAL/)에 있습니다. 기존 repository root의
`analog_echo` 파일들은 초기 프로젝트 기록으로 보존합니다.

최종본에서 먼저 볼 파일:

- `RF_Power_Lock_FINAL/README.md`: 빌드 및 배포 개요
- `RF_Power_Lock_FINAL/PROJECT_HANDOFF.md`: 하드웨어·제어 구조와 실험 상태
- `RF_Power_Lock_FINAL/output/`: 실제 보드에 배포된 bitstream과 HWH
- `RF_Power_Lock_FINAL/deploy/`: 부팅 서비스와 Python 제어 파일
- `RF_Power_Lock_FINAL/analog_echo.srcs/`: PI, ADC/DAC 보정 RTL과 block design

배포 산출물의 SHA-256은
`RF_Power_Lock_FINAL/DEPLOYED_ARTIFACTS.sha256`에 기록되어 있습니다.
