#!/usr/bin/env bash
# tools/check-layout-tree.sh — verify every tracked file appears in the
# "## Repository layout" tree in README.md.
#
# The README carries an ASCII tree of the repository under a
# "## Repository layout" heading.  This check fails if any git-tracked
# file is absent from that tree, so a newly added file cannot silently
# rot the diagram out of date.  It is the check CI ran inline before it
# was extracted here so `make test` can catch it locally too.
#
# Matching is by basename anywhere in the tree text, not full path: the
# goal is "no file is missing from the diagram", not a byte-exact path
# audit, so moving a file between directories is deliberately not caught.
#
# Usage: bash tools/check-layout-tree.sh [root]
# Unprivileged; root defaults to the repository containing this script.
# Exits non-zero with one line per file missing from the tree.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${root}"

# Extract the ASCII tree: the first fenced code block after the
# "## Repository layout" heading.
tree=$(awk '/^## Repository layout/{f=1} f&&/^```/{n++; next} f&&n==1{print} n==2{exit}' README.md)

if [ -z "${tree}" ]; then
    echo "BROKEN: no '## Repository layout' code block found in README.md" >&2
    exit 1
fi

fail=0
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    re=$(basename "${f}" | sed 's/[].[*^$]/\\&/g')
    if ! printf '%s\n' "${tree}" | grep -qE "(^|[ /])${re}( |$)"; then
        echo "Missing from README '## Repository layout': ${f}" >&2
        fail=1
    fi
done < <(git ls-files)

if [ "${fail}" -ne 0 ]; then
    echo "Update the tree in README.md." >&2
    exit 1
fi

n=$(git ls-files | wc -l | tr -d ' ')
echo "OK: all ${n} tracked files appear in the README layout tree."
