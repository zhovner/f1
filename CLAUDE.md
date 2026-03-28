# Flipper One

Flipper One is a portable Linux computer based on the Rockchip RK3576 SoC with an RP2350 co-processor for hardware control. This is the main working directory that contains all related repositories and tooling.

## provision.sh

Script to start a development session on a Flipper One device over LAN:
1. Discovers devices via mDNS (`_flipper._tcp`)
2. Shows device list (IP, serial, hostname) for selection
3. Removes stale SSH host keys and installs your public key
4. Auto-commits git-tracked files before sync
5. Starts fswatch file monitor logging to `./logs/fswatch.log`
6. Starts mutagen two-way sync with the device (terminates on Ctrl+C)

## Repositories

### flipper-linux-kernel
Customized Linux kernel for the RK3576. Includes MCU interconnect drivers for communication between the Linux CPU and RP2350 co-processor.

### flipperone-linux-build-scripts
Build automation for complete Linux disk images. Shell scripts to build U-Boot, mainline/BSP kernels, root filesystem, and bootable SD/eMMC images. Supports Docker and Dev Containers. Avahi mDNS discovery config is on the `zhovner/avahi-discover` branch.

### flipperone-mcu-firmware
Firmware for the RP2350 co-processor (FreeRTOS + Pico SDK). Controls LCD display, buttons, touchpad, LEDs, and battery/power management. Communicates with the Linux CPU via SPI/I2C/UART.

### flipperone-docs
Developer documentation sources published at https://docs.flipper.net/one via Archbee. Covers hardware specs, schematics, software architecture, and testing procedures.

### flipperone-testing
Hardware validation test scripts. Temperature monitoring and system logging with interactive HTML reports (Plotly). Other test modules (power, CPU, GPU, network, disk) are placeholders.

### cog
WPE WebKit browser launcher for embedded/fullscreen web apps. Provides `libcogcore`, the `cog` launcher, and `cogctl` D-Bus control utility. Used as the kiosk browser on Flipper One's LCD display.
