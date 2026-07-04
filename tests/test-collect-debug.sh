#!/usr/bin/env bash
# tests/test-collect-debug.sh — tools/collect-debug.sh runs cleanly (exit 0)
# both with a mocked x120x sysfs and with none (driver not loaded), using
# the tool's path overrides.
#
# Run:  bash tests/test-collect-debug.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail

# Tests never need root; refuse it so a stray sudo can't touch the system.
if [ "$(id -u)" -eq 0 ]; then
    echo "Refusing to run as root — these tests never need it." >&2
    exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="${HERE}/../tools/collect-debug.sh"

WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT

PASS=0; FAIL=0
assert() {
    if eval "$2" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s   [%s]\n' "$1" "$2"
    fi
}

echo "collect-debug.sh"

# --- Case 1: mocked sysfs WITH x120x devices ---------------------------------
mkdir -p "${WORK}/ps/x120x-battery" "${WORK}/ps/x120x-charger" "${WORK}/ps/x120x-ac"
echo 100  > "${WORK}/ps/x120x-battery/capacity"
echo Full > "${WORK}/ps/x120x-battery/status"
echo Fast > "${WORK}/ps/x120x-charger/charge_type"
echo 1    > "${WORK}/ps/x120x-ac/online"
printf 'Raspberry Pi 5 Model B Rev 1.0\0' > "${WORK}/model"
printf 'PRETTY_NAME="Test OS"\nID=debian\n'   > "${WORK}/osrel"
printf 'options x120x battery_mah=20000 board=x120x\n' > "${WORK}/conf"

out=$(X120X_PS_DIR="${WORK}/ps" X120X_MODEL="${WORK}/model" \
      X120X_OS_RELEASE="${WORK}/osrel" X120X_CONF="${WORK}/conf" \
      bash "${TOOL}"); rc=$?
printf '%s\n' "${out}" > "${WORK}/out1"
assert "with mock: exits 0"            '[ "'"$rc"'" -eq 0 ]'
assert "with mock: single fenced block" '[ "$(grep -c "^\`\`\`" "${WORK}/out1")" -eq 2 ]'
assert "with mock: shows capacity=100"  'grep -q "x120x-battery/capacity  *100" "${WORK}/out1"'
assert "with mock: shows charge_type"   'grep -q "x120x-charger/charge_type  *Fast" "${WORK}/out1"'
assert "with mock: shows Pi model"      'grep -q "Raspberry Pi 5 Model B" "${WORK}/out1"'
assert "with mock: shows conf"          'grep -q "battery_mah=20000" "${WORK}/out1"'

# --- Case 2: no x120x devices (driver not loaded) ----------------------------
mkdir -p "${WORK}/empty"
out=$(X120X_PS_DIR="${WORK}/empty" X120X_MODEL="${WORK}/nope" \
      X120X_OS_RELEASE="${WORK}/nope" X120X_CONF="${WORK}/nope" \
      bash "${TOOL}"); rc=$?
printf '%s\n' "${out}" > "${WORK}/out2"
assert "no driver: exits 0"             '[ "'"$rc"'" -eq 0 ]'
assert "no driver: single fenced block" '[ "$(grep -c "^\`\`\`" "${WORK}/out2")" -eq 2 ]'
assert "no driver: notes driver not loaded" 'grep -q "driver not loaded" "${WORK}/out2"'
assert "no driver: missing paths noted"  'grep -q "not available" "${WORK}/out2"'

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
