# lib/common.sh — helpers shared by install.sh and uninstall.sh.
#
# This file is sourced, never executed.  It is the single source of
# truth for everything the installer and uninstaller must agree on:
# the output helpers, the root check, the INI marker constants that
# install_ini_block (install.sh) and remove_ini_block (uninstall.sh)
# both build their markers from, and the legacy-line cleanup helpers.
# Before this file existed the two scripts carried identical copies
# with nothing enforcing agreement.
#
# Copyright (C) 2026 Edvard Fielding <mor-lock@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck shell=bash

# Refuse direct execution — none of these helpers make sense outside
# the sourcing script.
if [ "${BASH_SOURCE[0]-}" = "$0" ]; then
    echo "lib/common.sh is a library — source it, do not run it." >&2
    exit 64
fi

# -------------------------------------------------------------------------
# Output helpers
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
    [ "$(id -u)" -eq 0 ] \
        || die "This script must be run with sudo: sudo bash $(basename "$0")"
}

# -------------------------------------------------------------------------
# INI marker constants
#
# Marker convention (written by install_ini_block, deleted by
# remove_ini_block):
#   # >>> x120x-dkms: <tag> (do not edit) >>>
#   <content>
#   # <<< x120x-dkms: <tag> <<<
#
# Lines outside the markers are never touched, so users who set their
# own values are left alone.
# -------------------------------------------------------------------------

# The prefixes look unused to shellcheck because they are consumed by
# install_ini_block (install.sh) and remove_ini_block (uninstall.sh),
# which it cannot see from this file.
# shellcheck disable=SC2034
X120X_MARKER_BEGIN_PREFIX="# >>> x120x-dkms:"
# shellcheck disable=SC2034
X120X_MARKER_END_PREFIX="# <<< x120x-dkms:"

# -------------------------------------------------------------------------
# Legacy cleanup helpers
#
# Older versions of install.sh wrote bare lines (no markers) into
# logind.conf and UPower.conf, and commented out any pre-existing
# HandleLowBattery= / CriticalPowerAction= / NoPollBatteries= line
# alongside.  A system that's been through an old install will still
# have those lines sitting around even after the new installer writes
# its marker block; without explicit cleanup they accumulate forever.
# install.sh calls these before writing its marker block and
# uninstall.sh calls them on removal, so such a system gets cleaned
# up either way.
#
# These functions remove the exact strings the old installer emitted.
# Each pattern matches a single specific line — we never uncomment
# anything, because the old installer commented blindly and a user
# who had deliberately written `#HandleLowBattery=ignore` would be
# surprised by silent reactivation.
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
