# RF Power Lock 프로젝트 Handoff

> 최종 확인일: 2026-08-10 (KST)
>
> 이 문서는 다른 컴퓨터의 Codex가 기존 대화 없이도 프로젝트를 이어받을 수 있도록 작성한 기준 문서다.

## 1. 가장 중요한 현재 상태

- Red Pitaya 주소: `10.0.133.45`
- 장치: Red Pitaya STEMlab 125-14 Original Generation
- FPGA bitstream은 이미 제작·검증·배포되어 있다. 당분간 Vivado 수정은 계획하지 않는다.
- 현재 FPGA는 **TTL 입력을 사용하지 않는 항상 활성화 구조**다.
- 그러나 현재 P gain과 I gain이 모두 0이므로 **실제 피드백은 OFF**다.
- Red Pitaya의 `rf-power-lock.service`는 `enabled`이고 `active`다.
- 부팅 시 bitstream과 EEPROM LV ADC/DAC 보정값을 자동으로 적용한다.
- 부팅 시 setpoint, P, I, threshold는 모두 0으로 초기화한다.
- 사용자 제어 파일은 현재 **Red Pitaya fast analog input LV(약 ±1 V) 기준**으로 설정되어 있다.
- LV 소프트웨어는 2026-08-04에 Red Pitaya에도 최종 반영하고 검증했다.
- 실제 보드의 IN1 물리 점퍼가 LV 위치인지 원격으로는 확인할 수 없다. 실험 전에 반드시 육안 확인한다.
- PD 출력은 그대로 연결하면 1 V를 넘을 수 있다. LV 사용 시 외부 감쇠회로가 필요하다.
- 현재 보드 상태 확인값:

```text
CH1: setpoint=0 V, Kp=0, Ki=0, threshold=0
CH2: setpoint=0 V, Kp=0, Ki=0, threshold=0
```

## 2. 프로젝트 목적

RF power가 변해도 Power Detector(PD)가 측정하는 RF 세기가 목표값으로 돌아오도록 빠른 PI feedback loop를 만든다.

전체 신호 흐름은 다음과 같다.

```text
RF source
  → VVA RF IN
  → VVA RF OUT
  → RF splitter/coupler 또는 직접 연결
  → Power Detector RF IN
  → PD DC OUT
  → 감쇠회로
  → Red Pitaya IN1
  → FPGA PI controller
  → Red Pitaya OUT1 (약 -1~+1 V)
  → Summing amplifier (+3 V level shift)
  → VVA control (약 2~4 V)
```

의도한 feedback 방향은 다음과 같다.

```text
RF power 증가
→ PD DC voltage 감소
→ FPGA가 VVA attenuation을 증가시키는 방향으로 보정
→ RF power가 목표값으로 복귀
```

## 3. 주요 하드웨어

### 3.1 RF source

- 최대 출력: `+10 dBm`
- 50 Ω sinusoidal signal 기준:
  - `+10 dBm = 10 mW`
  - 약 `0.707 Vrms`
  - 약 `2.00 Vpp`
- 실제 실험 주파수는 최종 확정·기록이 필요하다.
  - PD 검증 PDF는 주로 10 MHz다.
  - VVA 검증 PDF는 30 MHz 조건이 포함되어 있다.

### 3.2 VVA

- 모델: Mini-Circuits `ZX73-2500+`
- V+ supply: `3 V`
- Control voltage 사용 범위: `2~4 V`
- 기존 실험에서 V+=3 V일 때:
  - control 2 V → attenuation 약 15 dB
  - control 4 V → attenuation 약 7 dB
- control voltage가 올라가면 attenuation은 감소한다.
- 공식 RF input absolute maximum은 +20 dBm이므로 RF source +10 dBm은 안전 범위다.
- 공식 문서: <https://www.minicircuits.com/pdfs/ZX73-2500%2B.pdf>

### 3.3 Power Detector

