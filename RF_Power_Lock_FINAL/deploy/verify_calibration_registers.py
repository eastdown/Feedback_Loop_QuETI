#!/usr/bin/env python3
"""Read back the live ADC/DAC calibration AXI GPIO registers."""

from pynq import MMIO


DAC_GAIN_BASE = 0x41240000
DAC_OFFSET_BASE = 0x41250000
ADC_GAIN_BASE = 0x41260000
ADC_OFFSET_BASE = 0x41270000
REGISTER_RANGE = 0x10000
CHANNEL1_DATA = 0x0
CHANNEL2_DATA = 0x8


def read_channels(base):
    registers = MMIO(base, REGISTER_RANGE)
    return registers.read(CHANNEL1_DATA) & 0xFFFF, registers.read(CHANNEL2_DATA) & 0xFFFF


dac_gain_ch1, dac_gain_ch2 = read_channels(DAC_GAIN_BASE)
dac_offset_ch1, dac_offset_ch2 = read_channels(DAC_OFFSET_BASE)
adc_gain_ch1, adc_gain_ch2 = read_channels(ADC_GAIN_BASE)
adc_offset_ch1, adc_offset_ch2 = read_channels(ADC_OFFSET_BASE)

print(f"DAC gain:   OUT1=0x{dac_gain_ch1:04X}, OUT2=0x{dac_gain_ch2:04X}")
print(f"DAC offset: OUT1=0x{dac_offset_ch1:04X}, OUT2=0x{dac_offset_ch2:04X}")
print(f"ADC gain:   IN1=0x{adc_gain_ch1:04X}, IN2=0x{adc_gain_ch2:04X}")
print(f"ADC offset: IN1=0x{adc_offset_ch1:04X}, IN2=0x{adc_offset_ch2:04X}")

expected = (0x1D24, 0x1D13, 0xFFF8, 0xFFE8, 0x21D0, 0x21BB, 0xFEE4, 0xFD88)
actual = (
    dac_gain_ch1,
    dac_gain_ch2,
    dac_offset_ch1,
    dac_offset_ch2,
    adc_gain_ch1,
    adc_gain_ch2,
    adc_offset_ch1,
    adc_offset_ch2,
)
if actual != expected:
    raise SystemExit(f"register verification failed: expected {expected}, got {actual}")

print("ADC/DAC calibration register verification: PASS")
