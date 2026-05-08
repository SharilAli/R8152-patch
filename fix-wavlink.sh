#!/bin/bash
set -e

VENDOR="0bda"
PRODUCT="8157"
DRIVER_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BLACKLIST_FILE="/etc/modprobe.d/blacklist-cdc_ncm.conf"

echo "=== RTL8157 / Wavlink 5G fix ==="

# --- Step 1: Build and install custom r8152 driver ---
echo "[1] Building custom r8152 driver from $DRIVER_DIR..."
cd "$DRIVER_DIR"
make clean
make

echo "[2] Installing driver..."
sudo make install
sudo depmod -a

# --- Step 2: Blacklist cdc_ncm ---
echo "[3] Blacklisting cdc_ncm..."
if ! grep -q "blacklist cdc_ncm" "$BLACKLIST_FILE" 2>/dev/null; then
    echo -e "blacklist cdc_ncm\nblacklist cdc_mbim" | sudo tee "$BLACKLIST_FILE" > /dev/null
fi
if command -v dracut >/dev/null 2>&1; then
    sudo dracut --force
elif command -v update-initramfs >/dev/null 2>&1; then
    sudo update-initramfs -u
else
    echo "    WARN: no dracut or update-initramfs found; blacklist may not persist across reboots"
fi

# --- Step 3: Unload competing drivers ---
echo "[4] Unloading cdc_ncm/cdc_mbim if loaded..."
sudo modprobe -r cdc_mbim 2>/dev/null || true
sudo modprobe -r cdc_ncm  2>/dev/null || true

# --- Step 4: Find RTL8157 USB path ---
echo "[5] Locating RTL8157 on USB bus..."
USB_PATH=""
for dev in /sys/bus/usb/devices/*/; do
    vid=$(cat "$dev/idVendor" 2>/dev/null)
    pid=$(cat "$dev/idProduct" 2>/dev/null)
    if [ "$vid" = "$VENDOR" ] && [ "$pid" = "$PRODUCT" ]; then
        USB_PATH=$(basename "$dev")
        break
    fi
done

if [ -z "$USB_PATH" ]; then
    echo "RTL8157 (${VENDOR}:${PRODUCT}) not found on USB bus"
    exit 1
fi

echo "[6] Switching RTL8157 at $USB_PATH to Realtek proprietary config (config 1)..."
echo 1 | sudo tee /sys/bus/usb/devices/${USB_PATH}/bConfigurationValue > /dev/null
echo "    Current config: $(cat /sys/bus/usb/devices/${USB_PATH}/bConfigurationValue)"

echo "[7] Available interfaces on ${USB_PATH}:"
ls /sys/bus/usb/devices/ | grep "^${USB_PATH}:" || true

# --- Step 5: Load r8152 ---
echo "[8] Loading r8152..."
lsmod | grep -q r8152 || sudo modprobe r8152

# --- Step 6: Wait for interface ---
echo "[9] Waiting for r8152 interface..."
IFACE=""
for i in $(seq 1 15); do
    IFACE=$(ls /sys/class/net/ | while read iface; do
        driver=$(readlink /sys/class/net/$iface/device/driver 2>/dev/null | xargs basename 2>/dev/null)
        if [ "$driver" = "r8152" ]; then
            echo "$iface"
            break
        fi
    done | head -1)
    [ -n "$IFACE" ] && break
    sleep 1
done

if [ -z "$IFACE" ]; then
    echo "[9] No r8152 interface found — trying manual bind..."
    BIND_IFACE="${USB_PATH}:2.0"
    echo "$BIND_IFACE" | sudo tee /sys/bus/usb/drivers/r8152/bind > /dev/null 2>&1 || true
    sleep 2
    IFACE=$(ls /sys/class/net/ | while read iface; do
        driver=$(readlink /sys/class/net/$iface/device/driver 2>/dev/null | xargs basename 2>/dev/null)
        [ "$driver" = "r8152" ] && echo "$iface" && break
    done | head -1)
fi

if [ -z "$IFACE" ]; then
    echo "ERROR: r8152 interface not found after all attempts"
    exit 1
fi

echo "[10] r8152 interface found: $IFACE"

echo "[11] Speed check:"
ethtool "$IFACE" 2>/dev/null || echo "    ethtool not available"

echo "[12] USB driver state:"
USB_BUSNUM=$(cat /sys/bus/usb/devices/${USB_PATH}/busnum 2>/dev/null)
if [ -n "$USB_BUSNUM" ]; then
    lsusb -t 2>/dev/null | awk -v bus="$(printf 'Bus %02d' "$USB_BUSNUM")" '
        $0 ~ bus {p=1; print; next}
        p && /^\/:/ {p=0}
        p {print}
    '
else
    lsusb -t 2>/dev/null
fi

echo ""
echo "=== Done. Run: sudo nmcli device connect $IFACE ==="
