#!/usr/bin/env bash
# install.sh — x120x-dkms installation script
#
# Installs the SupTronics X120x UPS HAT kernel driver on Raspberry Pi.
# Run from the repository root:
#
#   sudo bash install.sh [OPTIONS]
#
# Options:
#   --battery-mah N        Total battery pack capacity in mAh (default: 1000)
#                          Example: 4x 5000mAh cells = 20000
#   --charge-mode MODE     Initial charge mode: fast or longlife (default: fast)
#                          longlife limits charging to 75-80% to extend battery life
#                          Can be changed at any time via sysfs; persisted across reboots
#   --board VARIANT        Board variant (default: x120x).
#                          Supported: x120x, x728v2, x728v1, x708, x729
#                          Variants other than x120x are EXPERIMENTAL (untested).
#   --skip-eeprom          Do not modify Raspberry Pi bootloader EEPROM settings
#                          (POWER_OFF_ON_HALT, PSU_MAX_CURRENT).  You are then
#                          responsible for configuring them manually — see README.
#
# Copyright (C) 2026 Edvard Fielding <mor-lock@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLD='\033[1m'
RST='\033[0m'

info()  { echo -e "${BLD}[x120x]${RST} $*"; }
ok()    { echo -e "${GRN}[x120x]${RST} $*"; }
warn()  { echo -e "${YLW}[x120x] WARNING:${RST} $*"; }
die()   { echo -e "${RED}[x120x] ERROR:${RST} $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run with sudo: sudo bash install.sh"
}

# -------------------------------------------------------------------------
# Temp-file cleanup
#
# Paths pushed here are removed on exit, so a kill mid-run cannot leak
# them.  Individual steps also rm on their normal paths; this is the
# backstop.
# -------------------------------------------------------------------------

X120X_CLEANUP=()
_x120x_cleanup() {
    [ "${#X120X_CLEANUP[@]}" -eq 0 ] || rm -rf -- "${X120X_CLEANUP[@]}" 2>/dev/null || true
}
trap _x120x_cleanup EXIT

# -------------------------------------------------------------------------
# INI block helper
#
# Append a marker-wrapped block of lines under a named section in an INI
# file.  systemd-style INI honours the LAST matching key for any given
# section, so appending our block at the bottom of [Login] / [UPower]
# overrides any prior setting without touching what's already there.
#
# Marker convention:
#   # >>> x120x-dkms: <tag> (do not edit) >>>
#   <content>
#   # <<< x120x-dkms: <tag> <<<
#
# The uninstaller deletes everything between matching markers; lines
# outside the markers are never touched, so users who set their own
# values are left alone.
#
# Usage: install_ini_block FILE SECTION TAG LINE [LINE ...]
#   FILE     — path to the INI file (must exist)
#   SECTION  — section name without brackets (e.g. "Login")
#   TAG      — short identifier used in the marker comment
#   LINE...  — one or more lines to write inside the block
# -------------------------------------------------------------------------

X120X_MARKER_BEGIN_PREFIX="# >>> x120x-dkms:"
X120X_MARKER_END_PREFIX="# <<< x120x-dkms:"

install_ini_block() {
    local file="$1" section="$2" tag="$3"
    shift 3

    [ -f "${file}" ] || { warn "${file} not found — skipping ${tag}"; return 0; }

    local marker_begin="${X120X_MARKER_BEGIN_PREFIX} ${tag} (do not edit) >>>"
    local marker_end="${X120X_MARKER_END_PREFIX} ${tag} <<<"

    # If our block is already present, remove it so we can rewrite it
    # idempotently with the current desired content.  We only ever touch
    # text between our own markers.
    if grep -qF "${marker_begin}" "${file}"; then
        # Delete from begin marker through end marker, inclusive.
        # Use a literal-string match via address-of-text by escaping for sed.
        local esc_begin esc_end
        esc_begin=$(printf '%s\n' "${marker_begin}" | sed 's/[][\/.^$*]/\\&/g')
        esc_end=$(printf '%s\n' "${marker_end}"   | sed 's/[][\/.^$*]/\\&/g')
        sed -i "/^${esc_begin}$/,/^${esc_end}$/d" "${file}"
    fi

    # Ensure the section header exists.  If not, append a blank line and
    # the header before our block so the keys land in the right section.
    if ! grep -qE "^\[${section}\][[:space:]]*$" "${file}"; then
        printf '\n[%s]\n' "${section}" >> "${file}"
    fi

    # Append the marker-wrapped block at end of file.  Since the section
    # header was either pre-existing further up OR just appended on the
    # line above, our block lands inside that section.  systemd reads
    # the LAST occurrence of any key in a section, so this overrides any
    # earlier setting without commenting anything out.
    {
        printf '\n%s\n' "${marker_begin}"
        local line
        for line in "$@"; do
            printf '%s\n' "${line}"
        done
        printf '%s\n' "${marker_end}"
    } >> "${file}"
}

