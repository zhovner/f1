# Flipper One

Flipper One is a portable Linux computer based on the Rockchip RK3576 SoC with an RP2350 co-processor for hardware control. This is the main working directory that contains all related repositories and tooling.

## Development environment

Claude Code sessions run in two contexts:
- **Local macOS** — the developer's machine where source repos live
- **Remote FlipperOne device** — connected via SSH, with local repos mounted via mutagen sync

At the start of a session, always determine which system you are running on. Read the MOTD file to get device info:
```
cat /etc/motd 2>/dev/null || run-parts /etc/update-motd.d/ 2>/dev/null
```
This shows board name, CPU serial, memory, build info, and git ref. If the command returns nothing, you are on the local macOS system.

## provision.sh

Script to start a development session on a Flipper One device over LAN.

Usage:
```
./provision.sh            # auto-discover devices via mDNS
./provision.sh 10.0.0.1   # connect directly to a known IP
```

What it does:
1. Discovers devices via mDNS (`_flipper._tcp`), or uses the IP provided as argument
2. Shows device list (IP, serial, hostname) for selection
3. Removes stale SSH host keys and installs your public key
4. Auto-commits git-tracked files before sync
5. Starts fswatch file monitor logging to `./logs/fswatch.log`
6. Starts mutagen two-way sync with the device (terminates on Ctrl+C)

## Repositories

### flipper-linux-kernel
Customized Linux kernel for the RK3576. Includes MCU interconnect drivers for communication between the Linux CPU and RP2350 co-processor.

### flipperone-linux-build-scripts
Build system that generates the Linux firmware running on FlipperOne devices. Shell scripts to build U-Boot, mainline/BSP kernels, root filesystem, and bootable SD/eMMC images. The MOTD, overlays, and system configs shipped on the device originate from this repo. Supports Docker and Dev Containers. Avahi mDNS discovery config is on the `zhovner/avahi-discover` branch.

### flipperone-mcu-firmware
Firmware for the RP2350 co-processor (FreeRTOS + Pico SDK). Controls LCD display, buttons, touchpad, LEDs, and battery/power management. Communicates with the Linux CPU via SPI/I2C/UART.

### flipperone-docs
Developer documentation sources published at https://docs.flipper.net/one via Archbee. Covers hardware specs, schematics, software architecture, and testing procedures.

### flipperone-testing
Hardware validation test scripts. Temperature monitoring and system logging with interactive HTML reports (Plotly). Other test modules (power, CPU, GPU, network, disk) are placeholders.

