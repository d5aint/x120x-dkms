#!/usr/bin/env bash
# tests/test-args.sh — install.sh argument parsing.
#
# The parser runs before the root check and before config.txt detection,
# so invalid arguments `die` in the parser (asserted by exit code +
# message).  Valid arguments are "accepted" — the script proceeds past the
# parser and dies later (config.txt not found, or not root); we assert
# only that the parser did NOT reject them, which is host-independent.
#
# Run:  bash tests/test-args.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Refusing to run as root: expect_accept invokes" >&2
    echo "install.sh with valid arguments, which as root on a" >&2
    echo "real Pi would execute the full installer repeatedly." >&2
    exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL_SH="${HERE}/../install.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; }

# Parser must REJECT: nonzero exit AND the given message in the output.
expect_die() {  # name  message  args...
    local name="$1" msg="$2"; shift 2
    local out rc; out=$(bash "${INSTALL_SH}" "$@" 2>&1); rc=$?
    if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qF -- "${msg}"; then
        pass "${name}"
    else
        fail "${name}  (rc=${rc}, first line: ${out%%$'\n'*})"
    fi
}

# Parser must ACCEPT: the given rejection substring must NOT appear (the
# script may still die afterwards at config.txt / root — that's expected).
expect_accept() {  # name  reject-substring  args...
    local name="$1" rej="$2"; shift 2
    local out; out=$(bash "${INSTALL_SH}" "$@" 2>&1)
    if printf '%s' "${out}" | grep -qF -- "${rej}"; then
        fail "${name}  (rejected: ${rej})"
    else
        pass "${name}"
    fi
}

echo "--battery-mah"
expect_die    "abc rejected"           "requires a positive integer" --battery-mah abc
expect_die    "0 rejected"             "must be greater than zero"   --battery-mah 0
expect_die    "-5 rejected"            "requires a positive integer" --battery-mah -5
expect_die    "missing value rejected" "requires a positive integer" --battery-mah
expect_accept "6000 accepted"          "--battery-mah"               --battery-mah 6000
expect_accept "007 accepted"           "--battery-mah"               --battery-mah 007

echo "--charge-mode"
for m in fast Fast FAST longlife long-life "Long Life"; do
    expect_accept "'${m}' accepted" "Unknown charge mode" --charge-mode "${m}"
done
expect_die "turbo rejected" "Unknown charge mode: turbo" --charge-mode turbo

echo "--board"
for b in x120x x728v2 x728v1 x708 x729; do
    expect_accept "'${b}' accepted" "Unknown board variant" --board "${b}"
done
expect_die "x999 rejected" "Unknown board variant: x999" --board x999

echo "unknown option"
expect_die "--frobnicate rejected" "Unknown option: --frobnicate" --frobnicate

echo "--help"
help_out=$(bash "${INSTALL_SH}" --help 2>&1); help_rc=$?
if [ "${help_rc}" -eq 0 ]; then pass "--help exits 0"; else fail "--help exits 0 (rc=${help_rc})"; fi
for flag in --battery-mah --charge-mode --board --skip-eeprom; do
    if printf '%s' "${help_out}" | grep -qF -- "${flag}"; then
        pass "--help mentions ${flag}"
    else
        fail "--help mentions ${flag}"
    fi
done

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
