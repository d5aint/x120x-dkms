#!/usr/bin/env bash
# tests/test-persist.sh — the x120x-persist-mode.sh body that install.sh
# writes via heredoc (the udev-triggered charge-mode persistence).
#
# The heredoc body is extracted from install.sh and run with its two
# paths overridden (X120X_CONF, X120X_CHARGE_TYPE_PATH) against temp
# fixtures — the same override convention as the installer's other
# testable externals.
#
# Run:  bash tests/test-persist.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail

# Tests never need root; refuse it so a stray sudo can't touch the system.
if [ "$(id -u)" -eq 0 ]; then
    echo "Refusing to run as root — these tests never need it." >&2
    exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL_SH="${HERE}/../install.sh"

WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT

# Extract the heredoc body (between the `<< 'PERSIST_EOF'` line and the
# closing PERSIST_EOF marker) into a runnable script.
PERSIST="${WORK}/x120x-persist-mode.sh"
sed -n "/<< 'PERSIST_EOF'/,/^PERSIST_EOF$/p" "${INSTALL_SH}" | sed '1d;$d' > "${PERSIST}"
chmod +x "${PERSIST}"
[ -s "${PERSIST}" ] || { echo "could not extract persist heredoc from install.sh" >&2; exit 2; }

PASS=0; FAIL=0
assert() {
    if eval "$2" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s   [%s]\n' "$1" "$2"
    fi
}

# Run the persist script with a given charge_type and CONF contents.
CT="${WORK}/charge_type"
CONF="${WORK}/x120x.conf"
run_persist() {  # charge-type-string
    printf '%s\n' "$1" > "${CT}"
    X120X_CONF="${CONF}" X120X_CHARGE_TYPE_PATH="${CT}" sh "${PERSIST}"
}

echo "x120x-persist-mode.sh"

# 1 — "Long Life" -> conservation_mode_default=1 (existing value replaced).
printf 'options x120x battery_mah=20000 conservation_mode_default=0 board=x120x\n' > "${CONF}"
run_persist "Long Life"
assert "Long Life -> default=1" 'grep -q "conservation_mode_default=1" "${CONF}"'
assert "Long Life -> no stale =0" '! grep -q "conservation_mode_default=0" "${CONF}"'

# 2 — "Fast" -> =0 (existing value replaced).
printf 'options x120x battery_mah=20000 conservation_mode_default=1 board=x120x\n' > "${CONF}"
run_persist "Fast"
assert "Fast -> default=0" 'grep -q "conservation_mode_default=0" "${CONF}"'
assert "Fast -> no stale =1" '! grep -q "conservation_mode_default=1" "${CONF}"'

# 3 — replacement is in place: other options and the single line survive.
printf 'options x120x battery_mah=20000 conservation_mode_default=0 board=x120x\n' > "${CONF}"
run_persist "Long Life"
assert "replace in place: battery_mah kept" 'grep -q "battery_mah=20000" "${CONF}"'
assert "replace in place: board kept"       'grep -q "board=x120x" "${CONF}"'
assert "replace in place: still one line"   '[ "$(wc -l < "${CONF}")" -eq 1 ]'

# 4 — options line without the key: key injected after "options x120x ".
printf 'options x120x battery_mah=20000 board=x120x\n' > "${CONF}"
run_persist "Long Life"
assert "key injected: default=1 present" 'grep -q "conservation_mode_default=1" "${CONF}"'
assert "key injected: right after 'options x120x '" 'grep -q "^options x120x conservation_mode_default=1 " "${CONF}"'
assert "key injected: other options kept" 'grep -q "battery_mah=20000" "${CONF}"'

# 5 — CONF absent: no error, no file created.
MISSING="${WORK}/does-not-exist.conf"
printf 'Long Life\n' > "${CT}"
X120X_CONF="${MISSING}" X120X_CHARGE_TYPE_PATH="${CT}" sh "${PERSIST}"; rc=$?
assert "missing CONF: exit 0"        '[ "'"$rc"'" -eq 0 ]'
assert "missing CONF: no file made"  '[ ! -e "${MISSING}" ]'

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
