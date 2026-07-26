#!/usr/bin/env bash
# uninstall.sh — x120x-dkms uninstallation script
#
# Removes the SupTronics X120x UPS HAT kernel driver and all changes
# made by install.sh.  Run from the repository root:
#
#   sudo bash uninstall.sh
#
# What this script removes:
#   - DKMS kernel module (all installed kernel versions)
#   - DKMS source tree from /usr/src/
#   - Device tree overlay from /boot/firmware/overlays/ (or /boot/overlays/)
#   - dtoverlay=x120x and gpio=6=pu lines from config.txt
#   - /etc/modprobe.d/x120x.conf
#   - Charge mode persistence script and udev rule
#   - The logind drop-in /etc/systemd/logind.conf.d/90-x120x.conf
#   - x120x-dkms marker-wrapped blocks from /etc/UPower/UPower.conf and
#     — on systems installed before the drop-in existed — from
#     /etc/systemd/logind.conf (plus legacy bare lines written by
#     older versions of install.sh)
#
# What this script does NOT touch:
#   - The linux-headers-$(uname -r) and dkms packages (installed as
#     system dependencies; removing them may affect other software)
#   - Bootloader EEPROM settings (POWER_OFF_ON_HALT, PSU_MAX_CURRENT)
#   - Any config.txt lines not added by the installer
#   - Lines in logind.conf / UPower.conf outside our marker block.
#     In particular: previously commented-out keys like
#     `#HandleLowBattery=ignore` are NEVER uncommented — the installer
#     does not record whether a comment was its doing or the user's,
#     and silently uncommenting a deliberate user setting would be
#     surprising.  Review these files manually after uninstall if you
#     had pre-existing values.
#
# Copyright (C) 2026 Edvard Fielding <mor-lock@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

# -------------------------------------------------------------------------
# Shared helpers — output, require_root, INI marker constants, legacy
# cleanup.  lib/common.sh is the single source of truth for the contract
# install.sh and uninstall.sh must agree on.
# -------------------------------------------------------------------------

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh" \
    || { echo "[x120x] ERROR: cannot load lib/common.sh — run from a full checkout" >&2; exit 1; }

# remove_ini_block (lib/common.sh) deletes the marker-wrapped blocks
# written by install_ini_block; lines outside the markers are never
# touched, so users who set their own values are left alone.

# clean_legacy_logind / clean_legacy_upower (lib/common.sh) are called
# on removal, so bare lines left by a pre-marker installer are cleaned
# up even when no marker block exists.

# -------------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------------

PKG_NAME="x120x"

# Detect Pi model for correct boot path
if [ -f /boot/firmware/config.txt ]; then
    CONFIG_TXT="/boot/firmware/config.txt"
    OVERLAYS_DIR="/boot/firmware/overlays"
elif [ -f /boot/config.txt ]; then
    CONFIG_TXT="/boot/config.txt"
    OVERLAYS_DIR="/boot/overlays"
else
    warn "Cannot find config.txt — skipping overlay and config.txt cleanup"
    CONFIG_TXT=""
    OVERLAYS_DIR=""
fi

require_root

info "x120x-dkms uninstaller"
echo

# -------------------------------------------------------------------------
# Step 1: Unload module if currently loaded
# -------------------------------------------------------------------------

info "Step 1/7 — Unloading kernel module (if loaded)..."

if lsmod | grep -q "^x120x "; then
    rmmod x120x 2>/dev/null \
        || warn "Could not unload x120x module — it may be in use. Continuing anyway."
    ok "Module unloaded"
else
    ok "Module not currently loaded"
fi

# -------------------------------------------------------------------------
# Step 2: Remove DKMS module
# -------------------------------------------------------------------------

info "Step 2/7 — Removing DKMS kernel module..."

# Discover and remove every installed version of this driver — we don't
# know which version the user installed, and older versions may have
# been left behind by previous installs. install.sh uses the same
# pattern when cleaning up before a new install.
REMOVED_ANY=0
while IFS= read -r ver; do
    [ -z "${ver}" ] && continue
    info "  Removing ${PKG_NAME}/${ver}..."
    dkms remove "${PKG_NAME}/${ver}" --all 2>/dev/null \
        || warn "  dkms remove ${PKG_NAME}/${ver} reported an error — continuing"
    rm -rf "/usr/src/${PKG_NAME}-${ver}"
    ok "  Removed ${PKG_NAME}/${ver}"
    REMOVED_ANY=1
done < <(dkms status "${PKG_NAME}" 2>/dev/null \
    | grep -oP "${PKG_NAME}/\K[0-9]+\.[0-9]+\.[0-9]+" \
    | sort -uV)

if [ "${REMOVED_ANY}" -eq 0 ]; then
    ok "No DKMS installations found for ${PKG_NAME}"
fi

# Also clean up any orphaned source trees that dkms did not know about
for src in /usr/src/${PKG_NAME}-[0-9]*; do
    [ -d "${src}" ] || continue
    rm -rf "${src}"
    ok "Removed orphaned DKMS source tree: ${src}"
done

# -------------------------------------------------------------------------
# Step 3: Remove device tree overlay and config.txt entries
# -------------------------------------------------------------------------

info "Step 3/7 — Removing device tree overlay and config.txt entries..."

if [ -n "${OVERLAYS_DIR}" ] && [ -f "${OVERLAYS_DIR}/x120x.dtbo" ]; then
    rm -f "${OVERLAYS_DIR}/x120x.dtbo"
    ok "Removed ${OVERLAYS_DIR}/x120x.dtbo"
