#!/usr/bin/env bash
# tests/test-driver-params.sh — guard the undervoltage-shutdown module
# parameters against silent removal by a refactor.
#
# The driver's kernel-side poweroff (src/x120x.c) is safety-critical:
# on systemd < 255 it is the only thing that powers the box off on
# undervoltage.  A refactor that dropped a param or its enable check
# would regress that silently — W=1/checkpatch would stay green.  This
# test asserts each param is declared, described, and consulted.
#
# It greps the source (there is no C unit harness in this repo); the
# trigger path itself is exercised on hardware via
# vfloor_poweroff_dry_run — see that param's MODULE_PARM_DESC.
#
# Run:  bash tests/test-driver-params.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="${HERE}/../src/x120x.c"
[ -f "${SRC}" ] || { echo "cannot find src/x120x.c at ${SRC}" >&2; exit 2; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; }

check() {  # name  regex
    if grep -qE "$2" "${SRC}"; then pass "$1"; else fail "$1  (no match: $2)"; fi
}

echo "undervoltage-shutdown params present and wired"
check "vfloor_poweroff declared"          '^module_param\(vfloor_poweroff, '
check "vfloor_poweroff described"         'MODULE_PARM_DESC\(vfloor_poweroff,'
check "vfloor_poweroff gates the trigger" 'if \(vfloor_poweroff\)'
check "vmin_critical_mv declared"         '^module_param\(vmin_critical_mv, '
check "vmin_critical_mv described"        'MODULE_PARM_DESC\(vmin_critical_mv,'
check "vmin_critical_mv clamped"          'vmin_critical_mv = clamp\(vmin_critical_mv'
check "dry-run declared"                  '^module_param\(vfloor_poweroff_dry_run, '
check "dry-run described"                 'MODULE_PARM_DESC\(vfloor_poweroff_dry_run,'
check "orderly_poweroff called"           'orderly_poweroff\(false\)'
check "poweroff is on-battery only"       '!new_ac && new_uv > 0 && new_uv <= vmin_uv'

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
