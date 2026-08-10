#!/usr/bin/env python3
"""User control client for the RF Power Lock FPGA service.

The real-time PI calculation runs in the FPGA.  The root service owns the
hardware; this small client safely sends setpoint and gain changes to it.
"""

from __future__ import annotations

import argparse
import json
import socket
import time
from typing import Any, Dict


SOCKET_PATH = "/run/rf-power-lock/control.sock"
GAIN_FORMAT_VERSION = 2
KP_FRAC_BITS = 10
KI_FRAC_BITS = 13
KP_SCALE = 1 << KP_FRAC_BITS
KI_SCALE = 1 << KI_FRAC_BITS
# The physical IN1/IN2 jumpers are configured for LV mode (+/-1 V).
ADC_FULL_SCALE_VOLTS = 1.0
MIN_I16 = -(1 << 15)
MAX_I16 = (1 << 15) - 1


def _validate_channel(channel: int) -> None:
    if channel not in (1, 2):
        raise ValueError("channel must be 1 or 2")


def _validate_i16(value: int, name: str) -> int:
    if not MIN_I16 <= value <= MAX_I16:
        raise ValueError(f"{name} must be between {MIN_I16} and {MAX_I16}")
    return value


def volts_to_counts(volts: float) -> int:
    """Convert voltage to the FPGA ADC count for the +/-1 V LV range."""
    if not -ADC_FULL_SCALE_VOLTS <= volts < ADC_FULL_SCALE_VOLTS:
        raise ValueError(
            f"voltage must be at least -{ADC_FULL_SCALE_VOLTS:.1f} V "
            f"and less than +{ADC_FULL_SCALE_VOLTS:.1f} V"
        )
    return _validate_i16(
        round(volts / ADC_FULL_SCALE_VOLTS * (1 << 15)), "ADC count"
    )


def counts_to_volts(counts: int) -> float:
    return (
        _validate_i16(int(counts), "ADC count")
        / float(1 << 15)
        * ADC_FULL_SCALE_VOLTS
    )


def kp_to_fixed(gain: float) -> int:
    """Encode Kp as signed Q6.10 (-32 to just under +32)."""
    value = round(float(gain) * KP_SCALE)
    return _validate_i16(value, "Kp")


def ki_to_fixed(gain: float) -> int:
    """Encode Ki as signed Q3.13 (-4 to just under +4)."""
    value = round(float(gain) * KI_SCALE)
    return _validate_i16(value, "Ki")


def fixed_to_kp(value: int) -> float:
    return _validate_i16(int(value), "Q6.10 Kp") / float(KP_SCALE)


def fixed_to_ki(value: int) -> float:
    return _validate_i16(int(value), "Q3.13 Ki") / float(KI_SCALE)


def _request(payload: Dict[str, Any]) -> Dict[str, Any]:
    payload = dict(payload)
    payload["gain_format_version"] = GAIN_FORMAT_VERSION
    request = json.dumps(payload).encode("utf-8") + b"\n"
    deadline = time.monotonic() + 20.0
    while True:
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(20.0)
            client.connect(SOCKET_PATH)
            break
        except (FileNotFoundError, ConnectionRefusedError) as exc:
            client.close()
            if time.monotonic() >= deadline:
                raise RuntimeError(
                    "RF Power Lock service is not available. "
                    "Check rf-power-lock.service."
                ) from exc
            time.sleep(0.2)

    try:
        with client:
            client.sendall(request)
            response_bytes = b""
            while b"\n" not in response_bytes:
                block = client.recv(4096)
                if not block:
                    break
                response_bytes += block
    except socket.timeout as exc:
        raise RuntimeError("RF Power Lock service response timed out") from exc

    if not response_bytes:
        raise RuntimeError("RF Power Lock service returned no response")
    response = json.loads(response_bytes.split(b"\n", 1)[0].decode("utf-8"))
    if not response.get("ok"):
        raise RuntimeError(response.get("error", "unknown service error"))
    return response["data"]


def _human_status(raw: Dict[str, Any]) -> Dict[int, Dict[str, float]]:
    result: Dict[int, Dict[str, float]] = {}
    for channel_text, values in raw["channels"].items():
        channel = int(channel_text)
        result[channel] = {
            "setpoint_volts": counts_to_volts(values["setpoint"]),
            "setpoint_counts": values["setpoint"],
            "kp": fixed_to_kp(values["kp"]),
            "kp_q10": values["kp"],
            "ki": fixed_to_ki(values["ki"]),
            "ki_q13": values["ki"],
            "threshold_volts": counts_to_volts(values["threshold"]),
            "threshold_counts": values["threshold"],
        }
    return result


