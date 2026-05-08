# Wavlink RTL8157 5G Fix (Linux)

Fixes the Wavlink USB 10/100/1G/2.5G/5G LAN adapter (Realtek RTL8157, `0bda:8157`) failing to negotiate 5 Gbps on Linux.

## The problem

By default, the kernel binds `cdc_ncm` to the RTL8157, which is generic and caps the link at 1 Gbps. The dongle also ships in a CDC USB configuration — it has to be switched to Realtek's proprietary config (`bConfigurationValue=1`) before the `r8152` driver can take over and negotiate 5 Gbps.

On kernel ≥ 7.0 the inbox `r8152` also fails to build due to a missing `linux/hex.h` include. The driver source in this folder includes that fix and other compat shims (Realtek `r8152` v2.21.4 + patches).

## Single-command install

From inside this folder:

```bash
sudo bash ./fix-wavlink.sh
```

Then connect the new interface:

```bash
sudo nmcli device connect <iface>   # e.g. enp0s20f0u2
```

That's it. The fix is persistent across reboots — the blacklist file and installed module survive, and the device re-enters config 1 on replug via the udev rules.

## Prerequisites

- Kernel headers for the running kernel.
  - **Fedora:** `sudo dnf install kernel-devel-$(uname -r) kernel-headers`
  - **Ubuntu/Debian:** `sudo apt install linux-headers-$(uname -r) build-essential`
- `ethtool` (only needed for the speed-check step).

If Secure Boot is enabled, the unsigned module will be rejected by the kernel. Either disable Secure Boot or sign the module with your own MOK.

## What the script does

1. **Builds and installs the patched `r8152`** from this folder against `/lib/modules/$(uname -r)/build`.
2. **Blacklists `cdc_ncm` and `cdc_mbim`** in `/etc/modprobe.d/blacklist-cdc_ncm.conf` and rebuilds the initramfs (`dracut --force` on Fedora, `update-initramfs -u` on Debian/Ubuntu).
3. **Unloads the competing CDC drivers** from the running kernel.
4. **Switches the RTL8157 USB configuration** to `1` (Realtek proprietary). This is the key step that unlocks 5 Gbps.
5. **Loads `r8152`** and waits for the network interface to appear; falls back to a manual `bind` via sysfs if needed.
6. **Verifies** the result with `ethtool` and `lsusb -t`.

## Files

| Path | Purpose |
|---|---|
| `fix-wavlink.sh` | One-shot install/fix script |
| `r8152.c`, `compatibility.h`, `Makefile` | Patched Realtek `r8152` v2.21.4 source |
| `50-usb-realtek-net.rules` | udev rules — keep RTL8157 in config 1 across replug/reboot |
| `ReadMe.txt` | Upstream Realtek vendor notes (advertise codes, S5 WOL, etc.) |
| `/etc/modprobe.d/blacklist-cdc_ncm.conf` | Installed by the script — blocks `cdc_ncm` on boot |

## Verifying the link

```bash
ethtool <iface> | grep Speed       # expect: Speed: 5000Mb/s
ip -br link show <iface>           # expect: state UP
lsusb -t                           # expect the 8157 at 10000M (USB 3.2 Gen 2)
```

## Re-running

If a kernel update replaces the module, just re-run `sudo bash ./fix-wavlink.sh` — the script is idempotent.

## Tested on

- **Fedora 44**, kernel `6.19.14-300.fc44.x86_64`
- Device: `0bda:8157` — Realtek USB 10/100/1G/2.5G/5G LAN (Wavlink)
- Driver: `r8152` v2.21.4 (2025/10/28) + patches
