#!/bin/bash
set -e

VENDOR="0bda"
PRODUCT="8157"
DRIVER_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BLACKLIST_FILE="/etc/modprobe.d/blacklist-cdc_ncm.conf"
UDEV_RULE_SRC="${DRIVER_DIR}/50-usb-realtek-net.rules"
UDEV_RULE_DST="/etc/udev/rules.d/50-usb-realtek-net.rules"

echo "=== RTL8157 / Wavlink 5G fix ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (e.g. via 'ssh proxmox' or 'su -')."
    exit 1
fi

# --- SSH self-detach ---
# During install we reload r8152, which momentarily disconnects every r8152 NIC.
# On a Proxmox host whose management bridge contains an r8152 NIC, the SSH
# session you're running this from will be killed before `modprobe r8152` can
# put the bridge port back. To survive that, re-launch ourselves detached from
# the controlling terminal and tail the log; an SSH drop now kills only the
# tail, not the script.
if [ -z "${FIX_WAVLINK_DETACHED:-}" ] && [ -n "${SSH_CONNECTION:-}" ]; then
    LOG=/var/log/fix-wavlink.log
    : > "$LOG"
    echo "SSH session detected — detaching from this terminal so an SSH blip can't kill the script."
    echo "  log:    $LOG"
    echo "  re-attach from any session with:  tail -F $LOG"
    echo
    FIX_WAVLINK_DETACHED=1 setsid nohup bash "$0" "$@" </dev/null >"$LOG" 2>&1 &
    CHILD=$!
    # Stream output. If SSH dies, this tail dies but the detached child keeps running.
    tail --pid="$CHILD" -F "$LOG" 2>/dev/null
    exit 0
fi

# --- Step 0: Verify kernel headers for the running kernel are present ---
KREL="$(uname -r)"
if [ ! -d "/lib/modules/${KREL}/build" ]; then
    echo "ERROR: kernel headers for ${KREL} are missing."
    if [[ "$KREL" == *-pve ]]; then
        if dpkg -l 2>/dev/null | grep -q '^ii  proxmox-kernel-helper'; then
            echo "       Install with: apt install proxmox-headers-${KREL}"
        else
            echo "       Install with: apt install pve-headers-${KREL}"
        fi
    else
        echo "       Install matching kernel-devel/linux-headers for ${KREL}."
    fi
    exit 1
fi

# --- Helpers: bridge snapshot/restore + version probes ---
# Why: rmmod r8152 destroys every r8152 netdev. The kernel auto-removes them
# from their bridges, and modprobe r8152 brings them back as standalone
# interfaces -- nothing re-attaches them. On a Proxmox host where vmbr0's only
# port is an r8152 NIC, that drops management connectivity until manual
# 'ifup vmbr0'. We snapshot before reload and re-attach after.

snapshot_r8152_bridges() {
    local sysif iface drv br bridge
    for sysif in /sys/class/net/*; do
        [ -e "$sysif/device" ] || continue
        iface=$(basename "$sysif")
        drv=$(readlink "$sysif/device/driver" 2>/dev/null | xargs -r basename)
        [ "$drv" = "r8152" ] || continue
        for br in /sys/class/net/*/brif/"$iface"; do
            [ -e "$br" ] || continue
            bridge=$(basename "$(dirname "$(dirname "$br")")")
            echo "$iface $bridge"
        done
    done
}

restore_r8152_bridges() {
    local snap="$1" iface bridge tries
    [ -z "$snap" ] && return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        iface="${line% *}"
        bridge="${line#* }"
        for tries in $(seq 1 30); do
            [ -e "/sys/class/net/$iface" ] && break
            sleep 1
        done
        if [ ! -e "/sys/class/net/$iface" ]; then
            echo "    WARN: $iface did not reappear; bridge $bridge will be empty"
            continue
        fi
        ip link set "$iface" up           || true
        ip link set "$iface" master "$bridge" || true
        echo "    re-attached $iface -> $bridge"
    done <<< "$snap"
}

