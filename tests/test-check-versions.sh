#!/usr/bin/env bash
# tests/test-check-versions.sh — unit tests for tools/check-versions.sh.
#
# Builds throwaway fixture trees (minimal dkms.conf, install.sh,
# src/x120x.c, docs/manual-install.md) under mktemp and runs the
# checker against them with an explicit root: the all-agree case
# passes, each single-source mutation fails naming that source, and a
# removed PKG_VERSION line fails rather than silently passing.
#
# Run:  bash tests/test-check-versions.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail   # deliberately not -e: we want every case to run

# Tests never need root; refuse it so a stray sudo can't touch the system.
if [ "$(id -u)" -eq 0 ]; then
    echo "Refusing to run as root — these tests never need it." >&2
    exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
CHECKER="${HERE}/../tools/check-versions.sh"

[ -f "${CHECKER}" ] || { echo "cannot find check-versions.sh at ${CHECKER}" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; }

# Build a fixture tree with the given version everywhere.
make_fixture() {  # dir version
    local d="$1" v="$2"
    mkdir -p "${d}/src" "${d}/docs"
    printf 'PACKAGE_VERSION="%s"\n' "${v}"     > "${d}/dkms.conf"
    printf 'PKG_VERSION="%s"\n' "${v}"         > "${d}/install.sh"
    printf 'MODULE_VERSION("%s");\n' "${v}"    > "${d}/src/x120x.c"
    cat > "${d}/docs/manual-install.md" << EOF
Copy to /usr/src/x120x-${v}/src, then run dkms add x120x/${v}.
Kernel 6.12.y is unrelated and must not match.
EOF
}

expect() {  # name expected-rc expected-substring dir
    local name="$1" want_rc="$2" want="$3" dir="$4" out rc
    out=$(bash "${CHECKER}" "${dir}" 2>&1); rc=$?
    if [ "${rc}" -eq "${want_rc}" ] && printf '%s' "${out}" | grep -qF "${want}"; then
        pass "${name}"
    else
        fail "${name}  (rc=${rc}, out: ${out})"
    fi
}

echo "check-versions tests"

make_fixture "${WORK}/ok" "0.9.9"
expect "all agree: passes"            0 "OK: version 0.9.9 agrees" "${WORK}/ok"

make_fixture "${WORK}/dkms" "0.9.9"
printf 'PACKAGE_VERSION="0.9.8"\n' > "${WORK}/dkms/dkms.conf"
# dkms.conf is the reporting reference, so mutating it makes the
# OTHER sources the reported mismatches — assert on install.sh.
expect "dkms.conf differs: fails"     1 "install.sh: PKG_VERSION=0.9.9 (expected 0.9.8)" "${WORK}/dkms"

make_fixture "${WORK}/inst" "0.9.9"
printf 'PKG_VERSION="0.9.8"\n' > "${WORK}/inst/install.sh"
expect "install.sh differs: fails"    1 "install.sh: PKG_VERSION=0.9.8 (expected 0.9.9)" "${WORK}/inst"

make_fixture "${WORK}/mod" "0.9.9"
printf 'MODULE_VERSION("0.9.8");\n' > "${WORK}/mod/src/x120x.c"
expect "MODULE_VERSION differs: fails" 1 "src/x120x.c: MODULE_VERSION=0.9.8 (expected 0.9.9)" "${WORK}/mod"

make_fixture "${WORK}/man" "0.9.9"
printf 'run dkms add x120x/0.9.8 into /usr/src/x120x-0.9.9\n' > "${WORK}/man/docs/manual-install.md"
expect "manual ref differs: fails, names line" 1 "docs/manual-install.md:1: x120x/0.9.8 (expected 0.9.9)" "${WORK}/man"

make_fixture "${WORK}/miss" "0.9.9"
: > "${WORK}/miss/install.sh"
expect "missing PKG_VERSION: fails"   1 "install.sh: PKG_VERSION not found" "${WORK}/miss"

make_fixture "${WORK}/noref" "0.9.9"
printf 'no version refs here; kernel 6.12.y only\n' > "${WORK}/noref/docs/manual-install.md"
expect "manual with no refs: fails"   1 "no x120x-X.Y.Z / x120x/X.Y.Z refs found" "${WORK}/noref"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
