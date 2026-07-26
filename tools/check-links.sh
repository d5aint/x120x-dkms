#!/usr/bin/env bash
# tools/check-links.sh — validate markdown links across the repository.
#
# Checks, for every tracked *.md file:
#   ](#anchor)         — resolves to a heading in the same file
#   ](path.md)         — the target file exists
#   ](path.md#anchor)  — the file exists AND the anchor resolves to a
#                        heading in that target file
#
# Relative paths resolve against the directory of the file containing
# the link, so `../README.md#foo` from docs/ and `docs/incidents.md#foo`
# from the root both work.  Targets whose path component does not end
# in `.md` are out of scope and skipped silently: external URLs would
# make the check network-dependent, and GitHub-convention URLs such as
# `../../issues/new?template=...` are not file paths at all.  Heading
# and link extraction are fence-aware, and inline code spans are
# stripped first so a literal `[...](#anchor)` inside backticks is not
# treated as a real link.
#
# Usage: bash tools/check-links.sh [root]
# Unprivileged; root defaults to the repository containing this script.
# Exits non-zero with one BROKEN line per failure.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${ROOT}" || { echo "cannot cd to ${ROOT}" >&2; exit 2; }

# GitHub-slugify one file's headings: fence-aware, lowercase, strip
# non-alphanumerics, spaces to hyphens, duplicate headings suffixed
# -1, -2, ...  This awk is the proven one that lived in ci.yml's
# "README anchor links resolve" step; this is now the only copy.
slugs_of() {
    awk '/^```/{f=!f;next} !f&&/^#+ /{h=$0;sub(/^#+[ \t]+/,"",h);s=tolower(h);gsub(/[^a-z0-9 -]+/,"",s);gsub(/ /,"-",s);c[s]++;print(c[s]==1?s:s"-"(c[s]-1))}' "$1"
}

# Link targets of one file: the contents of every ](...) on non-fence
# lines, after removing inline code spans.  grep exits 1 on a file
# with no links; that is not an error.
links_of() {
    awk '/^```/{f=!f;next} !f{print}' "$1" \
        | sed 's/`[^`]*`//g' \
        | grep -oE '\]\([^)]+\)' \
        | sed 's/^](//; s/)$//'
    return 0
}

# The markdown files to check: tracked files when inside a git work
# tree (CI and normal use); a plain find otherwise, so the test
# fixture can be an ordinary directory.
md_files() {
    if git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "${ROOT}" ls-files -- '*.md'
    else
        find . -name '*.md' -type f | sed 's|^\./||' | sort
    fi
}

fail=0
checked=0
while IFS= read -r file; do
    while IFS= read -r target; do
        [ -n "${target}" ] || continue
        case "${target}" in *://*) continue ;; esac    # external URL
        path="${target%%#*}"
        frag=""
        case "${target}" in *'#'*) frag="${target#*#}" ;; esac

        if [ -z "${path}" ]; then
            # ](#anchor) — same-file anchor
            tpath="${file}"
        else
            case "${path}" in *.md) ;; *) continue ;; esac   # not markdown
            tpath=$(realpath --relative-to="${ROOT}" -m -- "$(dirname "${file}")/${path}")
            if [ ! -f "${tpath}" ]; then
                echo "BROKEN: ${file}: ](${target}) — file not found: ${tpath}" >&2
                fail=1
                continue
            fi
        fi

        checked=$((checked + 1))
        if [ -n "${frag}" ] && ! slugs_of "${tpath}" | grep -qxF "${frag}"; then
            echo "BROKEN: ${file}: ](${target}) — anchor #${frag} not found in ${tpath}" >&2
            fail=1
        fi
    done < <(links_of "${file}")
done < <(md_files)

if [ "${fail}" -ne 0 ]; then
    echo "Markdown link check FAILED." >&2
    exit 1
fi
echo "OK: ${checked} markdown link(s) resolve."
