#!/usr/bin/env bash
# tests/test-ini-blocks.sh — INI block install/remove round-trip, the
# legacy-cleanup helpers, and the uninstaller's [all]-orphan perl.
#
# Functions are sed-extracted from install.sh / uninstall.sh (the same
# technique as tests/test-install.sh) and run against temp fixtures.
#
# Run:  bash tests/test-ini-blocks.sh
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
UNINSTALL_SH="${HERE}/../uninstall.sh"
COMMON_SH="${HERE}/../lib/common.sh"

WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT

# Logging stubs (install_ini_block calls warn; the rest are silent).
info() { :; }; ok() { :; }; warn() { :; }; die() { echo "die:$*" >&2; return 1; }

# Extract the marker vars + functions under test.  Each closing brace is
# the first column-0 "}" after its opener, which the sed ranges rely on.
eval "$(sed -n '/^X120X_MARKER_BEGIN_PREFIX=/,/^X120X_MARKER_END_PREFIX=/p' "${COMMON_SH}")"
eval "$(sed -n '/^install_ini_block() {/,/^}/p'  "${INSTALL_SH}")"
eval "$(sed -n '/^remove_ini_block() {/,/^}/p'    "${UNINSTALL_SH}")"
eval "$(sed -n '/^clean_legacy_logind() {/,/^}/p' "${COMMON_SH}")"
eval "$(sed -n '/^clean_legacy_upower() {/,/^}/p' "${COMMON_SH}")"
# The exact [all]-orphan perl program (extracted, not copied, to avoid drift).
PERL_ALL=$(sed -n "s/^[[:space:]]*perl -i -0pe '\([^']*\)'.*/\1/p" "${UNINSTALL_SH}")
[ -n "${PERL_ALL}" ] || { echo "could not extract [all] perl from uninstall.sh" >&2; exit 2; }

PASS=0; FAIL=0
assert() {
    if eval "$2" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf '  \033[0;32mPASS\033[0m %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s   [%s]\n' "$1" "$2"
    fi
}

TAG="logind-low-battery"

# ---------------------------------------------------------------------------
echo "install_ini_block <-> remove_ini_block round-trip"
# ---------------------------------------------------------------------------
# For files that already contain the target section, install then remove is
# byte-identical — including a user-owned key and a user trailing blank line.
roundtrip_ok() {  # name  printf-content
    local o="${WORK}/o" f="${WORK}/f"
    printf '%b' "$2" > "$o"; cp "$o" "$f"
    install_ini_block "$f" "Login" "${TAG}" "HandleLowBattery=poweroff" >/dev/null 2>&1
    remove_ini_block  "$f" "${TAG}" >/dev/null 2>&1
    assert "$1" 'cmp -s "'"$o"'" "'"$f"'"'
}
roundtrip_ok "section present, single trailing newline"  '[Login]\n#NAutoVTs=6\n'
roundtrip_ok "section present, user key inside"          '[Login]\nHandleLowBattery=ignore\n'
roundtrip_ok "section present, user trailing blank line" '[Login]\n#NAutoVTs=6\n\n'
roundtrip_ok "section present, two user keys"            '[Login]\nKillUserProcesses=no\nIdleAction=ignore\n'

# No target section: install adds the header.  The uninstaller's documented
# contract is to never touch lines outside its markers, so the header is left
# behind (NOT byte-identical) — assert the block is cleanly gone and every
# user line survives, not cmp.
{
    o="${WORK}/o"; f="${WORK}/f"
    printf '# other file\nKeyX=1\n' > "$o"; cp "$o" "$f"
    install_ini_block "$f" "Login" "${TAG}" "HandleLowBattery=poweroff" >/dev/null 2>&1
    remove_ini_block  "$f" "${TAG}" >/dev/null 2>&1
    assert "no-section: our block removed"        '! grep -q "x120x-dkms: ${TAG}" "'"$f"'"'
    assert "no-section: HandleLowBattery gone"    '! grep -q "HandleLowBattery" "'"$f"'"'
    assert "no-section: user line KeyX preserved" 'grep -qx "KeyX=1" "'"$f"'"'
}

# ---------------------------------------------------------------------------
echo "install_ini_block specifics"
# ---------------------------------------------------------------------------
# Header created when absent.
printf 'KeyX=1\n' > "${WORK}/f"
install_ini_block "${WORK}/f" "UPower" "t" "A=1" >/dev/null 2>&1
assert "creates [UPower] header when absent" 'grep -qx "\[UPower\]" "${WORK}/f"'
assert "writes the key inside the block"     'grep -qx "A=1" "${WORK}/f"'