# -------------------------------------------------------------------------
# Legacy cleanup helpers
#
# Older versions of install.sh wrote bare lines (no markers) into
# logind.conf and UPower.conf, and commented out any pre-existing
# HandleLowBattery= / CriticalPowerAction= / NoPollBatteries= line
# alongside.  A system that's been through an old install will still
# have those lines sitting around even after the new installer writes
# its marker block; without explicit cleanup they accumulate forever.
#
# These functions remove the exact strings the old installer emitted.
# Each pattern matches a single specific line — we never uncomment
# anything, because the old installer commented blindly and a user
# who had deliberately written `#HandleLowBattery=ignore` would be
# surprised by silent reactivation.
#
# The same cleanup is called from uninstall.sh; keeping it in a
# helper documents the contract that install.sh and uninstall.sh must
# agree on which lines belonged to the legacy installer.
# -------------------------------------------------------------------------

clean_legacy_logind() {
    local file="${1:-/etc/systemd/logind.conf}"
    [ -f "${file}" ] || return 0
    sed -i '/^# Added by x120x-dkms installer.*$/d'        "${file}"
    sed -i '/^# capacity_level=Critical.*$/d'              "${file}"
    sed -i '/^# To disable: set HandleLowBattery.*$/d'     "${file}"
    sed -i '/^HandleLowBattery=poweroff$/d'                "${file}"
}

clean_legacy_upower() {
    local file="${1:-/etc/UPower/UPower.conf}"
    [ -f "${file}" ] || return 0
    sed -i '/^# Added by x120x-dkms installer.*$/d'        "${file}"
    sed -i '/^# HybridSleep hangs on Raspberry Pi.*$/d'    "${file}"
    sed -i '/^CriticalPowerAction=PowerOff$/d'             "${file}"
    sed -i '/^# driver sends uevents.*$/d'                 "${file}"
    sed -i '/^NoPollBatteries=true$/d'                     "${file}"
}

# -------------------------------------------------------------------------
# Pi 5 bootloader EEPROM configuration
#
# POWER_OFF_ON_HALT=1 is required for the driver's core behaviour (clean
# power-off and automatic restart when mains returns); PSU_MAX_CURRENT=5000
# suppresses spurious low-power warnings.  Anyone installing this driver
# has an X120x UPS board, so both values are unconditionally correct — no
# negotiation with pre-existing values is needed.
#
# `rpi-eeprom-config --apply` only stages the update on the boot
# partition; the bootloader flashes it early during the next boot, so it
# lands with the same reboot this installer already requests.
#
# RPI_EEPROM_CONFIG and DT_MODEL_PATH are overridable so the test harness
# can inject mocks.
# -------------------------------------------------------------------------

