#!/usr/bin/env bash
# tests/test-install.sh — unit tests for install.sh's configure_bootloader().
#
# The function is extracted from install.sh and run against a mocked
# rpi-eeprom-config and a mocked device-tree model path (RPI_EEPROM_CONFIG
# / DT_MODEL_PATH overrides).  Assertions are made on the *staged* config
# file the mock captures at --apply time — never on a read-back, since on
# real hardware the flash only happens at the next boot.
#
# Run:  bash tests/test-install.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail   # deliberately not -e: we want every case to run

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL_SH="${HERE}/../install.sh"

[ -f "${INSTALL_SH}" ] || { echo "cannot find install.sh at ${INSTALL_SH}" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT

# Extract just the function under test.  This sed range works only
# because configure_bootloader()'s closing brace is the first column-0
# "}" after its opener — keep it that way (no top-level "}" in the body).
CB_SRC=$(sed -n '/^configure_bootloader() {/,/^}/p' "${INSTALL_SH}")
[ -n "${CB_SRC}" ] || { echo "could not extract configure_bootloader() from install.sh" >&2; exit 2; }

PASS=0
FAIL=0
assert() {  # assert "name" "test-expression"
    if eval "$2" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf '  \033[0;32mPASS\033[0m %s\n' "$1"
    else
        FAIL=$((FAIL + 1))
        printf '  \033[0;31mFAIL\033[0m %s   [%s]\n' "$1" "$2"
    fi
}

# A mock rpi-eeprom-config: no args -> dump ${MOCK_CURRENT}; "--apply FILE"
# -> record the call and copy FILE to ${MOCK_APPLIED}.
make_mock() {
    cat > "$1" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = "--apply" ]; then
    echo apply >> "${MOCK_APPLY_LOG}"
    cp "$2" "${MOCK_APPLIED}"
    exit "${MOCK_APPLY_RC:-0}"
fi
cat "${MOCK_CURRENT}"
MOCK
    chmod +x "$1"
}

# Reset per-case state and default to a healthy Pi 5 with the mock present.
reset() {
    export MOCK_APPLIED="${WORK}/applied"
    export MOCK_APPLY_LOG="${WORK}/apply.log"
    export MOCK_CURRENT="${WORK}/current"
    export MOCK_APPLY_RC=0
    : > "${MOCK_APPLY_LOG}"
    rm -f -- "${MOCK_APPLIED}"
    : > "${MOCK_CURRENT}"

    export RPI_EEPROM_CONFIG="${WORK}/mock-eeprom"
    make_mock "${RPI_EEPROM_CONFIG}"

    printf 'Raspberry Pi 5 Model B Rev 1.0\0' > "${WORK}/model"
    export DT_MODEL_PATH="${WORK}/model"

    SKIP_EEPROM=0
}

# Run configure_bootloader() in a subshell with logging stubs; logs land in
# ${LOGCAP}, the subshell's exit status is returned.
LOGCAP="${WORK}/log"
run_cb() {
    : > "${LOGCAP}"
    (
        info() { echo "info:$*" >> "${LOGCAP}"; }
        ok()   { echo "ok:$*"   >> "${LOGCAP}"; }
        warn() { echo "warn:$*" >> "${LOGCAP}"; }
        die()  { echo "die:$*"  >> "${LOGCAP}"; exit 1; }
        X120X_CLEANUP=()   # install.sh's main flow provides this; stub it here
        eval "${CB_SRC}"
        configure_bootloader
    )
}

applied_count() { wc -l < "${MOCK_APPLY_LOG}" | tr -d ' '; }

echo "configure_bootloader() tests"

# 1 — Non-Pi-5 model: skip, no --apply.
reset
printf 'Raspberry Pi 4 Model B Rev 1.4\0' > "${WORK}/model"
run_cb; rc=$?
assert "1 non-Pi5: returns 0"        '[ "'"$rc"'" -eq 0 ]'
assert "1 non-Pi5: no --apply"       '[ ! -s "${MOCK_APPLY_LOG}" ]'
assert "1 non-Pi5: logs 'not required'" 'grep -q "not required on this model" "${LOGCAP}"'

# 2 — Model file absent: same skip path, exit 0.
reset
export DT_MODEL_PATH="${WORK}/no-such-model"
run_cb; rc=$?
assert "2 no model file: returns 0"  '[ "'"$rc"'" -eq 0 ]'
assert "2 no model file: no --apply" '[ ! -s "${MOCK_APPLY_LOG}" ]'

# 3 — Pi 5, neither key present: both appended, --apply once, others kept.
reset
printf 'BOOT_ORDER=0xf41\nHDMI=1\n' > "${MOCK_CURRENT}"
run_cb; rc=$?
assert "3 neither key: returns 0"    '[ "'"$rc"'" -eq 0 ]'
assert "3 neither key: --apply once" '[ "$(applied_count)" -eq 1 ]'
assert "3 neither key: POWER_OFF_ON_HALT=1 staged" 'grep -qx "POWER_OFF_ON_HALT=1" "${MOCK_APPLIED}"'
assert "3 neither key: PSU_MAX_CURRENT=5000 staged" 'grep -qx "PSU_MAX_CURRENT=5000" "${MOCK_APPLIED}"'
assert "3 neither key: other keys preserved" 'grep -qx "BOOT_ORDER=0xf41" "${MOCK_APPLIED}"'