# Idempotent: running twice leaves exactly one block, one begin + one end.
printf '[Login]\n#x=1\n' > "${WORK}/f"
install_ini_block "${WORK}/f" "Login" "${TAG}" "HandleLowBattery=poweroff" >/dev/null 2>&1
install_ini_block "${WORK}/f" "Login" "${TAG}" "HandleLowBattery=poweroff" >/dev/null 2>&1
assert "idempotent: exactly one begin marker" '[ "$(grep -c ">>> x120x-dkms: ${TAG}" "${WORK}/f")" -eq 1 ]'
assert "idempotent: exactly one end marker"   '[ "$(grep -c "<<< x120x-dkms: ${TAG}" "${WORK}/f")" -eq 1 ]'
assert "idempotent: one HandleLowBattery line" '[ "$(grep -c "^HandleLowBattery=poweroff$" "${WORK}/f")" -eq 1 ]'

# Reinstall is byte-identical: install once, snapshot, install again and
# compare — guards against a blank line accumulating before the block.
printf '[Login]\nUserKey=1\n' > "${WORK}/f"
install_ini_block "${WORK}/f" "Login" "${TAG}" "HandleLowBattery=poweroff" >/dev/null 2>&1
cp "${WORK}/f" "${WORK}/f.once"
install_ini_block "${WORK}/f" "Login" "${TAG}" "HandleLowBattery=poweroff" >/dev/null 2>&1
assert "reinstall: byte-identical (no blank accumulation)" 'cmp -s "${WORK}/f.once" "${WORK}/f"'

# User lines outside the markers are never modified.
printf '[Login]\nUserKey=keep-me\n' > "${WORK}/f"
install_ini_block "${WORK}/f" "Login" "${TAG}" "HandleLowBattery=poweroff" >/dev/null 2>&1
assert "user line outside markers untouched" 'grep -qx "UserKey=keep-me" "${WORK}/f"'

# ---------------------------------------------------------------------------
echo "remove_ini_block specifics"
# ---------------------------------------------------------------------------
# File without our block is untouched (byte-identical).
printf '[Login]\nUserKey=1\n\n[Other]\nx=2\n' > "${WORK}/o"; cp "${WORK}/o" "${WORK}/f"
remove_ini_block "${WORK}/f" "${TAG}" >/dev/null 2>&1
assert "no block present: file untouched" 'cmp -s "${WORK}/o" "${WORK}/f"'

# User content before the block is preserved; only the block goes.
printf '[Login]\nUserKey=1\n' > "${WORK}/f"
install_ini_block "${WORK}/f" "Login" "${TAG}" "HandleLowBattery=poweroff" >/dev/null 2>&1
remove_ini_block  "${WORK}/f" "${TAG}" >/dev/null 2>&1
assert "remove: user key preserved" 'grep -qx "UserKey=1" "${WORK}/f"'
assert "remove: block gone"         '! grep -q "x120x-dkms" "${WORK}/f"'

# ---------------------------------------------------------------------------
echo "clean_legacy_logind / clean_legacy_upower"
# ---------------------------------------------------------------------------
# Removes exactly the documented legacy strings.
printf '# Added by x120x-dkms installer\nHandleLowBattery=poweroff\n[Login]\nKeep=1\n' > "${WORK}/f"
clean_legacy_logind "${WORK}/f" >/dev/null 2>&1
assert "legacy logind: removes bare HandleLowBattery=poweroff" '! grep -qx "HandleLowBattery=poweroff" "${WORK}/f"'
assert "legacy logind: removes installer comment" '! grep -q "Added by x120x-dkms" "${WORK}/f"'
assert "legacy logind: keeps user line" 'grep -qx "Keep=1" "${WORK}/f"'

# Never uncomments a deliberate #HandleLowBattery=ignore.
printf '#HandleLowBattery=ignore\n' > "${WORK}/f"
clean_legacy_logind "${WORK}/f" >/dev/null 2>&1
assert "legacy logind: does NOT uncomment #HandleLowBattery=ignore" 'grep -qx "#HandleLowBattery=ignore" "${WORK}/f"'

# Leaves near-miss lines (trailing comment / different value) alone.
printf 'HandleLowBattery=poweroff # mine\nHandleLowBattery=hibernate\n' > "${WORK}/f"
clean_legacy_logind "${WORK}/f" >/dev/null 2>&1
assert "legacy logind: leaves 'poweroff # mine'" 'grep -qx "HandleLowBattery=poweroff # mine" "${WORK}/f"'
assert "legacy logind: leaves '=hibernate'"      'grep -qx "HandleLowBattery=hibernate" "${WORK}/f"'