configure_bootloader() {
    if [ "${SKIP_EEPROM}" -eq 1 ]; then
        info "Skipping bootloader EEPROM configuration (--skip-eeprom)"
        return 0
    fi

    # Only the Pi 5 needs these settings (the X1209 runs on Pi 3/4, where
    # the power-off GPIO pulse handles shutdown).  Read the NUL-terminated
    # device-tree model; skip on any other model, or if the file is absent
    # (a non-Pi build/test environment).
    local model=""
    if [ -r "${DT_MODEL_PATH}" ]; then
        model=$(tr -d '\0' < "${DT_MODEL_PATH}")
    fi
    case "${model}" in
        *"Raspberry Pi 5"*) ;;
        *)
            info "Bootloader configuration not required on this model"
            return 0
            ;;
    esac

    if ! command -v "${RPI_EEPROM_CONFIG}" >/dev/null 2>&1; then
        warn "rpi-eeprom-config not found — bootloader EEPROM not configured."
        warn "Set POWER_OFF_ON_HALT=1 and PSU_MAX_CURRENT=5000 manually; see"
        warn "the README (Required bootloader settings)."
        return 0
    fi

    local cur new
    cur=$(mktemp -t x120x-eeprom-cur.XXXXXX) \
        || { warn "mktemp failed — skipping bootloader EEPROM setup."; return 0; }
    new=$(mktemp -t x120x-eeprom-new.XXXXXX) \
        || { warn "mktemp failed — skipping bootloader EEPROM setup."; rm -f -- "${cur}"; return 0; }
    chmod 600 -- "${cur}" "${new}"
    X120X_CLEANUP+=("${cur}" "${new}")

    if ! "${RPI_EEPROM_CONFIG}" > "${cur}" 2>/dev/null; then
        warn "Could not read current bootloader config — skipping EEPROM setup."
        rm -f -- "${cur}" "${new}"
        return 0
    fi

    # A successful-but-empty read (e.g. the unprivileged VideoCore mailbox
    # path returned nothing) must never be turned into a two-line config
    # that wipes BOOT_ORDER and everything else.
    if [ ! -s "${cur}" ]; then
        warn "Current bootloader config read back empty — skipping EEPROM setup."
        rm -f -- "${cur}" "${new}"
        return 0
    fi

    if grep -qx 'POWER_OFF_ON_HALT=1' "${cur}" \
       && grep -qx 'PSU_MAX_CURRENT=5000' "${cur}"; then
        ok "Bootloader already configured (POWER_OFF_ON_HALT=1, PSU_MAX_CURRENT=5000)"
        rm -f -- "${cur}" "${new}"
        return 0
    fi

    # Drop any existing values for our two keys, then append the required
    # ones.  This rewrites a differing prior value (e.g. =0) with no
    # special case, and leaves every other key untouched.  `|| true` keeps
    # set -e happy if grep -v matches nothing.
    grep -vE '^(POWER_OFF_ON_HALT|PSU_MAX_CURRENT)=' "${cur}" > "${new}" || true
    printf 'POWER_OFF_ON_HALT=1\nPSU_MAX_CURRENT=5000\n' >> "${new}"

    if "${RPI_EEPROM_CONFIG}" --apply "${new}" >/dev/null 2>&1; then
        ok "Bootloader update staged (POWER_OFF_ON_HALT=1, PSU_MAX_CURRENT=5000) — takes effect at the reboot below."
    else
        warn "rpi-eeprom-config --apply failed — configure the bootloader"
        warn "manually; see the README (Required bootloader settings)."
    fi

    rm -f -- "${cur}" "${new}"
    return 0
}

# -------------------------------------------------------------------------
# Argument parsing
# -------------------------------------------------------------------------

OPT_MAH=""
OPT_CHARGE_MODE=""
OPT_BOARD=""
SKIP_EEPROM=0

while [ $# -gt 0 ]; do
    case "$1" in
        --battery-mah)
            case "${2:-}" in
                ''|*[!0-9]*)
                    die "--battery-mah requires a positive integer (got: ${2:-<missing>})"
                    ;;
            esac
            # Strip leading zeros for cleanliness; reject 0.
            OPT_MAH=$((10#$2))
            [ "${OPT_MAH}" -gt 0 ] \
                || die "--battery-mah must be greater than zero"
            shift 2
            ;;
        --charge-mode)
            case "$2" in
                fast|Fast|FAST)         OPT_CHARGE_MODE="fast" ;;
                longlife|LongLife|LONGLIFE|long-life|"Long Life") OPT_CHARGE_MODE="longlife" ;;
                *) die "Unknown charge mode: $2  (use fast or longlife)" ;;
            esac
            shift 2
            ;;
        --board)
            case "$2" in
                x120x|x728v2|x728v1|x708|x729) OPT_BOARD="$2" ;;
                *) die "Unknown board variant: $2  (use x120x, x728v2, x728v1, x708, x729)" ;;
            esac
            shift 2
            ;;
        --skip-eeprom)
            SKIP_EEPROM=1
            shift
            ;;
        --help|-h)
            echo "Usage: sudo bash install.sh [--battery-mah N] [--charge-mode fast|longlife] [--board x120x|x728v2|x728v1|x708|x729] [--skip-eeprom]"
            echo
            echo "  --skip-eeprom  Do not modify Raspberry Pi bootloader EEPROM settings"
            echo "                 (POWER_OFF_ON_HALT, PSU_MAX_CURRENT).  You are then"
            echo "                 responsible for configuring them manually — see README."
            exit 0
            ;;
        *)
            die "Unknown option: $1  (use --help for usage)"
            ;;
    esac