reload_r8152_preserving_bridges() {
    local snap
    snap=$(snapshot_r8152_bridges)
    if [ -n "$snap" ]; then
        echo "    bridge memberships to restore after reload:"
        echo "$snap" | sed 's/^/      /'
    fi
    modprobe -r r8152 2>/dev/null || true
    modprobe r8152
    restore_r8152_bridges "$snap"
}

src_module_version()       { modinfo "$DRIVER_DIR/r8152.ko" 2>/dev/null | awk -F': +' '/^version:/{print $2; exit}'; }
installed_module_version() { modinfo r8152                  2>/dev/null | awk -F': +' '/^version:/{print $2; exit}'; }
running_module_version()   { cat /sys/module/r8152/version  2>/dev/null; }

# --- Step 1: Build the module (always; cheap and gives us the source version) ---
echo "[1] Building custom r8152 driver from $DRIVER_DIR..."
cd "$DRIVER_DIR"
make clean
make

SRC_VER="$(src_module_version)"
echo "    built r8152.ko version: ${SRC_VER:-unknown}"

# --- Idempotency: if everything is already current, skip the disruptive reload ---
INSTALLED_VER="$(installed_module_version)"
RUNNING_VER="$(running_module_version)"
SKIP_RELOAD=0
if [ -n "$SRC_VER" ] && [ "$SRC_VER" = "$INSTALLED_VER" ] && [ "$SRC_VER" = "$RUNNING_VER" ]; then
    echo "[2] Module ${SRC_VER} already installed and running — skipping rebuild-install reload."
    SKIP_RELOAD=1
else
    echo "[2] Installing module (running=${RUNNING_VER:-none}, installed=${INSTALLED_VER:-none}, built=${SRC_VER:-unknown})..."
    # Use the kernel build system directly (avoids the bundled Makefile's
    # 'rmmod r8152 then maybe install' ordering, which leaves the host with no
    # driver if the install step fails). Order: stage the new file, depmod,
    # then later we reload r8152 with bridge preservation.
    find "/lib/modules/${KREL}/kernel/drivers/net/usb/" -maxdepth 1 -name 'r8152.ko.*' -type f -delete 2>/dev/null || true
    make -C "/lib/modules/${KREL}/build" M="$DRIVER_DIR" INSTALL_MOD_DIR=kernel/drivers/net/usb modules_install
    depmod -a
fi

# --- Step 2: Blacklist cdc_ncm (idempotent: only regen initramfs if file changed) ---
BLACKLIST_CHANGED=0
if ! grep -q "blacklist cdc_ncm" "$BLACKLIST_FILE" 2>/dev/null; then
    echo "[3] Blacklisting cdc_ncm..."
    printf 'blacklist cdc_ncm\nblacklist cdc_mbim\n' > "$BLACKLIST_FILE"
    BLACKLIST_CHANGED=1
else
    echo "[3] cdc_ncm blacklist already present — nothing to do."
fi
if [ "$BLACKLIST_CHANGED" -eq 1 ]; then
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u
    elif command -v dracut >/dev/null 2>&1; then
        dracut --force
    else
        echo "    WARN: no update-initramfs or dracut found; blacklist may not persist across reboots"
    fi
fi

# --- Step 2b: Install udev rules (idempotent: only reload rules if file changed) ---
UDEV_CHANGED=0
if [ ! -f "$UDEV_RULE_SRC" ]; then
    echo "[3b] WARN: ${UDEV_RULE_SRC} not found; replug/reboot may not auto-set config 1"
elif [ ! -f "$UDEV_RULE_DST" ] || ! cmp -s "$UDEV_RULE_SRC" "$UDEV_RULE_DST"; then
    echo "[3b] Installing udev rules to ${UDEV_RULE_DST}..."
    install --group=root --owner=root --mode=0644 "$UDEV_RULE_SRC" "$UDEV_RULE_DST"
    UDEV_CHANGED=1
