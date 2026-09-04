#!/usr/bin/env bash
# GNU-vs-BSD `date` fallback ORDER across the repo (issue #1587).
#
# WHY THIS SUITE EXISTS
#
# GNU coreutils `date` reads `-r` as a FILE and prints that file's mtime; only
# BSD `date` reads it as epoch seconds. A chain written BSD-first —
#
#   date -u -r "$epoch" +FMT 2>/dev/null || date -u -d "@$epoch" +FMT 2>/dev/null
#
# — therefore works on GNU hosts only by accident: the `-r` arm normally fails
# because no such file exists, and execution falls through to the GNU arm.
#
# It stops being an accident the moment a file happens to be NAMED for the
# epoch. Then GNU `date -r` succeeds and prints that file's mtime as if it were
# the requested time: silently, exit 0, no marker. That is the same
# unmarked-wrong-time class issue #1529 exists to remove.
#
# The fix is an ordering one — try the GNU `-d "@"` arm FIRST, keep both arms:
#
#   date -u -d "@$epoch" +FMT 2>/dev/null || date -u -r "$epoch" +FMT 2>/dev/null
#
# Both arms are required. GNU alone strands macOS (BSD has no `-d`), BSD alone
# strands GNU. Measured during PR #1579: GNU always satisfies `-d @` and so never
# reaches `-r`; BSD rejects `-d` with `illegal option` at status 1 and ZERO bytes
# on stdout, so it falls through to `-r` unchanged.
#
# HOW THE ENVIRONMENT IS SIMULATED
#
# The defect is invisible on a BSD host and needs a hostile filesystem on a GNU
# one, so neither platform reproduces it unaided. A `date` shim carrying GNU
# semantics is prepended to PATH instead, making the suite platform-independent:
#
#   - `-d @EPOCH`  -> formats that epoch (delegated to the real binary)
#   - `-r ARG`     -> treats ARG as a FILENAME; prints the fixed sentinel
#                     DECOY-MTIME when the file exists, exits 1 when it does not
#   - `+%s`        -> a FROZEN clock, so helpers that compute "N units ago"
#                     internally land on a deterministic epoch we can plant a
#                     decoy for
#   - anything else -> delegated unchanged to the real binary
#
# The real binary's absolute path is baked into the shim at creation time. It is
# NOT looked up with `command -v` at call time: the shim's own directory is on
# PATH by then, so that would resolve to the shim and recurse forever.
#
# WHAT IS ASSERTED, PER SITE
#
#   1. NEGATIVE CONTROL — the reconstructed pre-fix BSD-first chain really does
#      render the decoy under the shim. Without this the fix proof below could
#      pass vacuously against a drifted shim.
#   2. FIX PROOF — the SHIPPED chain, extracted from the real source file rather
#      than retyped here, renders the true epoch and not the decoy.
#   3. STRUCTURAL — the shipped source keeps BOTH arms with the GNU `-d "@"` arm
#      before the BSD `-r "` arm, so the order cannot silently flip back.
#
# Sites 1-4 were BSD-first and are fixed by this change; sites 5-7 were already
# GNU-first and are pinned here so they stay that way.
#
# DELIBERATELY NOT COVERED
#
#   - `.claude/scripts/tests/overrun-check-tzdata.test.sh` holds OLD_UTC_CHAIN,
#     a FIXTURE of the pre-fix chain used as that suite's own negative control.
#     Reordering it would silently defeat that control.
#   - The repo's many `date -j -f` / `date -jf` BSD-first chains. `-j` is
#     BSD-only and GNU rejects it outright, so there is no filename-collision
#     failure mode there — a different portability question, not this defect.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "cannot resolve repo root" >&2; exit 1; }
cd "$REPO_ROOT" || { echo "cannot cd to repo root" >&2; exit 1; }

