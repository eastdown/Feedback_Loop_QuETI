#!/usr/bin/env python3
"""Read back the live RF Power Lock AXI GPIO registers without changing them."""

from pathlib import Path

from pynq import MMIO, PL


REGISTER_RANGE = 0x10000
CHANNEL1_DATA = 0x0
CHANNEL2_DATA = 0x8

REGISTERS = (
    ("offset", 0x41200000, (0x0000, 0x0000)),
    ("P gain", 0x41210000, (0x0000, 0x0000)),
    ("I gain", 0x41220000, (0x0000, 0x0000)),
    ("threshold", 0x41230000, (0x0000, 0x0000)),
    ("DAC gain", 0x41240000, (0x1D24, 0x1D13)),
    ("DAC offset", 0x41250000, (0xFFF8, 0xFFE8)),
)


def read_channels(base):
    registers = MMIO(base, REGISTER_RANGE)
    return (
        registers.read(CHANNEL1_DATA) & 0xFFFF,
        registers.read(CHANNEL2_DATA) & 0xFFFF,
    )


bitfile = str(PL.bitfile_name or "")
print(f"loaded bitfile: {bitfile}")
if Path(bitfile).name != "rf_power_lock.bit":
    raise SystemExit(f"unexpected loaded bitfile: {bitfile}")

for label, base, expected in REGISTERS:
    actual = read_channels(base)
    print(
        f"{label:10s} @ 0x{base:08X}: "
        f"CH1=0x{actual[0]:04X}, CH2=0x{actual[1]:04X}"
    )
    if actual != expected:
        raise SystemExit(
            f"{label} verification failed: expected {expected}, got {actual}"
        )

print("RF_POWER_LOCK_RUNTIME_VERIFY=PASS")
