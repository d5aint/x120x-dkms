#!/usr/bin/env bash
# tests/test-restore-overlay.sh — the x120x-restore-overlay.sh body that
# install.sh writes via heredoc (the apt-hook overlay-persistence helper for
# Ubuntu / flash-kernel, issue #5).
#
# The heredoc body is extracted from install.sh and run with its paths
# overridden (X120X_BOOT_DIR, X120X_CONFIG_TXT, X120X_OVERLAY_STASH) against
# temp fixtures — the same override convention as the installer's other
# testable externals.  The helper runs inside apt, so the central guarantees
# under test are: it restores the overlay only when it is configured but
# missing, it never overwrites an existing overlay, it is a no-op otherwise,
# and it always exits 0.
#
# Run:  bash tests/test-restore-overlay.sh
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

# Extract the heredoc body (between the `<< 'RESTORE_EOF'` line and the
# closing RESTORE_EOF marker) into a runnable script.
RESTORE="${WORK}/x120x-restore-overlay.sh"
sed -n "/<< 'RESTORE_EOF'/,/^RESTORE_EOF$/p" "${INSTALL_SH}" | sed '1d;$d' > "${RESTORE}"
chmod +x "${RESTORE}"
[ -s "${RESTORE}" ] || { echo "could not extract restore heredoc from install.sh" >&2; exit 2; }

PASS=0; FAIL=0
assert() {
    if eval "$2" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s   [%s]\n' "$1" "$2"
    fi
}

STASH="${WORK}/stash.dtbo"
printf 'STASHED-OVERLAY\n' > "${STASH}"

# Build a fresh fake boot tree for each case and run the helper against it.
# Args: <layout: current|plain|none> <config-has-overlay: yes|no> <stash: yes|no>
# Echoes the BOOT dir it created; leaves ${LAST_OVL} pointing at the expected
# overlay path.
BOOT=""; LAST_OVL=""
setup_boot() {  # layout  config  stash
    BOOT=$(mktemp -d "${WORK}/boot.XXXXXX")
    case "$1" in
        current) mkdir -p "${BOOT}/current/overlays"; LAST_OVL="${BOOT}/current/overlays/x120x.dtbo" ;;
        plain)   mkdir -p "${BOOT}/overlays";         LAST_OVL="${BOOT}/overlays/x120x.dtbo" ;;
        none)    LAST_OVL="${BOOT}/none/x120x.dtbo" ;;
    esac
    if [ "$2" = yes ]; then
        printf '[all]\ndtoverlay=x120x\ngpio=6=pu\n' > "${BOOT}/config.txt"
    else
        printf '[all]\ngpio=6=pu\n' > "${BOOT}/config.txt"
    fi
    if [ "$3" = yes ]; then USE_STASH="${STASH}"; else USE_STASH="${WORK}/no-such-stash.dtbo"; fi
}
run_restore() {
    X120X_BOOT_DIR="${BOOT}" X120X_CONFIG_TXT="${BOOT}/config.txt" \
        X120X_OVERLAY_STASH="${USE_STASH}" sh "${RESTORE}"
}

echo "x120x-restore-overlay.sh"

# 1 — Ubuntu layout, overlay configured but missing, stash present: restored.
setup_boot current yes yes
run_restore; rc=$?
assert "current: restores missing overlay"        '[ -f "${LAST_OVL}" ]'
assert "current: restored content is the stash"    'grep -q STASHED-OVERLAY "${LAST_OVL}"'
assert "current: exit 0"                           '[ "'"$rc"'" -eq 0 ]'

# 2 — overlay already present: never overwritten (idempotent no-op).
setup_boot current yes yes
printf 'ORIGINAL-OVERLAY\n' > "${LAST_OVL}"
run_restore
assert "present overlay left untouched"            'grep -q ORIGINAL-OVERLAY "${LAST_OVL}"'
assert "present overlay: stash not copied over it"  '! grep -q STASHED-OVERLAY "${LAST_OVL}"'

# 3 — overlay not enabled in config.txt: no-op, nothing created.
setup_boot current no yes
run_restore
assert "not configured: overlay not created"       '[ ! -f "${LAST_OVL}" ]'

# 4 — no stash to restore from: no-op, nothing created.
setup_boot current yes no
run_restore; rc=$?
assert "no stash: overlay not created"             '[ ! -f "${LAST_OVL}" ]'
assert "no stash: exit 0"                           '[ "'"$rc"'" -eq 0 ]'

# 5 — Raspberry Pi OS plain layout also restores (helper is layout-agnostic).
setup_boot plain yes yes
run_restore
assert "plain overlays: restores missing overlay"  '[ -f "${LAST_OVL}" ]'

# 6 — current/overlays wins when both directories exist.
setup_boot current yes yes
mkdir -p "${BOOT}/overlays"
run_restore
assert "both dirs: restores into current/overlays"  '[ -f "${BOOT}/current/overlays/x120x.dtbo" ]'
assert "both dirs: leaves plain overlays empty"      '[ ! -f "${BOOT}/overlays/x120x.dtbo" ]'

# 7 — no overlays directory at all: no-op, exit 0 (never fails an apt run).
setup_boot none yes yes
run_restore; rc=$?
assert "no overlays dir: exit 0"                    '[ "'"$rc"'" -eq 0 ]'

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