RELEASE_DECIDE="$REPO_ROOT/.claude/scripts/release-decide.sh"
STALE_CLEANUP="$REPO_ROOT/.claude/scripts/stale-cleanup.sh"
CHIP_REGISTRY="$REPO_ROOT/.claude/scripts/chip-offer-registry.sh"
ISSUE_CLAIM_TEST="$REPO_ROOT/.claude/scripts/tests/issue-claim.test.sh"
PR_PREFLIGHT_TEST="$REPO_ROOT/.claude/scripts/tests/pr-preflight.test.sh"
USAGE_HORIZON_TEST="$REPO_ROOT/.claude/scripts/tests/usage-horizon.test.sh"
USAGE_LIMIT_TEST="$REPO_ROOT/.claude/hooks/tests/usage-limit-record-handoff-pointer.test.sh"

for f in "$RELEASE_DECIDE" "$STALE_CLEANUP" "$CHIP_REGISTRY" "$ISSUE_CLAIM_TEST" \
         "$PR_PREFLIGHT_TEST" "$USAGE_HORIZON_TEST" "$USAGE_LIMIT_TEST"; do
  [[ -f "$f" ]] || { echo "missing source under test: $f" >&2; exit 1; }
done

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}
check_ne() {
  local desc="$1" forbidden="$2" actual="$3"
  if [[ "$actual" != "$forbidden" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (value must not be '$forbidden')"
  fi
}

# ---------------------------------------------------------------------------
# The shim. REAL_DATE is resolved BEFORE $TMP/bin joins PATH.
# ---------------------------------------------------------------------------
REAL_DATE="$(command -v date)" || { echo "no date binary on PATH" >&2; exit 1; }
case "$REAL_DATE" in
  /*) : ;;
  *) echo "date resolved to a non-absolute path: $REAL_DATE" >&2; exit 1 ;;
esac

DECOY_SENTINEL="DECOY-MTIME"
FROZEN_NOW=1788404400          # 2026-09-04T07:00:00Z — arbitrary but fixed
DECOY_EPOCH=$(( FROZEN_NOW - 3600 ))

GNUBIN="$TMP/gnubin"
mkdir -p "$GNUBIN"
cat > "$GNUBIN/date" <<'GNUDATE'
#!/usr/bin/env bash
# GNU-coreutils-semantics `date` shim.
#   -d @EPOCH  -> format that epoch (delegated to the real binary)
#   -r ARG     -> ARG is a FILENAME; emit a fixed sentinel so any chain reaching
#                 this arm is unmistakable in the output rather than merely off
#                 by some hours. Exit 1 when the file does not exist, exactly as
#                 GNU date does.
#   +%s        -> a frozen clock, so "N ago" helpers are deterministic.
set -uo pipefail
real="${SHIM_REAL_DATE:?SHIM_REAL_DATE must be set}"
now="${SHIM_NOW_EPOCH:?SHIM_NOW_EPOCH must be set}"
sentinel="${SHIM_DECOY_SENTINEL:?SHIM_DECOY_SENTINEL must be set}"
mode=""; val=""; fmt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) shift ;;
    -d) mode=d; val="${2:-}"; shift 2 ;;
    -r) mode=r; val="${2:-}"; shift 2 ;;
    +*) fmt="${1#+}"; shift ;;
    *)  shift ;;
  esac
done
case "$mode" in
  d) # GNU only understands @EPOCH here for our purposes; anything else is a
     # parse the real binary should answer for.
     [[ "$val" == @* ]] || exit 1
     # The real binary may itself be BSD, which has no -d: try both spellings.
     "$real" -u -d "@${val#@}" +"$fmt" 2>/dev/null \
       || "$real" -u -r "${val#@}" +"$fmt" ;;
  r) [[ -e "$val" ]] || exit 1
     printf '%s\n' "$sentinel" ;;
  *) if [[ "$fmt" == "%s" ]]; then printf '%s\n' "$now"; else "$real" -u +"$fmt"; fi ;;
esac
GNUDATE
chmod +x "$GNUBIN/date"

# The decoy: a file NAMED for the epoch, in the directory the chains run from.
: > "$TMP/$DECOY_EPOCH"

run_under_shim() {  # $1 = shell source to define, $2 = the call to make
  ( cd "$TMP" \
      && SHIM_REAL_DATE="$REAL_DATE" SHIM_NOW_EPOCH="$FROZEN_NOW" \
         SHIM_DECOY_SENTINEL="$DECOY_SENTINEL" PATH="$GNUBIN:$PATH" \
         bash -c "$1"$'\n'"$2" )
}

expect_fmt() {  # $1 = epoch, $2 = strftime format (without the leading +)
  "$REAL_DATE" -u -d "@$1" +"$2" 2>/dev/null || "$REAL_DATE" -u -r "$1" +"$2"
}

# Confirm the shim is what it claims before relying on it.
check_eq "shim: -r on the decoy file yields the sentinel (GNU semantics)" \
  "$DECOY_SENTINEL" "$(run_under_shim ':' "date -u -r $DECOY_EPOCH +%FT%TZ")"
check_eq "shim: -r on a name with no file exits non-zero and prints nothing" \
  "|1" "$(run_under_shim ':' "out=\$(date -u -r 999999991 +%FT%TZ 2>/dev/null); printf '%s|%s' \"\$out\" \"\$?\"")"
check_eq "shim: -d @EPOCH renders the true epoch" \
  "$(expect_fmt "$DECOY_EPOCH" '%FT%TZ')" \
  "$(run_under_shim ':' "date -u -d @$DECOY_EPOCH +%FT%TZ")"
check_eq "shim: bare +%s is frozen so 'N ago' helpers are deterministic" \
  "$FROZEN_NOW" "$(run_under_shim ':' 'date -u +%s')"

# ---------------------------------------------------------------------------
# Ordering helpers.
# ---------------------------------------------------------------------------
GNU_ARM='-d "@'
BSD_ARM='-r "'

first_index() {  # $1 = haystack, $2 = needle -> 0-based byte offset, or -1
  local haystack="$1" needle="$2" prefix
  [[ "$haystack" == *"$needle"* ]] || { printf '%s\n' -1; return; }
  prefix="${haystack%%"$needle"*}"
  printf '%s\n' "${#prefix}"
}

check_gnu_first() {  # $1 = description, $2 = source snippet
  local desc="$1" snippet="$2" g b
  g="$(first_index "$snippet" "$GNU_ARM")"
  b="$(first_index "$snippet" "$BSD_ARM")"
  if [[ "$g" -ge 0 && "$b" -ge 0 && "$g" -lt "$b" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc keeps both arms with the GNU form first"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL — $desc branch order regressed or an arm was dropped (gnu offset '$g', bsd offset '$b')"
  fi
}

require_snippet() {  # $1 = label, $2 = extracted text
  [[ -n "$2" ]] && return 0
  FAIL=$((FAIL + 1)); echo "FAIL — could not extract $1 from its source file"
  return 1
}

# ---------------------------------------------------------------------------
# Site 1 — release-decide.sh WINDOW_OPENS (production; named in #1587)
# ---------------------------------------------------------------------------
RELEASE_LINE="$(grep -m1 'WINDOW_OPENS=.*date -u' "$RELEASE_DECIDE" | sed 's/^[[:space:]]*//')"
if require_snippet "release-decide.sh WINDOW_OPENS" "$RELEASE_LINE"; then
  RELEASE_OLD='WINDOW_OPENS="\"$(date -u -r "$WINDOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$WINDOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)\""'
  RELEASE_CALL='printf "%s\n" "$WINDOW_OPENS"'
  RELEASE_PRELUDE="WINDOW_EPOCH=$DECOY_EPOCH"
  RELEASE_EXPECT="\"$(expect_fmt "$DECOY_EPOCH" '%Y-%m-%dT%H:%M:%SZ')\""

  check_eq "negative control: release-decide.sh's OLD BSD-first WINDOW_OPENS renders the decoy" \
    "\"$DECOY_SENTINEL\"" \
    "$(run_under_shim "$RELEASE_PRELUDE"$'\n'"$RELEASE_OLD" "$RELEASE_CALL")"
  check_eq "shipped release-decide.sh WINDOW_OPENS renders the true epoch" \
    "$RELEASE_EXPECT" \
    "$(run_under_shim "$RELEASE_PRELUDE"$'\n'"$RELEASE_LINE" "$RELEASE_CALL")"
  check_ne "shipped release-decide.sh WINDOW_OPENS never renders the decoy" \
    "\"$DECOY_SENTINEL\"" \
    "$(run_under_shim "$RELEASE_PRELUDE"$'\n'"$RELEASE_LINE" "$RELEASE_CALL")"
  check_gnu_first "release-decide.sh WINDOW_OPENS" "$RELEASE_LINE"
fi

# ---------------------------------------------------------------------------
# Site 2 — stale-cleanup.sh ts_to_date (production; found by the #1587 sweep)
# ---------------------------------------------------------------------------
TS_TO_DATE="$(sed -n '/^ts_to_date() {$/,/^}$/p' "$STALE_CLEANUP")"
if require_snippet "stale-cleanup.sh ts_to_date" "$TS_TO_DATE"; then
  TS_TO_DATE_OLD='ts_to_date() {
  local ts="$1"
  if date -r "$ts" +%Y-%m-%d 2>/dev/null; then return; fi
  date -d "@$ts" +%Y-%m-%d 2>/dev/null || echo "?"
}'
  check_eq "negative control: stale-cleanup.sh's OLD BSD-first ts_to_date renders the decoy" \
    "$DECOY_SENTINEL" \
    "$(run_under_shim "$TS_TO_DATE_OLD" "ts_to_date $DECOY_EPOCH")"
  check_eq "shipped stale-cleanup.sh ts_to_date renders the true epoch" \
    "$(expect_fmt "$DECOY_EPOCH" '%Y-%m-%d')" \
    "$(run_under_shim "$TS_TO_DATE" "ts_to_date $DECOY_EPOCH")"
  check_gnu_first "stale-cleanup.sh ts_to_date" "$TS_TO_DATE"
fi

# ---------------------------------------------------------------------------
# Site 3 — issue-claim.test.sh iso_ago (test helper; named in #1587)
# ---------------------------------------------------------------------------
ISO_AGO="$(sed -n '/^iso_ago() {$/,/^}$/p' "$ISSUE_CLAIM_TEST")"
if require_snippet "issue-claim.test.sh iso_ago" "$ISO_AGO"; then
  ISO_AGO_OLD='iso_ago() {
  local hours="$1" epoch
  epoch=$(( $(date -u +%s) - hours * 3600 ))
  date -u -r "$epoch" +%FT%TZ 2>/dev/null && return 0
  date -u -d "@$epoch" +%FT%TZ 2>/dev/null && return 0
  echo "iso_ago: no usable date(1) spelling" >&2
  return 1
}'
  check_eq "negative control: issue-claim.test.sh's OLD BSD-first iso_ago renders the decoy" \
    "$DECOY_SENTINEL" "$(run_under_shim "$ISO_AGO_OLD" 'iso_ago 1')"
  check_eq "shipped issue-claim.test.sh iso_ago renders the true epoch" \
    "$(expect_fmt "$DECOY_EPOCH" '%FT%TZ')" "$(run_under_shim "$ISO_AGO" 'iso_ago 1')"
  check_gnu_first "issue-claim.test.sh iso_ago" "$ISO_AGO"