- 모델: Mini-Circuits `ZX47-40LN-S+`
- RF power가 커질수록 DC output voltage는 감소한다.
- Vcc: 5 V, 전류 약 100 mA typical
- 기존 10 MHz 측정값:

| PD RF input | PD DC output |
|---:|---:|
| -10 dBm | 1.31 V |
| 0 dBm | 1.06 V |
| +10 dBm | 0.802 V |

- RF가 거의 없을 때 PD output은 약 2.1 V까지 올라간다.
- 공식 동작 범위는 대략 -40~+20 dBm이고, 현재 예상 PD input은 이 범위 안이다.
- 공식 문서: <https://www.minicircuits.com/WebStore/dashboardPdf?model=ZX47-40LN-S%2B>

### 3.4 Red Pitaya

- Fast analog input physical range는 jumper로 선택한다.
  - LV: 약 ±1 V full scale
  - HV: 약 ±20 V full scale
- **현재 Python control file은 LV 기준이다.**
- IN1 physical jumper도 LV 위치여야 한다.
- Fast analog output은 약 ±1 V이며, EEPROM DAC calibration을 적용한다.
- 입력 점퍼 공식 설명:
  <https://redpitaya.readthedocs.io/en/latest/developerGuide/hardware/ORIG_GEN/hw_specs/hw_specs.html#jumper-settings>

## 4. 예상 신호 범위

다음 계산은 아래 조건을 가정한다.

- RF source = +10 dBm
- VVA attenuation = 15~7 dB
- VVA와 PD 사이의 추가 cable/splitter/coupler loss는 우선 0 dB
- PD curve는 기존 10 MHz 측정값 사이를 보간

계산식:

```text
P_PD(dBm) = P_source - attenuation - additional_path_loss
```

### 4.1 VVA OUT이 PD에 직접 연결된 경우

| VVA control | attenuation 추정 | VVA RF output = PD RF input | RF Vpp, 50 Ω | PD DC output 추정 |
|---:|---:|---:|---:|---:|
| 2.0 V | 15 dB | -5 dBm | 0.356 Vpp | 1.185 V |
| 2.5 V | 13 dB | -3 dBm | 0.448 Vpp | 1.135 V |
| 3.0 V | 11 dB | -1 dBm | 0.564 Vpp | 1.085 V |
| 3.5 V | 9 dB | +1 dBm | 0.710 Vpp | 1.034 V |
| 4.0 V | 7 dB | +3 dBm | 0.893 Vpp | 0.983 V |

중간 동작점으로 VVA control 3 V를 선택하면 attenuation 약 11 dB, PD input 약 -1 dBm이다. 2~4 V 양쪽으로 움직일 수 있어 약 ±4 dB의 control headroom을 갖는다.

### 4.2 LV 입력을 위한 권장 PD 감쇠회로

PD를 Red Pitaya LV input에 직접 연결하면 대부분의 동작 범위에서 1 V를 넘는다. RF가 꺼지면 약 2.1 V가 되므로 직접 연결하면 안 된다.

권장 divider:

```text
PD DC OUT ── 604 Ω ──┬── Red Pitaya IN1
                      │
                    402 Ω
                      │
                     GND
```

```text
Divider ratio = 402 / (604 + 402) ≈ 0.400
Total load ≈ 1006 Ω
```

이 값은 PD datasheet graph의 1 kΩ output load 조건과 거의 같다. Red Pitaya IN1은 divider 중간 노드를 측정한다.

| 상태 | PD 원래 출력 | divider 후 IN1 |
|---|---:|---:|
| VVA control 2 V | 1.185 V | 0.474 V |
| VVA control 3 V | 1.085 V | 0.434 V |
| VVA control 4 V | 0.983 V | 0.393 V |
| RF OFF | 약 2.1 V | 약 0.84 V |