else
    echo "[3b] udev rules at ${UDEV_RULE_DST} already current — nothing to do."
fi
if [ "$UDEV_CHANGED" -eq 1 ]; then
    # Reload the rule DB (in-memory only — does NOT re-issue any device events).
    # We deliberately do NOT run 'udevadm trigger', because triggering 'add'
    # events on USB devices causes them to re-enumerate. That destroys the
    # netdev briefly, and if it's a bridge port (e.g. nic3 in vmbr0), the
    # bridge loses its only member -> host loses management connectivity.
    # The new rule will apply on the next genuine add event (replug/reboot).
    udevadm control --reload-rules 2>/dev/null || true
fi

# --- Step 3: Unload competing drivers ---
echo "[4] Unloading cdc_ncm/cdc_mbim if loaded..."
modprobe -r cdc_mbim 2>/dev/null || true
modprobe -r cdc_ncm  2>/dev/null || true

# --- Step 4: Find RTL8157 USB path ---
echo "[5] Locating RTL8157 on USB bus..."
USB_PATH=""
for dev in /sys/bus/usb/devices/*/; do
    # /sys/bus/usb/devices/* contains both real USB devices (have idVendor/idProduct)
    # and USB interfaces like 1-0:1.0 (do not). Skip anything without idVendor so
    # 'cat' failure doesn't trip set -e via the var=$(cat ...) assignment.
    [ -f "$dev/idVendor" ] || continue
    vid=$(cat "$dev/idVendor")
    pid=$(cat "$dev/idProduct" 2>/dev/null || true)
    if [ "$vid" = "$VENDOR" ] && [ "$pid" = "$PRODUCT" ]; then
        USB_PATH=$(basename "$dev")
        break
    fi
done

if [ -z "$USB_PATH" ]; then
    echo "RTL8157 (${VENDOR}:${PRODUCT}) not found on USB bus"
    exit 1
fi

CURRENT_CFG=$(cat /sys/bus/usb/devices/${USB_PATH}/bConfigurationValue 2>/dev/null)
if [ "$CURRENT_CFG" = "1" ]; then
    echo "[6] RTL8157 at $USB_PATH already at config 1 (Realtek proprietary) — leaving it alone."
else
    echo "[6] Switching RTL8157 at $USB_PATH from config ${CURRENT_CFG} to config 1..."
    echo 1 > /sys/bus/usb/devices/${USB_PATH}/bConfigurationValue
    echo "    Current config: $(cat /sys/bus/usb/devices/${USB_PATH}/bConfigurationValue)"
fi

echo "[7] Available interfaces on ${USB_PATH}:"
ls /sys/bus/usb/devices/ | grep "^${USB_PATH}:" || true

# --- Step 5: Reload r8152 (bridge-preserving) ---
if [ "$SKIP_RELOAD" -eq 1 ]; then
    echo "[8] Skipping r8152 reload (module already current)."
else
    echo "[8] Reloading r8152 (bridge-preserving)..."
    reload_r8152_preserving_bridges
fi

# --- Step 6: Wait for the interface bound to THIS USB path ---
echo "[9] Waiting for r8152 interface at USB path ${USB_PATH}..."
IFACE=""
for i in $(seq 1 15); do
    for iface in /sys/class/net/*; do
        [ -e "$iface/device" ] || continue
        devpath=$(readlink -f "$iface/device" 2>/dev/null)
        case "$devpath" in
            */${USB_PATH}:*)
                drv=$(readlink "$iface/device/driver" 2>/dev/null | xargs basename 2>/dev/null)
                if [ "$drv" = "r8152" ]; then
                    IFACE=$(basename "$iface")
                    break 2
                fi
                ;;
        esac
    done
    sleep 1
done