fi

# ---------------------------------------------------------------------------
# Site 4 — usage-limit-record-handoff-pointer.test.sh stamp_ago
#          (test helper; found by the #1587 sweep)
# ---------------------------------------------------------------------------
STAMP_AGO="$(sed -n '/^stamp_ago() {/,/^}$/p' "$USAGE_LIMIT_TEST")"
if require_snippet "usage-limit-record-handoff-pointer.test.sh stamp_ago" "$STAMP_AGO"; then
  STAMP_AGO_OLD='stamp_ago() {
  local epoch=$(( $(date -u +%s) - $1 ))
  date -u -r "$epoch" +%Y%m%d%H%M 2>/dev/null && return 0
  date -u -d "@$epoch" +%Y%m%d%H%M 2>/dev/null && return 0
  return 1
}'
  check_eq "negative control: the OLD BSD-first stamp_ago renders the decoy" \
    "$DECOY_SENTINEL" "$(run_under_shim "$STAMP_AGO_OLD" 'stamp_ago 3600')"
  check_eq "shipped stamp_ago renders the true epoch" \
    "$(expect_fmt "$DECOY_EPOCH" '%Y%m%d%H%M')" "$(run_under_shim "$STAMP_AGO" 'stamp_ago 3600')"
  check_gnu_first "usage-limit-record-handoff-pointer.test.sh stamp_ago" "$STAMP_AGO"