따라서 direct RF path에서 가운데 동작점을 사용할 경우 최초 예상 setpoint는 약 `0.434 V`다. 실제 setpoint는 divider 뒤, 즉 Red Pitaya IN1에 실제로 들어가는 전압을 oscilloscope로 측정한 값을 사용한다.

### 4.3 RF splitter 또는 T connector가 있는 경우

정식 50 Ω 2-way RF power splitter라면 각 branch에 이상적으로 약 3 dB loss가 추가된다. 실제 insertion loss까지 포함하면 보통 3 dB보다 조금 크므로 splitter datasheet를 사용한다.

3 dB loss만 가정하면:

| VVA control | VVA OUT | splitter 후 PD input | PD output 추정 | 0.4 divider 후 |
|---:|---:|---:|---:|---:|
| 2 V | -5 dBm | -8 dBm | 약 1.26 V | 약 0.504 V |
| 3 V | -1 dBm | -4 dBm | 약 1.16 V | 약 0.464 V |
| 4 V | +3 dBm | 0 dBm | 약 1.06 V | 약 0.424 V |

단순 SMA/BNC T connector에 50 Ω load 두 개를 연결하면 source가 25 Ω을 보게 되어 impedance mismatch와 reflection이 생긴다. 이 경우 일정한 3 dB splitter로 취급하면 안 된다. 정량적인 실험에는 정식 RF splitter 또는 directional coupler를 권장한다.

PD의 DC output 뒤에서 oscilloscope와 Red Pitaya로 T 분기하는 경우에는 두 입력을 모두 1 MΩ으로 두면 loading은 작다. Oscilloscope를 50 Ω으로 설정하면 PD output이 크게 달라질 수 있다.

## 5. Feedback 부호

현재 측정된 mapping이 `V_DAC 증가 → VVA control 증가`인 비반전 구조라고 가정하면:

```text
Red Pitaya OUT1 증가
→ VVA control 증가
→ attenuation 감소
→ RF power 증가
→ PD voltage 감소
```

FPGA error 정의는:

```text
error = setpoint - ADC input
```

따라서 현재 배선에서는 **Kp와 Ki가 음수여야 negative feedback이 될 것으로 예상**된다. 실제 실험에서는 `Ki=0`으로 두고 매우 작은 음수 Kp부터 방향을 검증한다. Summing amplifier가 반전 구조이거나 연결이 달라지면 부호도 달라질 수 있으므로 scope로 반드시 확인한다.

## 6. FPGA 구현 상태

### 6.1 로컬 Vivado 프로젝트

```text
RF Power Lock [FINAL]/analog_echo.xpr
```

주요 HDL:

```text
RF Power Lock [FINAL]/analog_echo.srcs/sources_1/imports/hdl/offset_ctrl.v
RF Power Lock [FINAL]/analog_echo.srcs/sources_1/imports/hdl/adc_calibrator.v
RF Power Lock [FINAL]/analog_echo.srcs/sources_1/imports/hdl/dac_calibrator.v
```

배포용 bitstream/hardware metadata:

```text
RF Power Lock [FINAL]/output/rf_power_lock_v1.bit
RF Power Lock [FINAL]/output/rf_power_lock_v1.hwh
```

### 6.2 PI pipeline

기존 코드는 한 clock 안에서 subtraction, multiplication, scaling, saturation, addition을 너무 많이 수행해 setup/hold 문제가 있었다. 현재 `offset_ctrl.v`는 작업을 여러 registered stage로 분리했다.

```text
S1: input/control capture, error calculation, threshold comparison
S2: P/I multiplication
S3: multiplier output register
S4: P scaling/saturation, I accumulation
S5: P+I addition and final saturation
```

- Clock: 125 MHz, 8 ns period
- 입력 capture edge부터 output edge까지 4 clock latency
- 현재 no-TTL + ADC calibration build timing:
  - setup WNS: +1.213 ns
  - hold WHS: +0.048 ns
- Behavioral pipeline simulation: 21/21 checks passed
- ADC calibration simulation: 8/8 checks passed