if [ -z "$IFACE" ]; then
    echo "[9] No r8152 interface found at ${USB_PATH} — trying manual bind..."
    BIND_IFACE="${USB_PATH}:2.0"
    echo "$BIND_IFACE" > /sys/bus/usb/drivers/r8152/bind 2>/dev/null || true
    sleep 2
    for iface in /sys/class/net/*; do
        [ -e "$iface/device" ] || continue
        devpath=$(readlink -f "$iface/device" 2>/dev/null)
        case "$devpath" in
            */${USB_PATH}:*)
                drv=$(readlink "$iface/device/driver" 2>/dev/null | xargs basename 2>/dev/null)
                [ "$drv" = "r8152" ] && IFACE=$(basename "$iface") && break
                ;;
        esac
    done
fi

if [ -z "$IFACE" ]; then
    echo "ERROR: r8152 interface for ${USB_PATH} not found after all attempts"
    exit 1
fi

echo "[10] r8152 interface found: $IFACE"

echo "[11] Speed check (waiting up to 10s for autoneg)..."
# Bring the iface up so autoneg can run. The bridge-attach in step [13] will do
# this again, but we need link state now to report a meaningful speed.
ip link set "$IFACE" up 2>/dev/null || true
for _ in $(seq 1 10); do
    if [ "$(cat /sys/class/net/${IFACE}/carrier 2>/dev/null)" = "1" ]; then
        break
    fi
    sleep 1
done
ethtool "$IFACE" 2>/dev/null | grep -E "Speed|Duplex|Link detected" \
    || echo "    ethtool not available (apt install ethtool) or link not up yet"

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

# --- Step 7: Put the 5G NIC into vmbr0 (5G in -> vmbr0 -> 2.5G out) ---
TARGET_BRIDGE="vmbr0"

# Detect existing bridge membership.
CURRENT_BRIDGE=""
for br in /sys/class/net/*/bridge; do
    [ -d "$br" ] || continue
    if [ -e "${br%/bridge}/brif/$IFACE" ]; then
        CURRENT_BRIDGE=$(basename "$(dirname "$br")")
        break
    fi
done

if [ -n "$CURRENT_BRIDGE" ]; then
    echo "[13] ${IFACE} is already a member of ${CURRENT_BRIDGE}."
    ip link set "$IFACE" up || true
elif [ -d "/sys/class/net/${TARGET_BRIDGE}/bridge" ]; then
    echo "[13] Attaching ${IFACE} to ${TARGET_BRIDGE} (runtime only)..."
    ip link set "$IFACE" up
    ip link set "$IFACE" master "$TARGET_BRIDGE"
    echo "    ${IFACE} now in ${TARGET_BRIDGE}: $(ls /sys/class/net/${TARGET_BRIDGE}/brif/ | tr '\n' ' ')"
else
    echo "[13] Bridge ${TARGET_BRIDGE} not found — bringing ${IFACE} up standalone."
    ip link set "$IFACE" up
fi

# --- Persistence hint ---
INTERFACES_FILE="/etc/network/interfaces"
if [ -f "$INTERFACES_FILE" ] && ! grep -qE "^\s*bridge-ports\b.*\b${IFACE}\b" "$INTERFACES_FILE"; then
    cat <<EOF

--- Persist across reboot ---
The runtime attach above is gone after a reboot. To make it permanent on Proxmox,
edit ${INTERFACES_FILE} so the vmbr0 stanza looks like this:

    auto ${IFACE}
    iface ${IFACE} inet manual

    auto ${TARGET_BRIDGE}
    iface ${TARGET_BRIDGE} inet static
        address  <your host IP>/<prefix>
        gateway  <your gateway>
        bridge-ports ${IFACE} nic3
        bridge-stp off
        bridge-fd 0

Then apply with:  ifreload -a

(Adjust 'nic3' / address / gateway to match your existing vmbr0 stanza.)
EOF
fi

echo ""
FINAL_SPEED=$(ethtool "${IFACE}" 2>/dev/null | awk -F': +' '/Speed:/ {print $2}')
echo "=== Done. ${IFACE} is on the patched r8152 at ${FINAL_SPEED:-unknown}. ==="