fi

# ---------------------------------------------------------------------------
# Sites 5-7 — already GNU-first when #1587 was filed. Pinned so a future edit
# cannot quietly reintroduce the defect in a site nobody is watching.
# ---------------------------------------------------------------------------
CHIP_EXPIRES="$(sed -n '/EXPIRES_AT="\$(date/,/printf .%s. "\${NOW}")"/p' "$CHIP_REGISTRY")"
require_snippet "chip-offer-registry.sh EXPIRES_AT" "$CHIP_EXPIRES" \
  && check_gnu_first "chip-offer-registry.sh EXPIRES_AT" "$CHIP_EXPIRES"

ISO_FROM_NOW="$(sed -n '/^iso_from_now() {/,/^}$/p' "$PR_PREFLIGHT_TEST")"
require_snippet "pr-preflight.test.sh iso_from_now" "$ISO_FROM_NOW" \
  && check_gnu_first "pr-preflight.test.sh iso_from_now" "$ISO_FROM_NOW"

# usage-horizon.test.sh deliberately uses an ISOLATED-try, regex-validated form
# rather than a naive `||` chain — the GNU arm must still come first, and the
# validation gate is what stops a decoy render being trusted even so.
BACKDATE_READING="$(sed -n '/^backdate_reading() {/,/^}$/p' "$USAGE_HORIZON_TEST")"
if require_snippet "usage-horizon.test.sh backdate_reading" "$BACKDATE_READING"; then
  check_gnu_first "usage-horizon.test.sh backdate_reading" "$BACKDATE_READING"
  if [[ "$BACKDATE_READING" == *'[0-9]{4}-[0-9]{2}-[0-9]{2}T'* ]]; then
    PASS=$((PASS + 1)); echo "ok   — usage-horizon.test.sh backdate_reading keeps its result-shape gate"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — usage-horizon.test.sh backdate_reading lost its result-shape gate"
  fi
