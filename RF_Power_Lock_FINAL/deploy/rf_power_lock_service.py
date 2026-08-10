#!/usr/bin/env python3
"""Load the RF Power Lock FPGA and provide a safe local control socket."""

from __future__ import annotations

import json
import os
import pwd
import signal
import socket
from pathlib import Path
from typing import Any, Dict

import pynq

from redpitaya_eeprom import read_calibration


SYSTEM_DIR = Path(__file__).resolve().parent
BITSTREAM = str(SYSTEM_DIR / "rf_power_lock.bit")
SOCKET_DIR = Path("/run/rf-power-lock")
SOCKET_PATH = SOCKET_DIR / "control.sock"
SOCKET_USER = "xilinx"
CALIBRATION_GAIN_FRAC_BITS = 13
GAIN_FORMAT_VERSION = 2
KP_FRAC_BITS = 10
KI_FRAC_BITS = 13
MIN_I16 = -(1 << 15)
MAX_I16 = (1 << 15) - 1
MAX_REQUEST_BYTES = 16 * 1024

GPIO_NAME = {
    "setpoint": "axi_gpio_0",
    "kp": "axi_gpio_1",
    "ki": "axi_gpio_2",
    "threshold": "axi_gpio_3",
    "dac_gain": "axi_gpio_4",
    "dac_offset": "axi_gpio_5",
    "adc_gain": "axi_gpio_6",
    "adc_offset": "axi_gpio_7",
}

running = True
overlay = None
calibration_summary: Dict[str, int] = {}


def _signed_to_u16(value: int) -> int:
    return value & 0xFFFF


def _u16_to_signed(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def _require_i16(value: Any, name: str) -> int:
    if type(value) is not int or not MIN_I16 <= value <= MAX_I16:
        raise ValueError(f"{name} must be an integer from {MIN_I16} to {MAX_I16}")
    return value


def _require_channel(value: Any) -> int:
    if type(value) is not int or value not in (1, 2):
        raise ValueError("channel must be 1 or 2")
    return value


def _require_gain_format(request: Dict[str, Any]) -> None:
    if request.get("gain_format_version") != GAIN_FORMAT_VERSION:
        raise ValueError(
            "outdated control client: reload rf_power_lock_control.py "
            f"(gain format version {GAIN_FORMAT_VERSION} required)"
        )


def _channel(gpio, channel: int):
    return gpio.channel1 if channel == 1 else gpio.channel2


def _write(name: str, channel: int, value: int) -> None:
    gpio = getattr(overlay, GPIO_NAME[name])
    _channel(gpio, channel).write(_signed_to_u16(value), 0xFFFF)


def _read(name: str, channel: int) -> int:
    gpio = getattr(overlay, GPIO_NAME[name])
    register_offset = 0x0 if channel == 1 else 0x8
    return _u16_to_signed(gpio.read(register_offset))


def _write_dual(name: str, channel1: int, channel2: int) -> None:
    _write(name, 1, channel1)
    _write(name, 2, channel2)


def load_safe_hardware() -> None:
    """Reload FPGA, clear both PI accumulators, and apply ADC/DAC calibration."""
    global overlay, calibration_summary

    calibration = read_calibration()
    pynq.PL.reset()
    overlay = pynq.Overlay(BITSTREAM)

    for name in ("setpoint", "kp", "ki", "threshold"):
        _write_dual(name, 0, 0)

    dac_gain_ch1 = calibration.dac_channel1.gain_fixed(CALIBRATION_GAIN_FRAC_BITS)
    dac_gain_ch2 = calibration.dac_channel2.gain_fixed(CALIBRATION_GAIN_FRAC_BITS)
    dac_offset_ch1 = calibration.dac_channel1.fpga_offset
    dac_offset_ch2 = calibration.dac_channel2.fpga_offset
    adc_gain_ch1 = calibration.adc_channel1_lv.gain_fixed(CALIBRATION_GAIN_FRAC_BITS)
    adc_gain_ch2 = calibration.adc_channel2_lv.gain_fixed(CALIBRATION_GAIN_FRAC_BITS)
    adc_offset_ch1 = calibration.adc_channel1_lv.fpga_offset
    adc_offset_ch2 = calibration.adc_channel2_lv.fpga_offset
    _write_dual("dac_gain", dac_gain_ch1, dac_gain_ch2)
    _write_dual("dac_offset", dac_offset_ch1, dac_offset_ch2)
    _write_dual("adc_gain", adc_gain_ch1, adc_gain_ch2)
    _write_dual("adc_offset", adc_offset_ch1, adc_offset_ch2)

    calibration_summary = {
        "zone": calibration.zone,
        "version": calibration.version,
        "out1_gain_q13": dac_gain_ch1,
        "out1_offset": dac_offset_ch1,
        "out2_gain_q13": dac_gain_ch2,
        "out2_offset": dac_offset_ch2,
        "in1_lv_gain_q13": adc_gain_ch1,
        "in1_lv_offset": adc_offset_ch1,
        "in2_lv_gain_q13": adc_gain_ch2,
        "in2_lv_offset": adc_offset_ch2,
    }


def controller_status() -> Dict[str, Any]:
    channels: Dict[str, Dict[str, int]] = {}
    for channel in (1, 2):
        channels[str(channel)] = {
            "setpoint": _read("setpoint", channel),
            "kp": _read("kp", channel),
            "ki": _read("ki", channel),
            "threshold": _read("threshold", channel),
        }
    return {
        "channels": channels,
        "calibration": calibration_summary,
        "gain_format": {
            "version": GAIN_FORMAT_VERSION,
            "kp_fractional_bits": KP_FRAC_BITS,
            "ki_fractional_bits": KI_FRAC_BITS,
        },
    }


def process_request(request: Dict[str, Any]) -> Dict[str, Any]:
    action = request.get("action")

    if action == "status":
        _require_gain_format(request)
        return controller_status()

    if action == "off":
        load_safe_hardware()
        return controller_status()

    if action == "apply":
        _require_gain_format(request)
        channel = _require_channel(request.get("channel"))
        setpoint = _require_i16(request.get("setpoint"), "setpoint")
        kp = _require_i16(request.get("kp"), "kp")
        ki = _require_i16(request.get("ki"), "ki")
        threshold = _require_i16(request.get("threshold"), "threshold")
        load_safe_hardware()
        _write("setpoint", channel, setpoint)
        _write("threshold", channel, threshold)
        _write("kp", channel, kp)
        _write("ki", channel, ki)
        return controller_status()

    if action == "gain":
        _require_gain_format(request)
        channel = _require_channel(request.get("channel"))
        kp = _require_i16(request.get("kp"), "kp")
        ki = _require_i16(request.get("ki"), "ki")
        _write("kp", channel, kp)
        _write("ki", channel, ki)
        return controller_status()

    if action == "setpoint":
        _require_gain_format(request)
        channel = _require_channel(request.get("channel"))
        setpoint = _require_i16(request.get("setpoint"), "setpoint")
        _write("setpoint", channel, setpoint)
        return controller_status()

    raise ValueError("unknown action; use status, off, apply, gain, or setpoint")


def stop_requested(signum, frame) -> None:
    global running
    running = False


def create_server() -> socket.socket:
    account = pwd.getpwnam(SOCKET_USER)
    SOCKET_DIR.mkdir(parents=True, exist_ok=True)
    os.chown(SOCKET_DIR, 0, account.pw_gid)
    os.chmod(SOCKET_DIR, 0o750)
    if SOCKET_PATH.exists() or SOCKET_PATH.is_socket():
        SOCKET_PATH.unlink()

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(SOCKET_PATH))
    os.chown(SOCKET_PATH, 0, account.pw_gid)
    os.chmod(SOCKET_PATH, 0o660)
    server.listen(4)
    server.settimeout(1.0)
    return server


