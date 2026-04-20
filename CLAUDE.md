# Flipper One

Flipper One is a portable Linux computer based on the Rockchip RK3576 SoC with an RP2350 co-processor for hardware control. This is the main working directory that contains all related repositories and tooling.

## Rules

- Never add `Co-Authored-By` lines to git commit messages.

## Development environment

Claude Code sessions run in two contexts:
- **Local macOS** — the developer's machine where source repos live
- **Remote FlipperOne device** — connected via SSH, files synced via rsync

At the start of a session, always determine which system you are running on. Read the MOTD file to get device info:
```
cat /etc/motd 2>/dev/null || run-parts /etc/update-motd.d/ 2>/dev/null
```
This shows board name, CPU serial, memory, build info, and git ref. If the command returns nothing, you are on the local macOS system.

## provision.sh

Script to provision a Flipper One device over LAN and sync files to it.

Usage:
```
./provision.sh            # auto-discover devices via mDNS
./provision.sh 10.0.0.1   # connect directly to a known IP/hostname
```

What it does:
1. Discovers devices via mDNS (`_flipper._tcp`) using `dns-sd -B` (streaming, results appear as devices are found). If only one device is found it is auto-selected.
2. Resolves the actual hostname via `dns-sd -L` (instance name may differ from hostname).
3. Removes stale SSH host keys and installs your public key via `ssh-copy-id`.
4. Asks to sync files — if yes, runs `rsync` to push the current folder to `user@device:~/f1`.
5. Stays running: press Enter to re-sync, Ctrl+C to quit.

Sync details:
- One-way: macOS (source of truth) → device. Deleting a file on the device and re-syncing restores it from Mac.
- Uses `rsync -rltz --delete` (no permission/owner sync — meaningless cross-platform).
- Excludes: `.git/`, `.gitignore`, `.DS_Store`, `.claude/`, `logs/`, `provision.sh`.
- SSH banner/MOTD suppressed via `-o LogLevel=error`.
- No external dependencies — uses only macOS built-in tools (`dns-sd`, `rsync`, `ssh`).

## Repositories

### flipper-linux-kernel
Customized Linux kernel for the RK3576. Includes MCU interconnect drivers for communication between the Linux CPU and RP2350 co-processor.

### linux-build-scripts
Build system that generates the Linux firmware running on FlipperOne devices. Shell scripts to build U-Boot, mainline/BSP kernels, root filesystem, and bootable SD/eMMC images. The MOTD, overlays, and system configs shipped on the device originate from this repo. Supports Docker and Dev Containers. Avahi mDNS discovery config is on the `zhovner/avahi-discover` branch.

### mcu-firmware
Firmware for the RP2350 co-processor (FreeRTOS + Pico SDK). Controls LCD display, buttons, touchpad, LEDs, and battery/power management. Communicates with the Linux CPU via SPI/I2C/UART.

### docs
Developer documentation sources published at https://docs.flipper.net/one via Archbee. Covers hardware specs, schematics, software architecture, and testing procedures.

### testing
Hardware validation test scripts. Temperature monitoring and system logging with interactive HTML reports (Plotly). Other test modules (power, CPU, GPU, network, disk) are placeholders.