def _print_status(raw: Dict[str, Any]) -> None:
    for channel, values in _human_status(raw).items():
        print(
            f"CH{channel}: setpoint={values['setpoint_volts']:.6f} V "
            f"({values['setpoint_counts']}), "
            f"Kp={values['kp']:.9f} ({values['kp_q10']} Q6.10), "
            f"Ki={values['ki']:.9f} ({values['ki_q13']}), "
            f"threshold={values['threshold_volts']:.6f} V "
            f"({values['threshold_counts']})"
        )
    calibration = raw.get("calibration", {})
    if calibration:
        print(
            "EEPROM calibration: "
            f"IN1-LV gain={calibration.get('in1_lv_gain_q13')} "
            f"offset={calibration.get('in1_lv_offset')}, "
            f"IN2-LV gain={calibration.get('in2_lv_gain_q13')} "
            f"offset={calibration.get('in2_lv_offset')}; "
            f"OUT1 gain={calibration.get('out1_gain_q13')} "
            f"offset={calibration.get('out1_offset')}, "
            f"OUT2 gain={calibration.get('out2_gain_q13')} "
            f"offset={calibration.get('out2_offset')}"
        )


def off() -> Dict[int, Dict[str, float]]:
    """Turn both channels off and clear the stored integral term."""
    raw = _request({"action": "off"})
    print("Feedback OFF: both channels reset, P=0, I=0, DAC command=0 V")
    return _human_status(raw)


def apply(
    channel: int,
    setpoint_volts: float,
    kp: float,
    ki: float = 0.0,
    threshold_volts: float = 0.0,
) -> Dict[int, Dict[str, float]]:
    """Reset safely, then start one channel with a complete PI configuration."""
    _validate_channel(channel)
    raw = _request(
        {
            "action": "apply",
            "channel": channel,
            "setpoint": volts_to_counts(setpoint_volts),
            "kp": kp_to_fixed(kp),
            "ki": ki_to_fixed(ki),
            "threshold": volts_to_counts(threshold_volts),
        }
    )
    _print_status(raw)
    return _human_status(raw)


def set_gains(channel: int, kp: float, ki: float = 0.0) -> Dict[int, Dict[str, float]]:
    """Change gains without clearing the existing integral memory."""
    _validate_channel(channel)
    raw = _request(
        {
            "action": "gain",
            "channel": channel,
            "kp": kp_to_fixed(kp),
            "ki": ki_to_fixed(ki),
        }
    )
    _print_status(raw)
    return _human_status(raw)


def set_setpoint(channel: int, setpoint_volts: float) -> Dict[int, Dict[str, float]]:
    """Change the target while feedback is running; this does not reset PI."""
    _validate_channel(channel)
    raw = _request(
        {
            "action": "setpoint",
            "channel": channel,
            "setpoint": volts_to_counts(setpoint_volts),
        }
    )
    _print_status(raw)
    return _human_status(raw)


def status(print_result: bool = True) -> Dict[int, Dict[str, float]]:
    """Read current settings through the privileged hardware service."""
    raw = _request({"action": "status"})
    if print_result:
        _print_status(raw)
    return _human_status(raw)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Set and inspect the Red Pitaya RF Power Lock controller."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status", help="show current settings")
    subparsers.add_parser("off", help="reset both channels and turn feedback off")

    apply_parser = subparsers.add_parser(
        "apply", help="reset safely and start feedback on one channel"
    )
    apply_parser.add_argument("--channel", type=int, choices=(1, 2), default=1)
    apply_parser.add_argument("--setpoint-v", type=float, required=True)
    apply_parser.add_argument("--kp", type=float, required=True)
    apply_parser.add_argument("--ki", type=float, default=0.0)
    apply_parser.add_argument("--threshold-v", type=float, default=0.0)

    gain_parser = subparsers.add_parser(
        "gain", help="change P/I gains without clearing the integral memory"
    )
    gain_parser.add_argument("--channel", type=int, choices=(1, 2), default=1)
    gain_parser.add_argument("--kp", type=float, required=True)
    gain_parser.add_argument("--ki", type=float, default=0.0)

    setpoint_parser = subparsers.add_parser(
        "setpoint", help="change the target without resetting feedback"
    )
    setpoint_parser.add_argument("--channel", type=int, choices=(1, 2), default=1)
    setpoint_parser.add_argument("--volts", type=float, required=True)
    return parser


def main() -> None:
    args = _build_parser().parse_args()
    if args.command == "status":
        status()
    elif args.command == "off":
        off()
    elif args.command == "apply":
        apply(args.channel, args.setpoint_v, args.kp, args.ki, args.threshold_v)
    elif args.command == "gain":
        set_gains(args.channel, args.kp, args.ki)
    elif args.command == "setpoint":
        set_setpoint(args.channel, args.volts)


if __name__ == "__main__":
    main()