done

# -------------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------------

PKG_NAME="x120x"
PKG_VERSION="0.4.6"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# External command and device-tree model path — overridable for testing.
RPI_EEPROM_CONFIG="${RPI_EEPROM_CONFIG:-rpi-eeprom-config}"
DT_MODEL_PATH="${DT_MODEL_PATH:-/proc/device-tree/model}"

# Detect Pi model for correct boot path
if [ -f /boot/firmware/config.txt ]; then
    CONFIG_TXT="/boot/firmware/config.txt"
    OVERLAYS_DIR="/boot/firmware/overlays"
elif [ -f /boot/config.txt ]; then
    CONFIG_TXT="/boot/config.txt"
    OVERLAYS_DIR="/boot/overlays"
else
    die "Cannot find config.txt — is this a Raspberry Pi running Raspberry Pi OS?"
fi

# -------------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------------

require_root

info "x120x-dkms ${PKG_VERSION} installer"
info "Source: ${SRC_DIR}"
info "Config: ${CONFIG_TXT}"
echo

# Verify required files are present
for f in src/x120x.c src/Kbuild Makefile dkms.conf x120x-overlay.dts; do
    [ -f "${SRC_DIR}/${f}" ] || die "Missing file: ${f} — run this script from the repository root"
done

# -------------------------------------------------------------------------
# Step 1: Dependencies
# -------------------------------------------------------------------------

info "Step 1/10 — Installing dependencies..."
apt-get update \
    || warn "apt-get update failed — continuing with existing package index"
apt-get install -y dkms "linux-headers-$(uname -r)" \
    || die "apt-get install failed"
ok "Dependencies installed"

# -------------------------------------------------------------------------
# Step 2: Copy source to DKMS tree
# -------------------------------------------------------------------------

DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

info "Step 2/10 — Copying source to DKMS tree (${DKMS_SRC})..."
rm -rf "${DKMS_SRC}"
cp -r "${SRC_DIR}" "${DKMS_SRC}"
ok "Source copied"

# -------------------------------------------------------------------------
# Step 3: Build and install kernel module
# -------------------------------------------------------------------------

info "Step 3/10 — Building kernel module (this takes about a minute)..."

# Remove any previous installation of this version cleanly
if dkms status "${PKG_NAME}/${PKG_VERSION}" 2>/dev/null | grep -q .; then
    info "  Removing previous installation of ${PKG_NAME}/${PKG_VERSION}..."
    dkms remove "${PKG_NAME}/${PKG_VERSION}" --all 2>/dev/null || true
fi

# Remove any older installed versions of this driver that may have been
# left behind by previous installs (e.g. x120x/0.1.0, x120x/0.2.0).
# These show up as 'built' or 'installed' in dkms status but are no
# longer needed once the current version is in place.
while IFS= read -r old_ver; do
    info "  Removing leftover ${PKG_NAME}/${old_ver}..."
    dkms remove "${PKG_NAME}/${old_ver}" --all 2>/dev/null || true
    rm -rf "/usr/src/${PKG_NAME}-${old_ver}"
    ok "  Removed ${PKG_NAME}/${old_ver}"
done < <(dkms status "${PKG_NAME}" 2>/dev/null \
    | grep -oP "${PKG_NAME}/\K[0-9]+\.[0-9]+\.[0-9]+" \
    | grep -v "^${PKG_VERSION}$" \
    | sort -uV)