fi

# ---------------------------------------------------------------------------
# The pre-fix fixture in overrun-check-tzdata.test.sh must stay BSD-first: it is
# that suite's negative control, and reordering it would make its fix proof pass
# vacuously. Asserted here so a future repo-wide "fix all the chains" sweep
# cannot break it silently.
# ---------------------------------------------------------------------------
TZDATA_TEST="$REPO_ROOT/.claude/scripts/tests/overrun-check-tzdata.test.sh"
if [[ -f "$TZDATA_TEST" ]]; then
  OLD_CHAIN_FIXTURE="$(sed -n "/^OLD_UTC_CHAIN='format_utc_clock() {$/,/^}'$/p" "$TZDATA_TEST")"
  if require_snippet "overrun-check-tzdata.test.sh OLD_UTC_CHAIN" "$OLD_CHAIN_FIXTURE"; then
    OG="$(first_index "$OLD_CHAIN_FIXTURE" '-u -d "@')"
    OB="$(first_index "$OLD_CHAIN_FIXTURE" '-u -r "')"
    if [[ "$OB" -ge 0 && "$OG" -ge 0 && "$OB" -lt "$OG" ]]; then
      PASS=$((PASS + 1)); echo "ok   — overrun-check-tzdata.test.sh's OLD_UTC_CHAIN fixture stays BSD-first"
    else
      FAIL=$((FAIL + 1))
      echo "FAIL — OLD_UTC_CHAIN was 'fixed' — that suite's negative control now passes vacuously (bsd '$OB', gnu '$OG')"
    fi
  fi
fi

echo
echo "date-r-ordering.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