### 6.3 TTL 상태

`offset_ctrl.v` 기본 parameter:

```verilog
parameter integer USE_TTL_ENABLE = 0
```

따라서 TTL pin은 현재 servo enable에 사용되지 않는다. 양 채널의 controller는 FPGA 관점에서 항상 enabled다. 다만 P와 I가 0이면 feedback action은 없다.

TTL 기능을 다시 쓰거나 TTL LOW로 hardware integrator reset을 하고 싶다면 Vivado 수정과 bitstream 재생성이 필요하다. 현재 계획에서는 Python의 `off()` 또는 `apply()`가 FPGA를 reload하여 integrator를 초기화한다.

### 6.4 Kp Q6.10 / Ki Q3.13 gain

P gain과 I gain은 같은 signed 16-bit register를 사용하지만 소수점 위치가 다르다.

```text
Kp register = real Kp × 1024       (Q6.10)
real Kp = Kp register / 1024

Ki register = real Ki × 8192       (Q3.13)
real Ki = Ki register / 8192
```

예:

```text
Kp  1.0  → 1024
Kp 16.0  → 16384
Kp -16.0 → -16384
Ki  1.0  → 8192
```

Kp 표현 범위는 `-32.0 ~ +31.9990234375`, 설정 간격은 약 `0.0009766`이다.
Ki 표현 범위는 기존과 같이 `-4.0 ~ +3.9998779296875`, 설정 간격은 약 `0.0001221`이다.

gain 형식 protocol version은 2다. 새 bitstream에서 오래된 Q3.13 Kp client를 사용하면
의도보다 Kp가 8배 커질 수 있으므로 서비스가 오래된 client 요청을 거부한다. Jupyter에서
기존 module을 import한 상태라면 `importlib.reload(rf_power_lock_control)` 후 사용한다.

주의: I accumulator는 FPGA에서 125 MHz sample마다 갱신될 수 있다. 큰 Ki는 매우 공격적이다. 과거 notebook의 `Kp=3`, `Ki=0.3`은 단순 시험 기록이며 다시 실행하면 안 된다.

### 6.5 Threshold 의미

현재 threshold는 error deadband가 아니다.

```verilog
ADC input > threshold
```

일 때만 integral accumulator update를 허용하는 signal-valid gate다. P 항은 threshold와 무관하게 계산된다.

## 7. ADC/DAC EEPROM calibration

초기 custom FPGA path는 Red Pitaya factory DAC calibration을 자동으로 사용하지 않아 출력 절댓값이 약 100~150 mV 크게 측정되었다. 현재 구조는 EEPROM에서 보드별 gain/offset을 읽고 모든 DAC sample에 선형 보정을 적용한다.

현재 보드에서 읽은 값:

```text
EEPROM zone: user
version: 5
OUT1 gain_q13: 7460
OUT1 offset: -8
OUT2 gain_q13: 7443
OUT2 offset: -24
IN1 LV gain_q13: 8656
IN1 LV offset: -284
IN2 LV gain_q13: 8635
IN2 LV offset: -632
```

보정 구조:

```text
calibrated DAC code = requested code × gain + offset
```

`dac_calibrator.v`가 channel별 보정과 min/max saturation을 담당한다.

ADC 쪽은 PI 제어기가 값을 받기 전에 아래 보정을 적용한다.

```text
calibrated ADC code = (raw ADC code - offset) × gain
```

`adc_calibrator.v`가 channel별 offset 제거, gain 적용, signed saturation을 담당한다. 따라서 Python의 `setpoint_volts`는 이제 EEPROM으로 보정된 LV 입력 전압과 비교된다. 단, 보드의 물리 입력 점퍼도 반드시 LV 위치여야 하며, 외부 회로와 계측기 자체의 오차까지 EEPROM이 보정해 주는 것은 아니므로 실제 실험값은 oscilloscope로 함께 확인한다.

## 8. 현재 bitstream 식별값

