#!/usr/bin/env bash
# tools/collect-debug.sh — one-shot diagnostics for x120x-dkms issues.
#
# Prints a single fenced block to stdout; paste it verbatim into a GitHub
# issue.  No root required, and it runs cleanly whether or not the driver
# is loaded.  A few values need sudo for full output (noted inline —
# `dmesg` in particular).
#
# Paths are overridable for testing: X120X_PS_DIR, X120X_MODEL,
# X120X_CONF, X120X_OS_RELEASE.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail

PS_DIR="${X120X_PS_DIR:-/sys/class/power_supply}"
MODEL="${X120X_MODEL:-/proc/device-tree/model}"
CONF="${X120X_CONF:-/etc/modprobe.d/x120x.conf}"
OSREL="${X120X_OS_RELEASE:-/etc/os-release}"

echo '```text'
echo "# x120x-dkms debug report"

echo
echo "## Pi model"
if [ -r "${MODEL}" ]; then tr -d '\0' < "${MODEL}" 2>/dev/null; else echo "(not available: ${MODEL})"; fi
echo

echo "## OS (os-release)"
grep -E '^(PRETTY_NAME|VERSION|ID)=' "${OSREL}" 2>/dev/null || echo "(not available: ${OSREL})"

echo
echo "## Kernel"
uname -a

echo
echo "## Architecture"
if command -v dpkg >/dev/null 2>&1; then dpkg --print-architecture; else uname -m; fi

echo
echo "## DKMS status"
if command -v dkms >/dev/null 2>&1; then
    dkms status 2>/dev/null | grep -i x120x || echo "(no x120x DKMS entry)"
else
    echo "(dkms not installed)"
fi

echo
echo "## Kernel log — dmesg | grep x120x  (run with sudo for full output)"
if command -v dmesg >/dev/null 2>&1; then
    dmesg 2>/dev/null | grep -i x120x || echo "(no x120x lines; try: sudo dmesg | grep x120x)"
else
    echo "(dmesg not available)"
fi

echo
echo "## power_supply devices"
ls "${PS_DIR}" 2>/dev/null || echo "(none under ${PS_DIR})"

echo
echo "## x120x sysfs values"
if [ -d "${PS_DIR}/x120x-battery" ] || [ -d "${PS_DIR}/x120x-charger" ]; then
    for kv in \
        x120x-battery/capacity x120x-battery/voltage_now \
        x120x-battery/status x120x-battery/health \
        x120x-charger/charge_type \
        x120x-charger/charge_control_start_threshold \
        x120x-charger/charge_control_end_threshold \
        x120x-ac/online; do
        printf '%-46s %s\n' "${kv}" "$(cat "${PS_DIR}/${kv}" 2>/dev/null || echo '(n/a)')"
    done
else
    echo "(driver not loaded — no x120x power_supply devices under ${PS_DIR})"
fi

echo
echo "## Module parameters"
if [ -d /sys/module/x120x/parameters ]; then
    for p in /sys/module/x120x/parameters/*; do
        printf '%-28s %s\n' "$(basename "${p}")" "$(cat "${p}" 2>/dev/null || echo '(n/a)')"
    done
else
    echo "(module not loaded)"
fi

echo
echo "## modprobe.d/x120x.conf"
if [ -r "${CONF}" ]; then cat "${CONF}"; else echo "(not available: ${CONF})"; fi

echo '```'
