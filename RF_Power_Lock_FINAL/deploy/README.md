# RF Power Lock 제어

이 폴더에서 실험자가 직접 사용할 파일은 `rf_power_lock_control.py` 하나입니다.
`_system` 폴더는 FPGA와 자동 시작에 필요한 내부 파일이므로 수정하지 않습니다.

현재 설정 확인:

```bash
cd /home/xilinx/jupyter_notebooks/RF_Power_Lock
/usr/local/share/pynq-venv/bin/python3 rf_power_lock_control.py status
```

채널 1을 목표 PD 전압 0.20 V, P gain 0.01, I gain 0으로 시작하는 문법 예시:

```bash
/usr/local/share/pynq-venv/bin/python3 rf_power_lock_control.py apply \
  --channel 1 --setpoint-v 0.20 --kp 0.01 --ki 0
```

실험 중 gain만 변경:

```bash
/usr/local/share/pynq-venv/bin/python3 rf_power_lock_control.py gain \
  --channel 1 --kp 0.02 --ki 0
```

피드백을 끄고 적분값까지 초기화:

```bash
/usr/local/share/pynq-venv/bin/python3 rf_power_lock_control.py off
```

다른 Python 파일에서도 사용할 수 있습니다.

```python
from rf_power_lock_control import apply, off, set_gains, set_setpoint, status

apply(channel=1, setpoint_volts=0.20, kp=0.01, ki=0.0)
set_gains(channel=1, kp=0.02, ki=0.0)
set_setpoint(channel=1, setpoint_volts=0.21)
status()
off()
```

Gain 범위와 형식:

```text
Kp: Q6.10, -32.0 ~ +31.9990234375, 간격 약 0.0009766
Ki: Q3.13,  -4.0 ~  +3.9998779296875, 간격 약 0.0001221
```

2026-08-07 이전 control module은 Kp를 Q3.13으로 전송하므로 새 서비스가 해당 요청을
거부합니다. Jupyter에서 이미 import했다면 아래처럼 새 파일을 다시 불러오십시오.

```python
import importlib
import rf_power_lock_control
importlib.reload(rf_power_lock_control)
```

전압 변환은 Red Pitaya 아날로그 입력 점퍼가 LV, 즉 약 +/-1 V 범위로 설정되어 있다고 가정합니다.
소프트웨어 설정만으로 입력 범위가 바뀌지는 않으므로 실제 IN1/IN2 점퍼도 LV 위치여야 합니다.
부팅하거나 `apply()`/`off()`로 FPGA를 다시 불러올 때 서비스가 EEPROM의 LV ADC gain/offset과
DAC gain/offset을 읽어 FPGA에 자동 적용합니다. 따라서 `setpoint_volts`에는 오실로스코프에서
원하는 실제 IN1/IN2 전압을 그대로 입력하면 됩니다.
1 V를 넘는 PD 신호는 감쇠 또는 신호 조절 없이 Red Pitaya 입력에 직접 연결하지 마십시오.
처음에는 `ki=0`으로 두고 작은 P gain부터 사용하십시오. 제어 방향이 반대이면 즉시 `off`를 실행하십시오.