현재 로컬 output과 Red Pitaya에 배포된 bitstream SHA-256이 일치한다.

```text
rf_power_lock_v1.bit
SHA-256: ca655d44a54156309450f3203186640b75283df305c8652cafbb2f8361065c33

rf_power_lock_v1.hwh
SHA-256: 6d5aa39c2e008c2238525d1be96a017ee732509fbeb9c03f312ab0fc2252f3ec
```

## 9. FPGA register map

각 AXI GPIO의 channel 1 register offset은 `0x0`, channel 2는 `0x8`이다.

| 기능 | AXI base address |
|---|---:|
| setpoint/offset | `0x41200000` |
| P gain | `0x41210000` |
| I gain | `0x41220000` |
| threshold | `0x41230000` |
| DAC calibration gain | `0x41240000` |
| DAC calibration offset | `0x41250000` |
| ADC calibration gain | `0x41260000` |
| ADC calibration offset | `0x41270000` |

일반 사용자 Python은 이 주소를 직접 MMIO하지 않는다. root service가 hardware를 소유하고 Unix socket으로 명령을 받는다.

## 10. Red Pitaya runtime 구조

### 10.1 네트워크

```text
Board IP: 10.0.133.45
SSH user: xilinx
Jupyter: http://10.0.133.45
```

로그인 password는 이 문서에 저장하지 않는다. 사용자에게 별도로 확인한다. 다른 PC를 direct Ethernet으로 연결할 때는 PC NIC를 `10.0.133.x/24`의 겹치지 않는 주소로 설정한다.

확인된 SSH host key fingerprint:

```text
ssh-ed25519 SHA256:c+9OzOS/pf1f22xHN89icl7yuaX8D9sdjnufONRaYIU
```

### 10.2 Red Pitaya 폴더

```text
/home/xilinx/jupyter_notebooks/RF_Power_Lock/
├── rf_power_lock_control.py      # 사용자가 import/실행
├── README.md
├── execution.ipynb              # 과거 시험 notebook; 위험한 old gain cell 있음
├── Untitled.ipynb
└── _system/
    ├── rf_power_lock.bit
    ├── rf_power_lock.hwh
    ├── rf_power_lock_service.py
    ├── redpitaya_eeprom.py
    └── verify_rf_power_lock_runtime.py
```

### 10.3 systemd service

```text
Service: rf-power-lock.service
Unit file: /etc/systemd/system/rf-power-lock.service
ExecStart:
/usr/local/share/pynq-venv/bin/python3 \
  /home/xilinx/jupyter_notebooks/RF_Power_Lock/_system/rf_power_lock_service.py
```

상태 확인:

```bash
systemctl is-enabled rf-power-lock.service
systemctl is-active rf-power-lock.service
systemctl status rf-power-lock.service --no-pager -l
```

서비스는 root로 실행되어 FPGA/MMIO를 소유한다. 일반 `xilinx` 사용자는 다음 Unix socket을 통해 제어한다.

```text
/run/rf-power-lock/control.sock
```

### 10.4 부팅 동작

1. EEPROM LV ADC/DAC calibration read/validation
2. FPGA reset 및 bitstream load
3. setpoint/P/I/threshold 모두 0
4. channel별 ADC/DAC gain/offset register 적용
5. local control socket 생성

따라서 Ethernet이 없어도 전원 부팅 후 bitstream은 올라간다. 다만 P와 I는 0으로 시작하므로 부팅만으로 feedback lock은 시작하지 않는다.

## 11. Python control file 사용법

로컬 원본:

```text
RF Power Lock [FINAL]/deploy/rf_power_lock_control.py
```

Red Pitaya 원본:

```text
/home/xilinx/jupyter_notebooks/RF_Power_Lock/rf_power_lock_control.py
```

Jupyter cell:

```python
%cd /home/xilinx/jupyter_notebooks/RF_Power_Lock

from rf_power_lock_control import (
    apply,
    off,
    set_gains,
    set_setpoint,
    status,
)
```

