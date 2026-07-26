# Manual installation (step by step)

Part of [x120x-dkms](../README.md).

If you prefer to understand each step or the install script is not
suitable for your setup, follow these instructions.

#### Step 1 — Install dependencies

```bash
sudo apt update
sudo apt install dkms linux-headers-$(uname -r)
```

`dkms` manages the kernel module and rebuilds it automatically after
kernel updates.  `linux-headers-$(uname -r)` provides headers that
match the currently running kernel exactly, which is what DKMS needs
to compile the module.

> **Note:** older Raspberry Pi OS releases used a single metapackage
> `raspberrypi-kernel-headers`.  On Bookworm and later this metapackage
> may pull headers for a different kernel than the one you booted with,
> which causes DKMS builds to fail with `kernel headers ... cannot be
> found`.  Use the kernel-specific package shown above to avoid that.

#### Step 2 — Copy source to the DKMS tree

DKMS expects the source under `/usr/src/<name>-<version>/`:

Copy exactly what DKMS needs — `dkms.conf`, the `Makefile`, and
`src/` (avoid `cp -r .`, which would drag `.git` and the
documentation along):

```bash
sudo install -d /usr/src/x120x-0.4.7/src
sudo cp dkms.conf Makefile LICENSE /usr/src/x120x-0.4.7/
sudo cp src/x120x.c src/Kbuild /usr/src/x120x-0.4.7/src/
```

#### Step 3 — Build and install the kernel module

```bash
sudo dkms add x120x/0.4.7
sudo dkms build x120x/0.4.7
sudo dkms install x120x/0.4.7
```

You will see compiler output scroll past — this is normal.  The build
takes about a minute on a Raspberry Pi 5.  It should end with
`DKMS: install completed`.

Verify the module is installed:

```bash
dkms status
```

You should see `x120x/0.4.7, <kernel-version>, aarch64: installed`.

#### Step 4 — Compile the device tree overlay

The overlay tells the kernel how the board is wired (I²C address,
GPIO assignments) so the driver can claim the hardware correctly.

```bash
dtc -@ -I dts -O dtb -o x120x.dtbo x120x-overlay.dts
```

#### Step 5 — Install the overlay

```bash
# Raspberry Pi 5 (Raspberry Pi OS Bookworm):
sudo cp x120x.dtbo /boot/firmware/overlays/

# Raspberry Pi 4 and earlier:
sudo cp x120x.dtbo /boot/overlays/
```

#### Step 6 — Enable the overlay at boot

Open the boot configuration file:

```bash
# Raspberry Pi 5:
sudo nano /boot/firmware/config.txt

# Raspberry Pi 4 and earlier:
sudo nano /boot/config.txt
```

Add these lines at the end of the file:

```
[all]
dtoverlay=x120x
```

The `[all]` section header ensures the overlay is applied on all Pi
models.  Without it, any `[cm4]` or `[cm5]` conditional blocks earlier
in the file will prevent the overlay from loading on a Pi 5.

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X` in nano).

#### Step 7 — Configure the bootloader (Raspberry Pi 5 only)

On a Pi 5, set the two required bootloader EEPROM settings — see
[Required bootloader settings (Raspberry Pi 5)](../README.md#required-bootloader-settings-raspberry-pi-5) in the README for what they do
and why.  The non-interactive one-liner keeps every other setting:

```bash
conf=$(mktemp)
sudo rpi-eeprom-config > "$conf"
sed -i -e '/^POWER_OFF_ON_HALT=/d' -e '/^PSU_MAX_CURRENT=/d' "$conf"
printf 'POWER_OFF_ON_HALT=1\nPSU_MAX_CURRENT=5000\n' >> "$conf"
sudo rpi-eeprom-config --apply "$conf"
rm -f "$conf"
```

(Pi 4 and Pi 3 users skip this step.)

#### Step 8 — Configure low-battery shutdown

The driver reports `capacity_level=Critical` when SoC drops below 5%.
UPower escalates to `warning-level: action` at 2% SoC (the
`PercentageAction` threshold the installer sets), which triggers a clean
OS shutdown via logind.  To enable this, create a drop-in file:

```bash
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/90-x120x.conf << 'EOF'
[Login]
HandleLowBattery=poweroff
EOF
```

To disable this behaviour at any time, delete the file (or override
`HandleLowBattery=ignore` from a later drop-in) and restart
`systemd-logind`.

The install script does this automatically.

#### Step 9 — Reboot

```bash
sudo reboot
```

#### Step 10 — Verify

After the reboot, check that everything is working:

```bash
# Confirm the overlay loaded and the driver initialised
dmesg | grep x120x

# Check the three power_supply devices exist
ls /sys/class/power_supply/

# Read live values
cat /sys/class/power_supply/x120x-battery/capacity
cat /sys/class/power_supply/x120x-battery/voltage_now
cat /sys/class/power_supply/x120x-ac/online

# Full UPower view
upower -i /org/freedesktop/UPower/devices/battery_x120x_battery
```

Expected output from `dmesg | grep x120x`:

```
x120x: loading out-of-tree module taints kernel.
x120x 1-0036: MAX1704x at 0x36 version 0x000
x120x 1-0036: x120x UPS ready (battery=x120x-battery ac=x120x-ac charger=x120x-charger hwmon=hwmon3)
```

The "taints kernel" message is normal for any out-of-tree module.

`voltage_now` is reported in µV — divide by 1,000,000 for volts.
A healthy fully charged cell reads approximately 4,150,000 (4.15 V).