dkms add     "${PKG_NAME}/${PKG_VERSION}" \
    || die "dkms add failed"
dkms build   "${PKG_NAME}/${PKG_VERSION}" \
    || die "dkms build failed — check /var/lib/dkms/${PKG_NAME}/${PKG_VERSION}/build/make.log"
dkms install "${PKG_NAME}/${PKG_VERSION}" \
    || die "dkms install failed"

ok "Kernel module built and installed"

# -------------------------------------------------------------------------
# Step 4: Compile device tree overlay
# -------------------------------------------------------------------------

info "Step 4/10 — Compiling device tree overlay..."

if ! command -v dtc &>/dev/null; then
    info "  dtc not found, installing device-tree-compiler..."
    apt-get install -y device-tree-compiler \
        || die "Failed to install device-tree-compiler"
fi

# Compile the overlay in a root-owned tmpdir rather than the source
# directory.  If SRC_DIR happens to live on a path an unprivileged user
# can write to, compiling in-place would open a TOCTOU window between
# the dtc output and the cp into /boot/firmware/overlays/.  A private
# tmpdir created by root closes that window.
DTBO_TMPDIR=$(mktemp -d -t x120x-dtbo.XXXXXX) \
    || die "Failed to create temporary directory for overlay compile"
chmod 700 "${DTBO_TMPDIR}"
X120X_CLEANUP+=("${DTBO_TMPDIR}")

dtc -@ -I dts -O dtb \
    -o "${DTBO_TMPDIR}/x120x.dtbo" \
    "${SRC_DIR}/x120x-overlay.dts" \
    || die "Failed to compile device tree overlay"
ok "Overlay compiled"

# -------------------------------------------------------------------------
# Step 5: Write battery configuration to modprobe.d
# -------------------------------------------------------------------------

MODPROBE_CONF="/etc/modprobe.d/x120x.conf"
INPUT_MAH="${OPT_MAH:-1000}"

CHARGE_MODE_DEFAULT="${OPT_CHARGE_MODE:-fast}"
CONSERVATION_DEFAULT=0
[ "${CHARGE_MODE_DEFAULT}" = "longlife" ] && CONSERVATION_DEFAULT=1
BOARD_VARIANT="${OPT_BOARD:-x120x}"

# Warn if experimental board selected
if [ "${BOARD_VARIANT}" != "x120x" ]; then
    warn "Board variant ${BOARD_VARIANT} is EXPERIMENTAL and untested."
    warn "Validate correct operation before relying on this driver."
fi

# Long Life not supported on boards without charge control
if [ "${BOARD_VARIANT}" = "x728v1" ] || [ "${BOARD_VARIANT}" = "x708" ] || [ "${BOARD_VARIANT}" = "x729" ]; then
    if [ "${CHARGE_MODE_DEFAULT}" = "longlife" ]; then
        warn "--charge-mode longlife ignored: ${BOARD_VARIANT} has no charge control GPIO"
        CHARGE_MODE_DEFAULT="fast"
        CONSERVATION_DEFAULT=0
    fi
fi

info "Step 5/10 — Writing battery configuration to ${MODPROBE_CONF}..."
cat > "${MODPROBE_CONF}" << MODPROBE_EOF
# x120x driver configuration
# Generated by x120x-dkms installer — edit to change battery parameters.
#
# battery_mah     — total pack capacity in mAh
#                   (number of cells × per-cell capacity)
#
# After editing, reload the driver:
#   sudo rmmod x120x && sudo modprobe x120x
# Or simply reboot.

options x120x battery_mah=${INPUT_MAH} conservation_mode_default=${CONSERVATION_DEFAULT} board=${BOARD_VARIANT}
MODPROBE_EOF
ok "Battery configuration written"

# -------------------------------------------------------------------------
# Step 6: Install overlay  (renumbered)
# -------------------------------------------------------------------------

info "Step 6/10 — Installing device tree overlay to ${OVERLAYS_DIR}..."
cp "${DTBO_TMPDIR}/x120x.dtbo" "${OVERLAYS_DIR}/" \
    || die "Failed to copy overlay to ${OVERLAYS_DIR}"