현재 상태 확인:

```python
status()
```

안전 정지 및 integrator 완전 초기화:

```python
off()
```

새 조건 시작:

```python
apply(
    channel=1,
    setpoint_volts=MEASURED_IN1_VOLTAGE,
    kp=SMALL_VERIFIED_SIGN_KP,
    ki=0.0,
    threshold_volts=0.0,
)
```

`apply()` 동작:

- FPGA를 reload하여 두 channel의 integrator를 모두 초기화한다.
- 두 channel을 P=I=0으로 만든다.
- 선택한 channel의 setpoint, threshold, P, I를 적용한다.
- 호출 즉시 feedback이 시작된다.

실행 중 gain만 변경:

```python
set_gains(channel=1, kp=NEW_KP, ki=NEW_KI)
```

`set_gains()`는 기존 integral memory를 지우지 않는다. 단순히 Ki=0으로 바꿔도 이미 누적된 I output은 남을 수 있으므로 feedback을 완전히 끄려면 `off()`를 사용한다.

실행 중 setpoint 변경:

```python
set_setpoint(channel=1, setpoint_volts=NEW_TARGET)
```

Jupyter kernel에서 control module을 이미 import한 뒤 파일을 교체했다면:

```python
import importlib
import rf_power_lock_control
importlib.reload(rf_power_lock_control)
```

## 12. 기존 execution.ipynb 주의사항

Red Pitaya의 `execution.ipynb`에는 과거 다음 test cell이 남아 있다.

```python
apply(
    channel=1,
    setpoint_volts=0.9,
    kp=3,
    ki=0.3,
    threshold_volts=0.0,
)
```

이 cell은 **현재 권장값이 아니며 다시 실행하면 안 된다.** 마지막에는 `off()`가 실행되어 현재 hardware state는 P=I=0이다. 새 실험 notebook에서는 실제 divider 뒤 IN1 전압과 작은 negative Kp를 사용해 처음부터 다시 시작한다.

## 13. 권장 feedback 실험 순서

1. Red Pitaya IN1 jumper가 LV인지 확인한다.
2. PD divider와 공통 ground를 확인한다.
3. Oscilloscope 입력은 1 MΩ으로 사용한다.
4. RF source를 안전한 power로 설정한다.
5. `off()`를 실행한다.
6. VVA control 약 3 V에서 divider 뒤 PD voltage를 측정한다.
7. 그 측정값을 setpoint로 사용한다.
8. `Ki=0`으로 두고 매우 작은 Kp부터 시작한다.
9. Kp 부호가 negative feedback 방향인지 확인한다.
10. RF source power를 ±0.5 dB 정도 step하고 PD가 setpoint로 돌아오는지 본다.
11. P가 안정적일 때만 작은 Ki를 추가한다.
12. PD overshoot, settling time, steady-state error, VVA control min/max를 기록한다.

Scope 권장 channel:

```text
CH1: RF source marker 또는 power-change timing signal
CH2: PD divider 뒤 / Red Pitaya IN1 voltage
CH3: Summing amplifier output / VVA control voltage
```

Feedback 성공의 핵심 관찰:

```text
Open loop: RF step 후 PD voltage가 바뀐 상태로 남음
Closed loop: PD voltage가 잠시 변한 뒤 setpoint로 돌아옴
```

## 14. 아직 결정·확인해야 할 사항

다른 컴퓨터에서 작업을 시작할 때 아래 항목부터 확인한다.

1. 최종 RF operating frequency
2. VVA OUT과 PD 사이에 실제로 무엇이 있는지
   - direct cable
   - 정식 50 Ω splitter
   - directional coupler
   - 단순 T connector
