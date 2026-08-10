#!/bin/bash
set -euo pipefail

STAGE="${1:?staging directory is required}"
TARGET="/home/xilinx/jupyter_notebooks/RF_Power_Lock"
OLD_SERVICE="dac-voltage-cycle.service"
NEW_SERVICE="rf-power-lock.service"

case "$STAGE" in
    /home/xilinx/rf_power_lock_upload_*) ;;
    *)
        echo "Refusing unexpected staging path: $STAGE" >&2
        exit 2
        ;;
esac

for file in \
    rf_power_lock_v1.bit \
    rf_power_lock_v1.hwh \
    rf_power_lock_service.py \
    rf_power_lock_control.py \
    redpitaya_eeprom.py \
    README.md \
    rf-power-lock.service; do
    test -f "$STAGE/$file"
done

systemctl stop "$NEW_SERVICE" || true
systemctl stop "$OLD_SERVICE" || true
mkdir -p "$TARGET/_system"

install -m 0644 "$STAGE/rf_power_lock_v1.bit" "$TARGET/_system/rf_power_lock.bit"
install -m 0644 "$STAGE/rf_power_lock_v1.hwh" "$TARGET/_system/rf_power_lock.hwh"
install -m 0755 "$STAGE/rf_power_lock_service.py" "$TARGET/_system/rf_power_lock_service.py"
install -m 0644 "$STAGE/redpitaya_eeprom.py" "$TARGET/_system/redpitaya_eeprom.py"
install -m 0755 "$STAGE/rf_power_lock_control.py" "$TARGET/rf_power_lock_control.py"
install -m 0644 "$STAGE/README.md" "$TARGET/README.md"
install -m 0644 "$STAGE/rf-power-lock.service" "/etc/systemd/system/$NEW_SERVICE"

systemctl daemon-reload
systemctl enable "$NEW_SERVICE"

if ! systemctl start "$NEW_SERVICE"; then
    systemctl disable "$NEW_SERVICE" || true
    systemctl start "$OLD_SERVICE" || true
    echo "RF Power Lock failed to start; the previous service was restarted" >&2
    exit 1
fi

sleep 4
if ! systemctl is-active --quiet "$NEW_SERVICE"; then
    systemctl stop "$NEW_SERVICE" || true
    systemctl disable "$NEW_SERVICE" || true
    systemctl start "$OLD_SERVICE" || true
    echo "RF Power Lock did not remain active; the previous service was restarted" >&2
    exit 1
fi

systemctl disable "$OLD_SERVICE"
echo "RF Power Lock activation completed"