else
    ok "Overlay not found (already removed)"
fi

if [ -n "${CONFIG_TXT}" ] && [ -f "${CONFIG_TXT}" ]; then
    # Remove the dtoverlay=x120x line and its comment
    sed -i '/^# SupTronics X120x UPS HAT driver$/d' "${CONFIG_TXT}"
    sed -i '/^dtoverlay=x120x$/d'                   "${CONFIG_TXT}"

    # Remove the gpio=6=pu pull-up line added by the installer
    sed -i '/^gpio=6=pu$/d' "${CONFIG_TXT}"

    # Remove any [all] section header the installer may have added
    # (only safe to remove if the installer added it; we match the exact
    # pattern: a blank line followed by [all] at end of file, with our
    # comment following immediately after — too fragile to guess.
    # Instead just remove a trailing bare [all] if the two lines
    # immediately below it are now gone, leaving it orphaned.)
    # Safest approach: remove a [all] line only if it is now followed
    # immediately by another section header or end of file.
    perl -i -0pe 's/\n\[all\]\n(?=\[|\z)/\n/g' "${CONFIG_TXT}" 2>/dev/null || true

    ok "Removed x120x entries from ${CONFIG_TXT}"
else
    ok "config.txt not found — skipping"
fi

# -------------------------------------------------------------------------
# Step 4: Remove modprobe configuration
# -------------------------------------------------------------------------

info "Step 4/7 — Removing modprobe configuration..."

MODPROBE_CONF="/etc/modprobe.d/x120x.conf"
if [ -f "${MODPROBE_CONF}" ]; then
    rm -f "${MODPROBE_CONF}"
    ok "Removed ${MODPROBE_CONF}"
else
    ok "Modprobe config not found (already removed)"
fi

# -------------------------------------------------------------------------
# Step 5: Remove charge mode persistence
# -------------------------------------------------------------------------

info "Step 5/7 — Removing charge mode persistence..."

PERSIST_SCRIPT="/usr/local/lib/x120x-persist-mode.sh"
UDEV_RULE="/etc/udev/rules.d/90-x120x-persist.rules"

if [ -f "${PERSIST_SCRIPT}" ]; then
    rm -f "${PERSIST_SCRIPT}"
    ok "Removed ${PERSIST_SCRIPT}"
else
    ok "Persistence script not found (already removed)"
fi

if [ -f "${UDEV_RULE}" ]; then
    rm -f "${UDEV_RULE}"
    udevadm control --reload-rules 2>/dev/null || true
    ok "Removed ${UDEV_RULE}"
else
    ok "udev rule not found (already removed)"
fi

# -------------------------------------------------------------------------
# Step 6: Restore logind.conf
# -------------------------------------------------------------------------

info "Step 6/7 — Restoring logind configuration..."

# Current installs: low-battery shutdown lives in a drop-in file that
# is entirely ours — removal is a plain rm.  Remove the directory too
# if (and only if) it is empty afterwards.
LOGIND_DROPIN="${LOGIND_DROPIN:-/etc/systemd/logind.conf.d/90-x120x.conf}"
if [ -f "${LOGIND_DROPIN}" ]; then
    rm -f "${LOGIND_DROPIN}"
    rmdir --ignore-fail-on-non-empty "$(dirname "${LOGIND_DROPIN}")" 2>/dev/null || true
    systemctl try-restart systemd-logind 2>/dev/null || true
    ok "Removed ${LOGIND_DROPIN}"
else
    ok "logind drop-in not found (already removed)"
fi

LOGIND_CONF="/etc/systemd/logind.conf"
if [ -f "${LOGIND_CONF}" ]; then
    # Older installs (pre-drop-in) appended a marker-wrapped block to
    # logind.conf itself; remove it.  Lines outside our markers are
    # not touched.
    remove_ini_block "${LOGIND_CONF}" "logind-low-battery"

    # Legacy cleanup: remove bare lines written by even older
    # (pre-marker) versions of install.sh.  Same helper is called from
    # install.sh too, so the patterns stay in one place.
    clean_legacy_logind "${LOGIND_CONF}"

    systemctl try-restart systemd-logind 2>/dev/null || true
    ok "Restored ${LOGIND_CONF}"
else
    ok "logind.conf not found — skipping"
fi

# -------------------------------------------------------------------------
# Step 7: Restore UPower configuration
# -------------------------------------------------------------------------

info "Step 7/7 — Restoring UPower configuration..."

UPOWER_CONF="/etc/UPower/UPower.conf"
if [ -f "${UPOWER_CONF}" ]; then
    # Preferred path: remove the marker-wrapped block.
    remove_ini_block "${UPOWER_CONF}" "upower-pi-tweaks"

    # Legacy cleanup: remove bare lines from older installer versions.
    clean_legacy_upower "${UPOWER_CONF}"

    systemctl restart upower 2>/dev/null || true
    ok "Restored ${UPOWER_CONF}"
else
    ok "UPower config not found — skipping"
fi

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------

echo
echo -e "${GRN}${BLD}Uninstallation complete.${RST}"
echo
echo -e "  The x120x kernel module and all installer changes have been removed."
echo
echo -e "  ${BLD}Reboot to complete the removal:${RST}"
echo
echo -e "    sudo reboot"
echo
echo -e "  ${YLW}Note:${RST} bootloader EEPROM settings (POWER_OFF_ON_HALT, PSU_MAX_CURRENT)"
echo -e "  were left in place (the installer sets them on a Pi 5). To revert them, run:"
echo
echo -e "    sudo rpi-eeprom-config -e"
echo