ok "Overlay installed"

# -------------------------------------------------------------------------
# Step 7: Enable overlay in config.txt
# -------------------------------------------------------------------------

info "Step 7/10 — Enabling overlay in ${CONFIG_TXT}..."

if grep -q "dtoverlay=x120x" "${CONFIG_TXT}"; then
    ok "dtoverlay=x120x already present in ${CONFIG_TXT}"
else
    # Always append at the bottom. If the last section header in the
    # file is not [all], insert [all] first so the overlay applies to
    # all boards unconditionally (including Pi 5).
    LAST_SECTION=$(grep "^\[" "${CONFIG_TXT}" | tail -1)
    if [ "${LAST_SECTION}" != "[all]" ]; then
        printf '\n[all]\n' >> "${CONFIG_TXT}"
    fi
    printf '# SupTronics X120x UPS HAT driver\ndtoverlay=x120x\n'         >> "${CONFIG_TXT}"
    ok "Added dtoverlay=x120x to ${CONFIG_TXT}"
fi

# Add pull-up on GPIO6 (AC-present signal).
# The X1206 drives GPIO6 high when AC is present and actively pulls it
# low on AC loss.  Without a pull-up the pin can float low at boot
# before the hardware asserts the signal, causing the driver to falsely
# report ac_online=0 and trigger an unnecessary shutdown even with the
# charger connected.
if grep -q "^gpio=6=pu" "${CONFIG_TXT}"; then
    ok "gpio=6=pu already present in ${CONFIG_TXT}"
else
    printf 'gpio=6=pu\n' >> "${CONFIG_TXT}"
    ok "Added gpio=6=pu to ${CONFIG_TXT}"
fi

# -------------------------------------------------------------------------
# Step 8: Configure bootloader EEPROM (Pi 5 only)
# -------------------------------------------------------------------------

info "Step 8/10 — Configuring bootloader (Raspberry Pi 5)..."

configure_bootloader

# -------------------------------------------------------------------------
# Step 9: Configure low-battery shutdown via systemd-logind
# -------------------------------------------------------------------------

info "Step 9/10 — Configuring low-battery shutdown..."

# Strip any bare lines left over from a previous (pre-marker) install.
# On a fresh system these are no-ops.
clean_legacy_logind "${LOGIND_CONF:=/etc/systemd/logind.conf}"

# systemd-logind honours the last matching key in the [Login] section,
# so appending our block at the bottom overrides any earlier setting
# without commenting out lines we did not write.  See install_ini_block
# for the marker convention.
install_ini_block "${LOGIND_CONF}" "Login" "logind-low-battery" \
    "# Clean shutdown when battery reaches capacity_level=Critical" \
    "# (cell voltage ≤ 3.20 V on battery)." \
    "# To opt out, remove the dtoverlay=x120x line or set" \
    "# HandleLowBattery=ignore in a drop-in file under" \
    "# /etc/systemd/logind.conf.d/" \
    "HandleLowBattery=poweroff"
ok "HandleLowBattery=poweroff set in ${LOGIND_CONF}"

# UPower configuration:
#   CriticalPowerAction=PowerOff  — HybridSleep hangs on Raspberry Pi.
#   UsePercentageForPolicy=true   — Act on SoC %, not time-to-empty
#                                   (a UPS HAT reports no time estimate).
#   PercentageAction=2            — Power off at 2% SoC.  Debian/RPi-OS
#                                   ship PercentageAction=0, which would
#                                   only act at 0% — no margin above the
#                                   3.20 V floor.  GKeyFile honours the
#                                   last value, so this overrides the 0.
#   NoPollBatteries=true          — The driver sends uevents on all state
#                                   changes and on a 30s heartbeat.  UPower
#                                   polling the kernel independently causes
#                                   races that produce spurious 0%/unknown
#                                   entries in the history files and corrupt
#                                   gnome-power-statistics graphs.
UPOWER_CONF="/etc/UPower/UPower.conf"
if [ -f "${UPOWER_CONF}" ]; then
    # Strip legacy bare lines first (no-op on a fresh system).
    clean_legacy_upower "${UPOWER_CONF}"

    install_ini_block "${UPOWER_CONF}" "UPower" "upower-pi-tweaks" \
        "# HybridSleep hangs on Raspberry Pi — use PowerOff instead." \
        "CriticalPowerAction=PowerOff" \
        "# Act on battery percentage; a UPS HAT reports no time-to-empty." \
        "UsePercentageForPolicy=true" \
        "# Fire the PowerOff action at 2% SoC.  Debian/RPi-OS default" \
        "# PercentageAction=0 would only act at 0% — no margin above the" \
        "# 3.20 V floor.  UPower (GKeyFile) honours this last value." \
        "PercentageAction=2" \
        "# Driver sends uevents on all state changes; polling causes" \
        "# races that produce spurious 0%/unknown history entries." \
        "NoPollBatteries=true"
    ok "UPower tweaks installed in ${UPOWER_CONF}"
    systemctl restart upower 2>/dev/null || true
