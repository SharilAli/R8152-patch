# Wavlink RTL8157 5G Fix (Linux 7.0+)

Fixes the Wavlink USB 10/100/1G/2.5G/5G LAN adapter (Realtek RTL8157, `0bda:8157`) not achieving 5Gbps on Linux kernel 7.0+.

## The Problem

By default, Linux loads `cdc_ncm` for the RTL8157 instead of Realtek's own `r8152` driver. The `cdc_ncm` driver is generic and caps the link at 1Gbps. The RTL8157 also ships in a CDC configuration — it needs to be switched to Realtek's proprietary USB config (config 1) before `r8152` can take over and negotiate 5Gbps.

Additionally, the inbox `r8152` driver in kernel 7.0 is missing a `linux/hex.h` include guard, which causes a build failure. The custom driver in this repo patches that.

## One-command install

```bash
sudo bash ~/fix-wavlink.sh
```

## What the script does

**1. Builds the patched r8152 driver**
The inbox kernel driver has a missing `linux/hex.h` include on kernel >= 7.0.0. The repo at `~/realtek-r8152-linux` patches this and backports compatibility shims. The script runs `make && sudo make install` from that directory.

**2. Blacklists cdc_ncm**
Writes `/etc/modprobe.d/blacklist-cdc_ncm.conf` to prevent `cdc_ncm` and `cdc_mbim` from grabbing the device on boot, then runs `update-initramfs` to make it permanent.

**3. Unloads competing drivers**
Removes `cdc_ncm` and `cdc_mbim` from the running kernel without rebooting.

**4. Switches the RTL8157 USB configuration**
Writes `1` to `/sys/bus/usb/devices/<path>/bConfigurationValue`. This tells the device to switch from CDC mode (config 2, generic, 1Gbps) to Realtek proprietary mode (config 1, enables 5Gbps negotiation). This is the key step.

**5. Loads r8152 and brings up the interface**
Loads the freshly built driver, waits for the network interface to appear, and falls back to a manual bind via `/sys/bus/usb/drivers/r8152/bind` if needed.

**6. Verifies the result**
Runs `ethtool` to confirm speed modes and `lsusb -t` to confirm the USB link is operating at 10000M (USB 3.2 Gen 2).

## Files

| Path | Purpose |
|---|---|
| `~/realtek-r8152-linux/` | Patched r8152 driver source |
| `~/fix-wavlink.sh` | Combined fix script |
| `/etc/modprobe.d/blacklist-cdc_ncm.conf` | Prevents cdc_ncm from loading on boot |

## After running

Connect the interface with NetworkManager:
```bash
sudo nmcli device connect <interface>   # e.g. enx00e04c680144
```

The fix survives reboots — the blacklist and installed driver module are persistent. If a kernel update replaces the inbox driver, re-run the script.

## Tested on

- Kernel: `7.0.0-15-generic`
- Device: `0bda:8157` — Realtek USB 10/100/1G/2.5G/5G LAN (Wavlink)
- Driver: `realtek-r8152-linux` v2.21.4 + patches