# UPower: removes documented bare lines, keeps user content.
printf 'CriticalPowerAction=PowerOff\nNoPollBatteries=true\n[UPower]\nUsePercentageForPolicy=true\n' > "${WORK}/f"
clean_legacy_upower "${WORK}/f" >/dev/null 2>&1
assert "legacy upower: removes bare CriticalPowerAction=PowerOff" '! grep -qx "CriticalPowerAction=PowerOff" "${WORK}/f"'
assert "legacy upower: removes bare NoPollBatteries=true" '! grep -qx "NoPollBatteries=true" "${WORK}/f"'
assert "legacy upower: keeps user UsePercentageForPolicy" 'grep -qx "UsePercentageForPolicy=true" "${WORK}/f"'

# ---------------------------------------------------------------------------
echo "config.txt [all]-orphan perl"
# ---------------------------------------------------------------------------
run_all_perl() { perl -i -0pe "${PERL_ALL}" "$1" 2>/dev/null || true; }

# Orphaned [all] followed by another section header -> removed.
printf '[cm4]\nfoo=1\n\n[all]\n[pi5]\nbar=2\n' > "${WORK}/f"
run_all_perl "${WORK}/f"
assert "[all] before another header: removed" '! grep -qx "\[all\]" "${WORK}/f"'
assert "[all] before another header: [pi5] kept" 'grep -qx "\[pi5\]" "${WORK}/f"'

# Orphaned [all] at end of file -> removed.
printf '[cm4]\nfoo=1\n\n[all]\n' > "${WORK}/f"
run_all_perl "${WORK}/f"
assert "[all] at EOF: removed"      '! grep -qx "\[all\]" "${WORK}/f"'
assert "[all] at EOF: foo=1 kept"   'grep -qx "foo=1" "${WORK}/f"'

# [all] still containing user lines -> preserved.
printf '[cm4]\nfoo=1\n[all]\ndtparam=audio=on\n' > "${WORK}/f"
run_all_perl "${WORK}/f"
assert "[all] with content: preserved" 'grep -qx "\[all\]" "${WORK}/f"'
assert "[all] with content: user line kept" 'grep -qx "dtparam=audio=on" "${WORK}/f"'

# No [all] at all -> unchanged (byte-identical).
printf '[cm4]\nfoo=1\n' > "${WORK}/o"; cp "${WORK}/o" "${WORK}/f"
run_all_perl "${WORK}/f"
assert "no [all]: file unchanged" 'cmp -s "${WORK}/o" "${WORK}/f"'

# ---------------------------------------------------------------------------
echo "Step 7 overlay-presence check (anchored)"
# ---------------------------------------------------------------------------
# The installer's "already present" grep must not treat a commented-out or
# prefixed line as installed, or it would skip appending the overlay.
OVL_RE=$(sed -n "s/.*grep -qE '\([^']*dtoverlay[^']*\)'.*/\1/p" "${INSTALL_SH}")
[ -n "${OVL_RE}" ] || { echo "could not extract overlay grep from install.sh" >&2; exit 2; }
matches() { printf '%s\n' "$1" | grep -qE "${OVL_RE}"; }
assert "overlay: active line matches"          'matches "dtoverlay=x120x"'
assert "overlay: leading whitespace matches"   'matches "    dtoverlay=x120x"'
assert "overlay: commented-out does NOT match" '! matches "#dtoverlay=x120x"'
assert "overlay: prefixed does NOT match"       '! matches "xdtoverlay=x120x"'
assert "overlay: suffixed does NOT match"       '! matches "dtoverlay=x120x-extra"'

# Same anchoring for the gpio=6=pu sibling check.
GPIO_RE=$(sed -n "s/.*grep -qE '\([^']*gpio=6=pu[^']*\)'.*/\1/p" "${INSTALL_SH}")
[ -n "${GPIO_RE}" ] || { echo "could not extract gpio grep from install.sh" >&2; exit 2; }
gmatches() { printf '%s\n' "$1" | grep -qE "${GPIO_RE}"; }
assert "gpio: active line matches"          'gmatches "gpio=6=pu"'
assert "gpio: leading whitespace matches"   'gmatches "    gpio=6=pu"'
assert "gpio: commented-out does NOT match" '! gmatches "#gpio=6=pu"'
assert "gpio: suffixed does NOT match"       '! gmatches "gpio=6=pux"'

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
