#!/usr/bin/env python3
"""Read Red Pitaya universal fast ADC/DAC calibration without writing EEPROM."""

from dataclasses import dataclass
import os
import struct


EEPROM_PATH = "/sys/bus/i2c/devices/0-0050/eeprom"
USER_ZONE_OFFSET = 0x0000
FACTORY_ZONE_OFFSET = 0x1C00

UNIVERSAL_VERSIONS = {5, 6}
HEADER = struct.Struct("<BBH4x")
ITEM = struct.Struct("<Hi")
MAX_ITEMS = 512

DAC_CH1_GAIN = 1
DAC_CH1_OFFSET = 2
DAC_CH2_GAIN = 3
DAC_CH2_OFFSET = 4
ADC_CH1_GAIN_LV = 9
ADC_CH1_OFFSET_LV = 10
ADC_CH2_GAIN_LV = 11
ADC_CH2_OFFSET_LV = 12

# Red Pitaya calibBaseScaleFromVoltage(1.0, true):
# uint32_t(1.0 / 100.0 * 0x10000000)
UNIVERSAL_GAIN_BASE = int((1 << 28) / 100.0)


@dataclass(frozen=True)
class DacChannelCalibration:
    raw_gain: int
    raw_offset: int

    @property
    def gain(self):
        return self.raw_gain / UNIVERSAL_GAIN_BASE

    def gain_fixed(self, fractional_bits=13):
        value = int(round(self.gain * (1 << fractional_bits)))
        if not -(1 << 15) <= value <= (1 << 15) - 1:
            raise ValueError(f"DAC gain does not fit signed 16-bit Q format: {value}")
        return value

    @property
    def fpga_offset(self):
        # EEPROM offset is expressed in physical 14-bit DAC counts.  The custom
        # FPGA stream is a 16-bit signed word and DAC.vhd drops bits [1:0].
        value = self.raw_offset << 2
        if not -(1 << 15) <= value <= (1 << 15) - 1:
            raise ValueError(f"DAC offset does not fit signed 16-bit word: {value}")
        return value


@dataclass(frozen=True)
class AdcChannelCalibration:
    raw_gain: int
    raw_offset: int

    @property
    def gain(self):
        return self.raw_gain / UNIVERSAL_GAIN_BASE

    def gain_fixed(self, fractional_bits=13):
        value = int(round(self.gain * (1 << fractional_bits)))
        if not -(1 << 15) <= value <= (1 << 15) - 1:
            raise ValueError(f"ADC gain does not fit signed 16-bit Q format: {value}")
        return value

    @property
    def fpga_offset(self):
        # EEPROM offset is in signed physical 14-bit ADC counts.  The ADC IP
        # shifts every sample left by two before emitting its 16-bit stream.
        value = self.raw_offset << 2
        if not -(1 << 15) <= value <= (1 << 15) - 1:
            raise ValueError(f"ADC offset does not fit signed 16-bit word: {value}")
        return value


@dataclass(frozen=True)
class BoardCalibration:
    version: int
    write_protect_check: int
    zone: str
    dac_channel1: DacChannelCalibration
    dac_channel2: DacChannelCalibration
    adc_channel1_lv: AdcChannelCalibration
    adc_channel2_lv: AdcChannelCalibration

    # Keep the original DAC-only helper API working for the standalone voltage
    # cycle utility and older notebooks.
    @property
    def channel1(self):
        return self.dac_channel1

    @property
    def channel2(self):
        return self.dac_channel2