def handle_client(client: socket.socket) -> None:
    try:
        payload = b""
        while b"\n" not in payload:
            block = client.recv(4096)
            if not block:
                break
            payload += block
            if len(payload) > MAX_REQUEST_BYTES:
                raise ValueError("request is too large")
        request = json.loads(payload.split(b"\n", 1)[0].decode("utf-8"))
        if not isinstance(request, dict):
            raise ValueError("request must be a JSON object")
        response = {"ok": True, "data": process_request(request)}
    except Exception as exc:
        response = {"ok": False, "error": str(exc)}
    client.sendall(json.dumps(response).encode("utf-8") + b"\n")


def main() -> None:
    global overlay

    signal.signal(signal.SIGTERM, stop_requested)
    signal.signal(signal.SIGINT, stop_requested)
    load_safe_hardware()
    server = create_server()

    print(
        "RF Power Lock ready: safe boot P=0, I=0; "
        f"control socket={SOCKET_PATH}; calibration={calibration_summary}",
        flush=True,
    )

    try:
        while running:
            try:
                client, _ = server.accept()
            except socket.timeout:
                continue
            with client:
                handle_client(client)
    finally:
        server.close()
        if SOCKET_PATH.exists() or SOCKET_PATH.is_socket():
            SOCKET_PATH.unlink()
        # Reloading is required to clear the persistent integral accumulator.
        try:
            load_safe_hardware()
        except Exception as exc:
            print(f"Safe shutdown reset failed: {exc}", flush=True)
        print("RF Power Lock service stopped with both channels reset", flush=True)


if __name__ == "__main__":
    main()
