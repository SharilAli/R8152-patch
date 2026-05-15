# Wavlink RTL8157 5G Fix (Linux)

Fixes the Wavlink USB 10/100/1G/2.5G/5G LAN adapter (Realtek RTL8157, `0bda:8157`) failing to negotiate 5 Gbps on Linux.

## The problem

By default, the kernel binds `cdc_ncm` to the RTL8157, which is generic and caps the link at 1 Gbps. The dongle also ships in a CDC USB configuration — it has to be switched to Realtek's proprietary config (`bConfigurationValue=1`) before the `r8152` driver can take over and negotiate 5 Gbps.

On kernel ≥ 7.0 the inbox `r8152` also fails to build due to a missing `linux/hex.h` include. The driver source in this folder includes that fix and other compat shims (Realtek `r8152` v2.21.4 + patches).

## Single-command install

Run the script as root from inside this folder:

```bash
bash ./fix-wavlink.sh
```

Then connect the new interface (NetworkManager-based distros only):

```bash
nmcli device connect <iface>   # e.g. enp0s20f0u2
```

On Proxmox there is no NetworkManager — bring the interface up directly or add
it to a bridge in `/etc/network/interfaces` (see the Proxmox section below).

That's it. The fix is persistent across reboots — the blacklist file and installed module survive, and the device re-enters config 1 on replug via the udev rules.

## Prerequisites

- Run as **root** (the script no longer wraps each command in `sudo`).
- Kernel headers for the running kernel.
  - **Fedora:** `dnf install kernel-devel-$(uname -r) kernel-headers`
  - **Ubuntu/Debian:** `apt install linux-headers-$(uname -r) build-essential`
  - **Proxmox VE 9 (kernel 6.8+):** `apt install proxmox-headers-$(uname -r) build-essential`
  - **Proxmox VE 8 (pve-kernel 6.2/6.5):** `apt install pve-headers-$(uname -r) build-essential`
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

If a kernel update replaces the module, just re-run `bash ./fix-wavlink.sh` as root — the script is idempotent.

## Proxmox VE notes

The script is hardened for headless Proxmox boxes where the only management
path is an r8152 NIC bridged into `vmbr0` — i.e. unloading `r8152` over SSH
will normally sever your connection until you have console access. Specific
safeguards:

- **Idempotent.** If the module version on disk and in memory both match what
  the source builds to, the disruptive `rmmod r8152 && modprobe r8152` step
  is skipped entirely. So re-running after the first success is a no-op.
- **SSH self-detach.** When invoked over SSH, the script re-execs itself
  detached from the controlling terminal via `setsid` + `nohup` and tails
  `/var/log/fix-wavlink.log`. If your SSH session drops mid-run (e.g. because
  `vmbr0`'s port just blipped), the script keeps running and finishes the
  reattach; you can `ssh` back in and `tail -F /var/log/fix-wavlink.log`.
- **Bridge-preserving reload.** Linux bridges do *not* auto-reattach a netdev
  when its driver reloads — they require an explicit `ip link set <iface>
  master <bridge>`. Before unloading `r8152`, the script snapshots bridge
  membership for every r8152 NIC and restores it after `modprobe r8152`.
- **No `udevadm trigger`.** Synthetic `add` events on USB devices cause
  `r8152` NICs to re-enumerate and drop out of their bridges. The script only
  ever calls `udevadm control --reload-rules` (in-memory rule reload).
- **Multiple Realtek NICs.** With both an `8156` (2.5G) and `8157` (5G)
  plugged in, interface detection is scoped to the 8157's USB path so it
  can't misreport the wrong NIC.
- **Kernel upgrades.** Proxmox replaces the kernel often. After every kernel
  upgrade, install the matching `proxmox-headers-<new-kernel>` package, then
  re-run the script. Pinning the working kernel via `proxmox-boot-tool kernel
  pin <kver>` is recommended if you want to defer the upgrade.

### Putting the new NIC into a bridge for VM / passthrough use

The script runtime-attaches the new interface to `vmbr0` if `vmbr0` exists
and the iface isn't already in a bridge, and prints a snippet to make this
persistent in `/etc/network/interfaces`. Example for a single-bridge layout
(5 G uplink and 2.5 G downlink on the same `vmbr0`):

```
auto nic1
iface nic1 inet manual

auto vmbr0
iface vmbr0 inet static
    address  192.168.1.11/24
    gateway  192.168.1.254
    bridge-ports nic1 nic3
    bridge-stp off
    bridge-fd 0
```

Apply with `ifreload -a` (ifupdown2; the default on Proxmox).

## Tested on

- **Fedora 44**, kernel `6.19.14-300.fc44.x86_64`
- **Proxmox VE 9.1**, kernel `6.2.16-5-pve` (root SSH workflow)
- Device: `0bda:8157` — Realtek USB 10/100/1G/2.5G/5G LAN (Wavlink)
- Driver: `r8152` v2.21.4 (2025/10/28) + patches