# 4 — Pi 5, both keys already correct: no --apply.
reset
printf 'BOOT_ORDER=0xf41\nPOWER_OFF_ON_HALT=1\nPSU_MAX_CURRENT=5000\n' > "${MOCK_CURRENT}"
run_cb; rc=$?
assert "4 both correct: returns 0"   '[ "'"$rc"'" -eq 0 ]'
assert "4 both correct: no --apply"  '[ ! -s "${MOCK_APPLY_LOG}" ]'
assert "4 both correct: logs 'already configured'" 'grep -q "already configured" "${LOGCAP}"'

# 5 — Pi 5, prior POWER_OFF_ON_HALT=0: rewritten to =1, one --apply, others intact.
reset
printf 'BOOT_ORDER=0xf41\nPOWER_OFF_ON_HALT=0\nPSU_MAX_CURRENT=5000\nWAKE_ON_GPIO=1\n' > "${MOCK_CURRENT}"
run_cb; rc=$?
assert "5 prior =0: --apply once"    '[ "$(applied_count)" -eq 1 ]'
assert "5 prior =0: rewritten to =1" 'grep -qx "POWER_OFF_ON_HALT=1" "${MOCK_APPLIED}"'
assert "5 prior =0: no =0 remains"   '! grep -qx "POWER_OFF_ON_HALT=0" "${MOCK_APPLIED}"'
assert "5 prior =0: WAKE_ON_GPIO intact" 'grep -qx "WAKE_ON_GPIO=1" "${MOCK_APPLIED}"'
assert "5 prior =0: BOOT_ORDER intact"   'grep -qx "BOOT_ORDER=0xf41" "${MOCK_APPLIED}"'

# 6 — Pi 5, one key correct / other missing: staged file has both correct.
reset
printf 'POWER_OFF_ON_HALT=1\nHDMI=1\n' > "${MOCK_CURRENT}"
run_cb; rc=$?
assert "6 one missing: --apply once" '[ "$(applied_count)" -eq 1 ]'
assert "6 one missing: POWER_OFF_ON_HALT=1 staged" 'grep -qx "POWER_OFF_ON_HALT=1" "${MOCK_APPLIED}"'
assert "6 one missing: PSU_MAX_CURRENT=5000 staged" 'grep -qx "PSU_MAX_CURRENT=5000" "${MOCK_APPLIED}"'

# 7 — Staged file has exactly one instance of each key (even given duplicates).
reset
printf 'POWER_OFF_ON_HALT=0\nPOWER_OFF_ON_HALT=1\nPSU_MAX_CURRENT=1000\nHDMI=1\n' > "${MOCK_CURRENT}"
run_cb; rc=$?
assert "7 dedup: exactly one POWER_OFF_ON_HALT" '[ "$(grep -c "^POWER_OFF_ON_HALT=" "${MOCK_APPLIED}")" -eq 1 ]'
assert "7 dedup: exactly one PSU_MAX_CURRENT"   '[ "$(grep -c "^PSU_MAX_CURRENT=" "${MOCK_APPLIED}")" -eq 1 ]'
assert "7 dedup: value is =1"   'grep -qx "POWER_OFF_ON_HALT=1" "${MOCK_APPLIED}"'
assert "7 dedup: value is =5000" 'grep -qx "PSU_MAX_CURRENT=5000" "${MOCK_APPLIED}"'

# 8 — --skip-eeprom: function returns early, no --apply.
reset
SKIP_EEPROM=1
run_cb; rc=$?
assert "8 skip-eeprom: returns 0"    '[ "'"$rc"'" -eq 0 ]'
assert "8 skip-eeprom: no --apply"   '[ ! -s "${MOCK_APPLY_LOG}" ]'
assert "8 skip-eeprom: logs skip"    'grep -q "Skipping bootloader" "${LOGCAP}"'

# 9 — rpi-eeprom-config missing: warn, continue, exit 0.
reset
export RPI_EEPROM_CONFIG="${WORK}/no-such-eeprom-binary"
run_cb; rc=$?
assert "9 missing binary: returns 0" '[ "'"$rc"'" -eq 0 ]'
assert "9 missing binary: no --apply" '[ ! -s "${MOCK_APPLY_LOG}" ]'
assert "9 missing binary: warns"     'grep -q "warn:rpi-eeprom-config not found" "${LOGCAP}"'

# 10 — Pi 5, dump succeeds but is empty: guard skips, no --apply.  A failed
#      unprivileged read must never be staged as a two-line config that
#      wipes the rest of the EEPROM config.
reset
: > "${MOCK_CURRENT}"
run_cb; rc=$?
assert "10 empty dump: returns 0"    '[ "'"$rc"'" -eq 0 ]'
assert "10 empty dump: no --apply"   '[ ! -s "${MOCK_APPLY_LOG}" ]'
assert "10 empty dump: warns"        'grep -q "read back empty" "${LOGCAP}"'

# 11 — Arg parsing: --help documents --skip-eeprom and exits 0.
echo "argument-parsing tests"
help_out=$(bash "${INSTALL_SH}" --help 2>&1); help_rc=$?
assert "11 --help: exits 0"          '[ "'"$help_rc"'" -eq 0 ]'
assert "11 --help: mentions --skip-eeprom" 'printf "%s" "'"$help_out"'" | grep -q -- "--skip-eeprom"'

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
