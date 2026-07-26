#!/usr/bin/env bash
# tests/test-check-links.sh — unit tests for tools/check-links.sh.
#
# Builds throwaway markdown trees under mktemp and runs the checker
# against them with an explicit root, exercising the path-resolution
# edge cases: same-file anchors, root→docs, docs→root via `../`,
# docs→docs sibling, missing file, missing anchor, duplicate-heading
# -N suffixing, and the skip rules (external URLs, GitHub's
# `../../issues/...` convention, fenced links, inline code spans).
# The fixture directories are not git repositories, which also
# exercises the checker's find-based file enumeration.
#
# Run:  bash tests/test-check-links.sh
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -uo pipefail   # deliberately not -e: we want every case to run

# Tests never need root; refuse it so a stray sudo can't touch the system.
if [ "$(id -u)" -eq 0 ]; then
    echo "Refusing to run as root — these tests never need it." >&2
    exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
CHECKER="${HERE}/../tools/check-links.sh"

[ -f "${CHECKER}" ] || { echo "cannot find check-links.sh at ${CHECKER}" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; }

# -------------------------------------------------------------------------
# Fixture: a tree where every link is valid or legitimately skipped.
# -------------------------------------------------------------------------
GOOD="${WORK}/good"
mkdir -p "${GOOD}/docs"

cat > "${GOOD}/root.md" << 'EOF'
# Alpha

## Dup

## Dup

Same-file anchor: [alpha](#alpha) and the duplicate [second](#dup-1).
Into docs: [a](docs/a.md) and [beta](docs/a.md#beta).
Skipped — GitHub URL convention: [report](../../issues/new?template=hardware_report.yml).
Skipped — external: [site](https://example.com/page#frag).
Skipped — not markdown: [license](LICENSE).
Skipped — inline code span: `[...](#anchor)` is example syntax.

```markdown
Skipped — fenced example: [nope](#not-a-real-heading)
```
EOF

cat > "${GOOD}/docs/a.md" << 'EOF'
# Beta

Back to root: [root](../root.md) and [alpha](../root.md#alpha).
Sibling: [gamma](b.md#gamma).
EOF

cat > "${GOOD}/docs/b.md" << 'EOF'
# Gamma
EOF

echo "good fixture"
out=$(bash "${CHECKER}" "${GOOD}" 2>&1); rc=$?
if [ "${rc}" -eq 0 ]; then pass "exit 0"; else fail "exit 0 (rc=${rc}: ${out})"; fi
# 7 validated links: #alpha #dup-1 docs/a.md docs/a.md#beta ../root.md
# ../root.md#alpha b.md#gamma — the five skips must not be counted.
if printf '%s' "${out}" | grep -qF "OK: 7 markdown link(s) resolve."; then
    pass "7 links checked, skips not counted"
else
    fail "7 links checked, skips not counted  (got: ${out})"
fi

# -------------------------------------------------------------------------
# Fixture: every failure mode.
# -------------------------------------------------------------------------
BAD="${WORK}/bad"
mkdir -p "${BAD}/docs"

cat > "${BAD}/root.md" << 'EOF'
# Alpha

Missing same-file anchor: [x](#missing-heading).
Missing file: [x](docs/gone.md).
Missing anchor in target: [x](docs/a.md#no-such-heading).
EOF

cat > "${BAD}/docs/a.md" << 'EOF'
# Beta

Missing file via ../: [x](../gone.md#whatever).
EOF

echo "bad fixture"
out=$(bash "${CHECKER}" "${BAD}" 2>&1); rc=$?
if [ "${rc}" -ne 0 ]; then pass "exit non-zero"; else fail "exit non-zero"; fi
expect_broken() {  # name  substring
    if printf '%s' "${out}" | grep -qF "$2"; then pass "$1"; else fail "$1  (missing: $2)"; fi
}
expect_broken "same-file anchor reported"  "root.md: ](#missing-heading) — anchor #missing-heading not found in root.md"
expect_broken "missing file reported"      "root.md: ](docs/gone.md) — file not found: docs/gone.md"
expect_broken "cross-file anchor reported" "root.md: ](docs/a.md#no-such-heading) — anchor #no-such-heading not found in docs/a.md"
expect_broken "../ path resolved in error" "docs/a.md: ](../gone.md#whatever) — file not found: gone.md"
if [ "$(printf '%s\n' "${out}" | grep -c '^BROKEN:')" -eq 4 ]; then
    pass "exactly 4 failures, nothing spurious"
else
    fail "exactly 4 failures, nothing spurious  (got: ${out})"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