def _read_exact_at(path, offset, size):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.lseek(fd, offset, os.SEEK_SET)
        chunks = []
        remaining = size
        while remaining:
            chunk = os.read(fd, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
    finally:
        os.close(fd)
    if len(data) != size:
        raise ValueError(
            f"Short EEPROM read at 0x{offset:04X}: expected {size}, got {len(data)}"
        )
    return data


def _read_zone(path, zone, zone_offset):
    header = _read_exact_at(path, zone_offset, HEADER.size)
    version, wp_check, count = HEADER.unpack(header)
    if version not in UNIVERSAL_VERSIONS:
        raise ValueError(f"Unsupported EEPROM calibration version {version} in {zone}")
    if count <= 0 or count > MAX_ITEMS:
        raise ValueError(f"Invalid EEPROM calibration item count {count} in {zone}")

    raw_items = _read_exact_at(path, zone_offset + HEADER.size, count * ITEM.size)
    values = {}
    for index in range(count):
        item_id, value = ITEM.unpack_from(raw_items, index * ITEM.size)
        values[item_id] = value

    required = {
        DAC_CH1_GAIN,
        DAC_CH1_OFFSET,
        DAC_CH2_GAIN,
        DAC_CH2_OFFSET,
        ADC_CH1_GAIN_LV,
        ADC_CH1_OFFSET_LV,
        ADC_CH2_GAIN_LV,
        ADC_CH2_OFFSET_LV,
    }
    missing = required.difference(values)
    if missing:
        raise ValueError(f"Missing ADC/DAC EEPROM items in {zone}: {sorted(missing)}")

    result = BoardCalibration(
        version=version,
        write_protect_check=wp_check,
        zone=zone,
        dac_channel1=DacChannelCalibration(
            raw_gain=values[DAC_CH1_GAIN], raw_offset=values[DAC_CH1_OFFSET]
        ),
        dac_channel2=DacChannelCalibration(
            raw_gain=values[DAC_CH2_GAIN], raw_offset=values[DAC_CH2_OFFSET]
        ),
        adc_channel1_lv=AdcChannelCalibration(
            raw_gain=values[ADC_CH1_GAIN_LV],
            raw_offset=values[ADC_CH1_OFFSET_LV],
        ),
        adc_channel2_lv=AdcChannelCalibration(
            raw_gain=values[ADC_CH2_GAIN_LV],
            raw_offset=values[ADC_CH2_OFFSET_LV],
        ),
    )

    for channel in (result.dac_channel1, result.dac_channel2):
        if not 0.5 <= channel.gain <= 1.5:
            raise ValueError(f"Implausible DAC gain {channel.gain:.6f} in {zone}")
        channel.gain_fixed()
        channel.fpga_offset

    for channel in (result.adc_channel1_lv, result.adc_channel2_lv):
        if not 0.5 <= channel.gain <= 1.5:
            raise ValueError(f"Implausible ADC gain {channel.gain:.6f} in {zone}")
        channel.gain_fixed()
        channel.fpga_offset

    return result


def read_calibration(path=EEPROM_PATH):
    """Read the active User zone, falling back to Factory; never writes EEPROM."""
    errors = []
    for zone, offset in (
        ("user", USER_ZONE_OFFSET),
        ("factory", FACTORY_ZONE_OFFSET),
    ):
        try:
            return _read_zone(path, zone, offset)
        except (OSError, ValueError) as error:
            errors.append(f"{zone}: {error}")
    raise RuntimeError("Unable to read valid ADC/DAC calibration; " + "; ".join(errors))


def read_dac_calibration(path=EEPROM_PATH):
    """Backward-compatible alias for callers created before ADC calibration."""
    return read_calibration(path)


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Read and display Red Pitaya ADC/DAC EEPROM calibration (read-only)."
    )
    parser.add_argument("path", nargs="?", default=EEPROM_PATH)
    args = parser.parse_args()

    calibration = read_calibration(args.path)
    print(calibration)
    print(
        "FPGA Q13/stream values: "
        f"OUT1 gain={calibration.dac_channel1.gain_fixed(13)} "
        f"offset={calibration.dac_channel1.fpga_offset}, "
        f"OUT2 gain={calibration.dac_channel2.gain_fixed(13)} "
        f"offset={calibration.dac_channel2.fpga_offset}, "
        f"IN1-LV gain={calibration.adc_channel1_lv.gain_fixed(13)} "
        f"offset={calibration.adc_channel1_lv.fpga_offset}, "
        f"IN2-LV gain={calibration.adc_channel2_lv.gain_fixed(13)} "
        f"offset={calibration.adc_channel2_lv.fpga_offset}"
    )


if __name__ == "__main__":
    main()