3. splitter/coupler/cable의 실제 loss
4. Red Pitaya IN1 physical jumper가 LV인지
5. 604 Ω / 402 Ω divider가 실제 설치되었는지
6. divider 뒤 실제 PD voltage range
7. Summing amplifier가 정확히 `Vcontrol = 3 V + VDAC`인지 및 polarity
8. 최종 setpoint
9. 안전한 Kp, Ki
10. PD signal noise/ripple과 필요한 filtering

현재 FPGA는 ADC sample을 CPU/Python에 직접 readback하는 register를 제공하지 않는다. `status()`는 setpoint/gain/threshold control register만 읽는다. 실시간 PD는 oscilloscope에서 확인한다. Python에서 ADC live data가 꼭 필요하면 새로운 FPGA register path 또는 별도 acquisition 방법이 필요하며, 이는 다시 Vivado 작업을 요구할 수 있다.

## 15. GitHub 및 다른 PC로 이동할 때의 주의점

기존 Git repository:

```text
Local: Laser_Intensity_Lock/analog_echo
Remote: https://github.com/eastdown/Feedback_Loop_QuETI.git
Branch: main
Last observed commit: 76829b2 Initial commit
```

현재 GitHub repository에는 기존 `analog_echo` 프로젝트와 함께 최신 최종본이
`RF_Power_Lock_FINAL/` 폴더로 포함되어 있다. 실제 보드에 배포된 bitstream/hwh,
runtime/control 파일, 주요 RTL, block design/IP 설정, 검증 소스와 timing report를
이 폴더에서 함께 보존한다.

다른 PC로 옮기기 전에 최소한 다음을 보존·commit해야 한다.

```text
RF Power Lock [FINAL]/PROJECT_HANDOFF.md
RF Power Lock [FINAL]/deploy/
RF Power Lock [FINAL]/output/rf_power_lock_v1.bit
RF Power Lock [FINAL]/output/rf_power_lock_v1.hwh
RF Power Lock [FINAL]/analog_echo.srcs/sources_1/imports/hdl/offset_ctrl.v
RF Power Lock [FINAL]/analog_echo.srcs/sources_1/imports/hdl/adc_calibrator.v
RF Power Lock [FINAL]/analog_echo.srcs/sources_1/imports/hdl/dac_calibrator.v
RF Power Lock [FINAL]/verification/
Lab NOte/PD & VVA Check.pdf
Lab NOte/Summing Amplifier & RedPitaya 출력 체크.pdf
Lab NOte/VVA & PD Reaction Time.pdf
```

Vivado 개발을 중단한다면 generated cache/run 전체보다 `deploy`, `output`, 주요 HDL, verification source/log, 이 handoff 문서를 중심으로 clean repository를 만드는 편이 관리하기 쉽다.

Bitstream이 이미 존재하므로 다른 PC에 Vivado가 없어도 Red Pitaya runtime 제어, Python instrument automation, 실험 데이터 분석은 계속할 수 있다.

## 16. Red Pitaya 복구 정보

주요 backup directory:

```text
/home/xilinx/rf_power_lock_backups/
```

확인된 backup 예:

```text
pre_no_ttl_20260803_153530
pre_control_20260803_163556
pre_socket_control_20260803_164100
pre_hv_control_20260803
pre_lv_final_20260804
pre_adc_calibration_20260807_061847
pre_kp_q6_10_20260807_161740
```

현재 LV control file로 바꾸기 직전의 HV client/README는 `pre_lv_final_20260804`에 백업했다.

## 17. 새 Codex에게 줄 첫 요청 예시

```text
PROJECT_HANDOFF.md를 먼저 전부 읽어라.
Vivado/FPGA 수정은 당분간 하지 않는다.
현재 목표는 Red Pitaya Python control과 외부 RF/TTL 장비 제어를 결합해
open-loop/closed-loop step response를 측정하고 안전한 Kp/Ki를 찾는 것이다.
먼저 실제 RF frequency, RF splitter/coupler, PD divider 설치 상태를 확인하고
예상 power/voltage range를 다시 계산한 뒤 실험 코드를 작성해라.
```