else
    warn "UPower config not found at ${UPOWER_CONF} — skipping UPower configuration"
fi

# -------------------------------------------------------------------------
# Step 10: Persist charge mode across reboots
# -------------------------------------------------------------------------

info "Step 10/10 — Installing charge mode persistence..."

PERSIST_SCRIPT="/usr/local/lib/x120x-persist-mode.sh"
UDEV_RULE="/etc/udev/rules.d/90-x120x-persist.rules"

mkdir -p /usr/local/lib

cat > "${PERSIST_SCRIPT}" << 'PERSIST_EOF'
#!/bin/sh
# x120x-persist-mode.sh — called by udev when charge_type changes.
# Writes conservation_mode_default to /etc/modprobe.d/x120x.conf so
# the charge mode (Fast or Long Life) survives reboots.
# CONF and the charge_type source default to the real paths but are
# overridable (X120X_CONF, X120X_CHARGE_TYPE_PATH) for testing.
CONF="${X120X_CONF:-/etc/modprobe.d/x120x.conf}"
CHARGE_TYPE_PATH="${X120X_CHARGE_TYPE_PATH:-/sys/class/power_supply/x120x-charger/charge_type}"
CHARGE_TYPE=$(cat "$CHARGE_TYPE_PATH" 2>/dev/null)
case "$CHARGE_TYPE" in
    "Long Life") MODE=1 ;;
    *)           MODE=0 ;;
esac
if [ -f "$CONF" ]; then
    if grep -q "conservation_mode_default" "$CONF"; then
        sed -i "s/conservation_mode_default=[0-9]*/conservation_mode_default=${MODE}/" "$CONF"
    else
        sed -i "s/^options x120x /options x120x conservation_mode_default=${MODE} /" "$CONF"
    fi
fi
PERSIST_EOF
chmod 755 "${PERSIST_SCRIPT}"
ok "Installed persistence script to ${PERSIST_SCRIPT}"

cat > "${UDEV_RULE}" << 'UDEV_EOF'
# Persist x120x charge mode to /etc/modprobe.d/x120x.conf on every change
ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="x120x-charger",     RUN+="/usr/local/lib/x120x-persist-mode.sh"
UDEV_EOF
udevadm control --reload-rules 2>/dev/null || true
ok "Installed charge mode persistence rule to ${UDEV_RULE}"

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------

echo
echo -e "${GRN}${BLD}Installation complete.${RST}"
echo
echo -e "  ${BLD}Next step:${RST} reboot your Raspberry Pi"
echo
echo -e "    sudo reboot"
echo
echo -e "  ${BLD}After reboot, verify with:${RST}"
echo
echo -e "    dmesg | grep x120x"
echo -e "    upower -i /org/freedesktop/UPower/devices/battery_x120x_battery"
echo
echo -e "  ${BLD}Battery configuration written to:${RST} ${MODPROBE_CONF}"
echo
echo -e "    battery_mah              = ${INPUT_MAH} mAh"
echo -e "    conservation_mode_default = ${CONSERVATION_DEFAULT}  (${CHARGE_MODE_DEFAULT} mode)"
echo -e "    board                    = ${BOARD_VARIANT}"
echo
echo -e "  To change these values, edit ${MODPROBE_CONF} and reboot."
echo
