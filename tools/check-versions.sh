#!/usr/bin/env bash
# tools/check-versions.sh — verify the version string agrees everywhere.
#
# The version lives in four places: dkms.conf (PACKAGE_VERSION),
# install.sh (PKG_VERSION), src/x120x.c (MODULE_VERSION), and the
# hardcoded x120x-X.Y.Z / x120x/X.Y.Z refs in docs/manual-install.md.
# Agreement used to be enforced only by the RELEASING.md checklist;
# this makes it a machine guarantee.  A source missing its version
# entirely is a failure — a refactor that removes PKG_VERSION should
# trip the check, not silently pass.
#
# Deliberately out of scope: CHANGELOG.md and README.md version
# mentions are historical records, not the current version, and the
# README tested-hardware row lags by design until on-hardware
# validation passes (see RELEASING.md).
#
# Usage: bash tools/check-versions.sh [root]
# Unprivileged; root defaults to the repository containing this
# script.  Exits non-zero with one line per problem.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${ROOT}" || { echo "cannot cd to ${ROOT}" >&2; exit 2; }

fail=0

v_dkms=$(sed -n 's/^PACKAGE_VERSION="\([0-9][0-9.]*\)"$/\1/p' dkms.conf)
v_inst=$(sed -n 's/^PKG_VERSION="\([0-9][0-9.]*\)"$/\1/p' install.sh)
v_mod=$(sed -n 's/^MODULE_VERSION("\([0-9][0-9.]*\)");$/\1/p' src/x120x.c)

[ -n "${v_dkms}" ] || { echo "BROKEN: dkms.conf: PACKAGE_VERSION not found" >&2; fail=1; }
[ -n "${v_inst}" ] || { echo "BROKEN: install.sh: PKG_VERSION not found" >&2; fail=1; }
[ -n "${v_mod}" ]  || { echo "BROKEN: src/x120x.c: MODULE_VERSION not found" >&2; fail=1; }
[ "${fail}" -eq 0 ] || { echo "Version check FAILED." >&2; exit 1; }

# Consensus: dkms.conf is the reference purely for reporting; every
# source must match every other, so the choice does not matter.
ref="${v_dkms}"

[ "${v_inst}" = "${ref}" ] \
    || { echo "BROKEN: install.sh: PKG_VERSION=${v_inst} (expected ${ref})" >&2; fail=1; }
[ "${v_mod}" = "${ref}" ] \
    || { echo "BROKEN: src/x120x.c: MODULE_VERSION=${v_mod} (expected ${ref})" >&2; fail=1; }

# Every hardcoded ref in the manual walkthrough must match.  Anchored
# to the x120x-X.Y.Z / x120x/X.Y.Z forms so kernel versions (6.12.y)
# and prose numbers never match.
found_manual=0
while IFS=: read -r line ref_str; do
    [ -n "${ref_str}" ] || continue
    found_manual=1
    v="${ref_str#x120x[-/]}"
    [ "${v}" = "${ref}" ] \
        || { echo "BROKEN: docs/manual-install.md:${line}: ${ref_str} (expected ${ref})" >&2; fail=1; }
done < <(grep -n -o 'x120x[-/][0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}' docs/manual-install.md)

[ "${found_manual}" -eq 1 ] \
    || { echo "BROKEN: docs/manual-install.md: no x120x-X.Y.Z / x120x/X.Y.Z refs found" >&2; fail=1; }

if [ "${fail}" -ne 0 ]; then
    echo "Version check FAILED (consensus: ${ref})." >&2
    exit 1
fi
echo "OK: version ${ref} agrees across dkms.conf, install.sh, src/x120x.c, docs/manual-install.md."
