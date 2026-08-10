#!/usr/bin/env python3
"""Verify the deployed gain encoding and protocol without changing hardware."""

import json
import socket

import rf_power_lock_control as control


EXPECTED_KP = {
    -32.0: -32768,
    -16.0: -16384,
    16.0: 16384,
    31.999: 32767,
}

for gain, expected in EXPECTED_KP.items():
    actual = control.kp_to_fixed(gain)
    if actual != expected:
        raise SystemExit(f"Kp encoding failed for {gain}: {actual} != {expected}")

if control.ki_to_fixed(-1 / 8912) != -1:
    raise SystemExit("Ki Q3.13 encoding changed unexpectedly")

status = control._request({"action": "status"})
expected_format = {
    "version": 2,
    "kp_fractional_bits": 10,
    "ki_fractional_bits": 13,
}
if status.get("gain_format") != expected_format:
    raise SystemExit(
        f"deployed gain format mismatch: {status.get('gain_format')} != {expected_format}"
    )

for channel, values in status["channels"].items():
    if values["kp"] != 0 or values["ki"] != 0:
        raise SystemExit(f"channel {channel} is not safely off: {values}")

# A stale client must be rejected rather than having its Q3.13 Kp interpreted
# as Q6.10 (which would command eight times the intended proportional gain).
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(control.SOCKET_PATH)
    client.sendall(b'{"action":"status"}\n')
    response = json.loads(client.makefile("rb").readline().decode("utf-8"))
if response.get("ok") or "outdated control client" not in response.get("error", ""):
    raise SystemExit(f"stale-client protection failed: {response}")

print("GAIN_FORMAT_VERIFY=PASS")
print("Kp Q6.10 range: -32.0 to +31.9990234375")
print("Ki Q3.13 range: -4.0 to +3.9998779296875")
print("Both hardware channels remain at Kp=0, Ki=0")
