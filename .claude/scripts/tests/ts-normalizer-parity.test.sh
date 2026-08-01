#!/usr/bin/env bash
# ts-normalizer-parity.test.sh — Drift guard for the #836 timestamp rule
# (issue #885).
#
# THE BUG THIS EXISTS TO CATCH
#   merge-gate.sh orders review/commit timestamps with bash norm_ts (now
#   lib/ts-normalizer.sh). escalate-review.sh orders the SAME pairs with a jq
#   `def canon_ts:` inside its own program, because jq cannot source a bash
#   function. Escalation is a CALLER of the gate, so if the two ever disagree
#   escalation can report gate_met on an approval the gate rules stale.
#
#   That happened twice on PR #883, and both times only human review caught it:
#     1. canon_ts dropped fractional seconds while norm_ts kept them, so
#        "…49.900Z" and "…49Z" compared EQUAL on one side and ordered on the
#        other.
#     2. The repair then normalised "+0000" on one side only — the same
#        divergence in a new spelling, introduced by the fix for the first.
#        A superset on one side of a must-agree pair is divergence, not slack.
#
#   So this suite does not re-type either implementation. It EXTRACTS the real
#   jq def blocks from the shipped scripts at runtime and sources the real bash
#   library, then runs both over the spelling matrix. Editing production code is
#   what the test observes; a divergent edit fails here instead of in review.
#
# ALSO PINNED
#   review-substance.sh's canon_ts is deliberately DIFFERENT (drops the
#   fraction, folds the UTC spellings onto "Z"). That is safe because every
#   timestamp it compares passes through that one function. A future "unify all
#   three" refactor would silently change its ordering, so the divergence is
#   asserted rather than merely commented.
#
# Requires jq. Run from anywhere:
#   bash .claude/scripts/tests/ts-normalizer-parity.test.sh
set -uo pipefail

# Anchor on this file, not the caller's cwd: run-hook-tests.sh cds to the repo
# root first, but the header above promises this suite runs from anywhere and a
# bare `git rev-parse` would resolve against wherever the caller happened to be.
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel)" || exit 1
SCRIPTS="$REPO_ROOT/.claude/scripts"
LIB="$SCRIPTS/lib/ts-normalizer.sh"
ESCALATE="$SCRIPTS/escalate-review.sh"
SUBSTANCE="$SCRIPTS/review-substance.sh"
MERGE_GATE="$SCRIPTS/merge-gate.sh"

# No temp dir: this suite only reads the shipped scripts and evaluates jq
# programs held in shell variables, so it writes nothing to disk.

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   — $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL — $1" >&2; }
check_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
check_ne() { # desc not_expected actual
  if [[ "$2" != "$3" ]]; then ok "$1"; else bad "$1 (expected something OTHER than '$2')"; fi
}
# Fatal: something this suite depends on is broken, so the remaining assertions
# would be meaningless. Reports the counters accumulated so far rather than a
# fabricated 0/1, and always exits non-zero.
die() {
  echo "FAIL — $1" >&2
  FAIL=$((FAIL + 1))
  echo
  echo "== summary == $PASS passed, $FAIL failed (aborted early)"
  exit 1
}

############################################################################
# Load the real bash normaliser
############################################################################
[[ -r "$LIB" ]] || die "lib/ts-normalizer.sh not found at $LIB"
# shellcheck source=../lib/ts-normalizer.sh
source "$LIB" || die "could not source $LIB"
declare -F norm_ts >/dev/null || die "norm_ts is not defined after sourcing $LIB"

############################################################################
# Extract the real jq def blocks from the shipped scripts
#
# The def spans several lines and contains an internal `;` (inside sub(…; …)),
# so "up to the first semicolon" would truncate it. Both defs terminate on a
# line ending in `end;`, so take from the `def canon_ts:` line through the first
# such line. Collapsing the def onto one line still works — awk evaluates all
# three rules against that single line, so it opens, prints, and closes there.
#
# Every failure mode below is fatal, never a skip: a test that silently stops
# comparing is exactly the false-clean this suite exists to prevent.
############################################################################
DEF_RE='^[[:space:]]*def canon_ts:'

extract_canon_ts() { # <file>
  awk -v re="$DEF_RE" '
    $0 ~ re { inblock = 1 }
    inblock { print }
    inblock && /end;[[:space:]]*$/ { exit }
  ' "$1"
}

count_defs() { # <file>
  grep -c "$DEF_RE" "$1"
}

# Build a one-expression jq program from a shipped file: the extracted def block
# followed by the call, so `jq -rn --arg t <ts> "$BUILT_JQ"` evaluates the real
# rule. Every failure path is fatal.
#
# The result lands in the global BUILT_JQ rather than on stdout ON PURPOSE:
# `X="$(build_jq_program …)"` would run this in a SUBSHELL, where die's `exit 1`
# kills only the subshell and the suite carries on with an empty program —
# the silent-false-clean this file exists to prevent.
BUILT_JQ=""
build_jq_program() { # <file> <label>  -> sets BUILT_JQ
  local file="$1" label="$2" block n prog probe
  BUILT_JQ=""
  [[ -r "$file" ]] || die "$label: file not readable at $file"
  n="$(count_defs "$file")"
  [[ "$n" == "1" ]] || die "$label: expected exactly 1 'def canon_ts:' in $file, found $n — extraction can no longer identify the production rule"
  block="$(extract_canon_ts "$file")"
  [[ -n "$block" ]] || die "$label: extracted an EMPTY canon_ts block from $file — the def shape changed and this guard has stopped guarding"
  grep -q 'end;[[:space:]]*$' <<<"$block" || die "$label: extracted block from $file does not terminate in 'end;' — extraction truncated the def"
  # Single-quoted on purpose: `$t` is the jq variable bound by `--arg t`, not a
  # shell variable. shellcheck reports SC2016 here; expanding it would be the bug.
  prog="$block"$'\n''$t | canon_ts'

  # Prove the extracted text is a valid, runnable jq program before anything
  # depends on it. A broken extraction must fail the suite, not quietly pass.
  probe="$(jq -rn --arg t "1970-01-01T00:00:00Z" "$prog" 2>&1)" \
    || die "$label: extracted canon_ts is not a valid jq program — $probe"
  [[ "$probe" == "1970-01-01T00:00:00" || "$probe" == "1970-01-01T00:00:00Z" ]] \
    || die "$label: extracted canon_ts produced an implausible result '$probe' for a plain Z timestamp"

  BUILT_JQ="$prog"
}

command -v jq >/dev/null 2>&1 || die "jq is required by this suite"

build_jq_program "$ESCALATE" "escalate-review.sh"
GATE_JQ="$BUILT_JQ"
build_jq_program "$SUBSTANCE" "review-substance.sh"
SUBSTANCE_JQ="$BUILT_JQ"
[[ -n "$GATE_JQ" && -n "$SUBSTANCE_JQ" ]] || die "a jq program came back empty — extraction is broken"

canon_gate()      { jq -rn --arg t "$1" "$GATE_JQ"; }
canon_substance() { jq -rn --arg t "$1" "$SUBSTANCE_JQ"; }

############################################################################
echo "== norm_ts contract (lib/ts-normalizer.sh) =="
############################################################################
check_eq "bare value untouched"        "2026-08-01T10:00:16"        "$(norm_ts "2026-08-01T10:00:16")"
check_eq "Z stripped"                  "2026-08-01T10:00:16"        "$(norm_ts "2026-08-01T10:00:16Z")"
check_eq "+00:00 stripped"             "2026-08-01T10:00:16"        "$(norm_ts "2026-08-01T10:00:16+00:00")"
check_eq "+0000 stripped"              "2026-08-01T10:00:16"        "$(norm_ts "2026-08-01T10:00:16+0000")"
check_eq "fraction RETAINED under Z"   "2026-08-01T10:00:16.900000" "$(norm_ts "2026-08-01T10:00:16.900000Z")"
check_eq "fraction RETAINED under +00:00" "2026-08-01T10:00:16.900" "$(norm_ts "2026-08-01T10:00:16.900+00:00")"
check_eq "empty in, empty out"         ""                           "$(norm_ts "")"
check_eq "missing arg, empty out"      ""                           "$(norm_ts)"
check_eq "idempotent on stripped value" "2026-08-01T10:00:16"       "$(norm_ts "$(norm_ts "2026-08-01T10:00:16Z")")"
# A real non-UTC offset must NOT be mangled into a wrong instant.
check_eq "non-UTC offset left alone"   "2026-08-01T10:00:16-04:00"  "$(norm_ts "2026-08-01T10:00:16-04:00")"
# Suffix stripping must not rewrite to "Z" — a fraction under a trailing Z sorts
# the wrong way ("." 0x2E < "Z" 0x5A), which is the h6d failure.
check_ne "output does not re-append Z" "2026-08-01T10:00:16Z"       "$(norm_ts "2026-08-01T10:00:16Z")"

############################################################################
echo "== parity: norm_ts (merge-gate) vs canon_ts (escalate-review) =="
############################################################################
# The spelling matrix from issue #885 and scenarios (h6b)-(h6e) of
# escalate-review.test.sh. Every entry must normalise IDENTICALLY on both sides.
MATRIX=(
  "2026-08-01T10:00:16"
  "2026-08-01T10:00:16Z"
  "2026-08-01T10:00:16+00:00"
  "2026-08-01T10:00:16+0000"
  "2026-08-01T10:00:16.900Z"
  "2026-08-01T10:00:16.900000Z"
  "2026-08-01T10:00:16.900+00:00"
  "2026-08-01T10:00:16.900000+0000"
  "2026-08-01T10:00:22+00:00"
  "2026-08-01T10:00:22Z"
  "2026-08-01T23:59:59.999999Z"
  "2026-08-01T10:00:16-04:00"
  "2026-08-01T10:00:16+05:30"
  ""
)
for ts in "${MATRIX[@]}"; do
  check_eq "parity on '${ts:-<empty>}'" "$(norm_ts "$ts")" "$(canon_gate "$ts")"
done

############################################################################
echo "== parity at the COMPARISON level (the shape PR #883 actually got wrong) =="
############################################################################
# Normalising identically is necessary but not sufficient — what the gate and
# escalation both do is a lexicographic ORDER test. Assert the two agree on the
# verdict, not just on the strings.
cmp_bash() { # a b -> lt|gt|eq
  local a b; a="$(norm_ts "$1")"; b="$(norm_ts "$2")"
  if [[ "$a" < "$b" ]]; then echo lt; elif [[ "$a" > "$b" ]]; then echo gt; else echo eq; fi
}
cmp_jq() { # a b -> lt|gt|eq
  local a b; a="$(canon_gate "$1")"; b="$(canon_gate "$2")"
  if [[ "$a" < "$b" ]]; then echo lt; elif [[ "$a" > "$b" ]]; then echo gt; else echo eq; fi
}
check_order() { # desc expected a b
  local desc="$1" want="$2" a="$3" b="$4"
  local got_bash got_jq
  got_bash="$(cmp_bash "$a" "$b")"
  got_jq="$(cmp_jq "$a" "$b")"
  check_eq "$desc — merge-gate order"  "$want" "$got_bash"
  check_eq "$desc — escalation agrees" "$got_bash" "$got_jq"
}

# (h6b): mixed +00:00 / Z spellings of a genuinely later approval.
check_order "(h6b) approval 10:00:22+00:00 is AFTER push 10:00:16Z" \
  gt "2026-08-01T10:00:22+00:00" "2026-08-01T10:00:16Z"
# (h6e): the compact +0000 spelling of the same case. This is finding #2 on
# PR #883 — one side stripped it, the other did not.
check_order "(h6e) approval 10:00:22Z is AFTER push 10:00:16+0000" \
  gt "2026-08-01T10:00:22Z" "2026-08-01T10:00:16+0000"
# (h6c): approval EARLIER within the same second as a fractional push. This is
# finding #1 on PR #883 — dropping the fraction collapsed these to eq, so
# escalation called a gate-stale approval fresh.
check_order "(h6c) approval …16Z is BEFORE push …16.900000Z (fraction must not collapse)" \
  lt "2026-08-01T10:00:16Z" "2026-08-01T10:00:16.900000Z"
# (h6d): the mirror — a fractional approval AFTER a whole-second push. Under a
# retained trailing "Z" this inverts, because "." (0x2E) < "Z" (0x5A).
check_order "(h6d) approval …16.900000Z is AFTER push …16Z (fraction must not invert)" \
  gt "2026-08-01T10:00:16.900000Z" "2026-08-01T10:00:16Z"
# Equal instants in three different spellings must all compare eq on both sides.
check_order "equal instant, Z vs +00:00" \
  eq "2026-08-01T10:00:16Z" "2026-08-01T10:00:16+00:00"
check_order "equal instant, +00:00 vs +0000" \
  eq "2026-08-01T10:00:16+00:00" "2026-08-01T10:00:16+0000"

############################################################################
echo "== review-substance.sh canon_ts: divergence is DELIBERATE and pinned =="
############################################################################
# review-substance.sh strips the fraction and folds the UTC spellings onto "Z".
# Safe there — every timestamp it compares passes through that one function, so
# it is internally consistent and is never compared against a merge-gate value
# (issue #875). These assertions exist so a future "unify all three normalisers"
# refactor fails HERE rather than silently reordering that script's markers.
check_eq "substance folds +00:00 onto Z" \
  "2026-08-01T10:00:16Z" "$(canon_substance "2026-08-01T10:00:16+00:00")"
check_eq "substance folds +0000 onto Z" \
  "2026-08-01T10:00:16Z" "$(canon_substance "2026-08-01T10:00:16+0000")"
check_eq "substance DROPS the fraction" \
  "2026-08-01T10:00:16Z" "$(canon_substance "2026-08-01T10:00:16.900000Z")"
check_eq "substance is idempotent" \
  "2026-08-01T10:00:16Z" "$(canon_substance "$(canon_substance "2026-08-01T10:00:16.900000+0000")")"
check_eq "substance passes empty through" "" "$(canon_substance "")"

# The two rules must remain genuinely different on the inputs that define the
# difference — if these ever start matching, someone unified them.
check_ne "substance != gate on a fractional input" \
  "$(norm_ts "2026-08-01T10:00:16.900000Z")" "$(canon_substance "2026-08-01T10:00:16.900000Z")"
check_ne "substance != gate on an offset input" \
  "$(norm_ts "2026-08-01T10:00:16+00:00")" "$(canon_substance "2026-08-01T10:00:16+00:00")"

############################################################################
echo "== the divergence is one-directional, and merge-gate.sh keeps it safe =="
############################################################################
# merge-gate.sh hands review-substance.sh the SAME raw HEAD committer date it
# uses as LAST_COMMIT_TS (as push_ts), so a merge-gate value really does get
# compared here — just never ACROSS the two rules.
#
# Pin the direction of the difference: dropping the fraction makes canon_ts
# MORE permissive than norm_ts. On this pair the gate orders approval < push
# (stale) while substance sees them as equal (fresh).
GATE_APPROVAL="$(norm_ts "2026-08-01T10:00:16Z")"
GATE_PUSH="$(norm_ts "2026-08-01T10:00:16.900000Z")"
SUB_APPROVAL="$(canon_substance "2026-08-01T10:00:16Z")"
SUB_PUSH="$(canon_substance "2026-08-01T10:00:16.900000Z")"
if [[ "$GATE_APPROVAL" < "$GATE_PUSH" ]]; then
  ok "gate rule orders this approval BEFORE the push (stale)"
else
  bad "gate rule no longer orders …16Z before …16.900000Z — norm_ts has stopped keeping fractions"
fi
check_eq "substance rule sees the same pair as EQUAL (more permissive)" "$SUB_APPROVAL" "$SUB_PUSH"

# That extra permissiveness is safe ONLY because the two verdicts are ANDed with
# freshness on the OUTSIDE: merge-gate.sh computes <PREFIX>_APPROVAL_STALE with
# norm_ts and tests the substance verdict INSIDE that guard, so substance can
# only ever subtract coverage — never restore an approval norm_ts ruled stale.
#
# WHAT THIS HAS TO CATCH, and why presence-greps are not enough.
# Asserting only that both tokens appear near each other catches a DELETED
# staleness check, but not the refactor that actually breaks the invariant:
# folding the two into one DISJUNCTION —
#
#     if [[ "$CR_SUBSTANTIVE" == true || "$CR_APPROVAL_STALE" == true ]]; then
#
# still contains both strings, so two `grep -q`s pass while a substantive but
# norm_ts-stale approval now validates. So pin the STRUCTURE, not the tokens:
# the staleness test must sit on an EARLIER (outer) line than the substance
# test, and neither of those two lines may be a disjunction.
#
# Both reviewer paths are checked. The CR and CA blocks are structurally
# identical and carry the identical hazard, and CodeAnt hollow approvals are
# what motivated #875 — pinning only CR would leave the other half unguarded.
#
# The block is delimited by its closing `fi` rather than a fixed line count, so
# adding a comment inside it cannot push the substance test out of view and
# produce a spurious failure.
extract_guard_block() { # <prefix>
  awk -v pat="^[[:space:]]*$1_APPROVAL_VALID=false" '
    $0 ~ pat { inblock = 1 }
    inblock { print }
    inblock && /^    fi[[:space:]]*$/ { exit }
  ' "$MERGE_GATE"
}

check_guard_nesting() { # <prefix>
  local p="$1" block stale_needle sub_needle stale_no sub_no stale_line sub_line
  block="$(extract_guard_block "$p")"
  [[ -n "$block" ]] || die "could not locate the ${p}_APPROVAL_VALID block in merge-gate.sh — this safety guard cannot be checked"
  grep -q '^    fi[[:space:]]*$' <<<"$block" \
    || die "${p}_APPROVAL_VALID block in merge-gate.sh does not terminate in a matching 'fi' — extraction is unreliable and this guard cannot be trusted"

  # grep -F: these are literal shell fragments, not patterns.
  stale_needle="\"\$${p}_APPROVAL_STALE\" == false"
  sub_needle="\"\$${p}_SUBSTANTIVE\" == true"
  stale_no="$(grep -nF "$stale_needle" <<<"$block" | head -1 | cut -d: -f1)"
  sub_no="$(grep -nF "$sub_needle" <<<"$block" | head -1 | cut -d: -f1)"

  if [[ -n "$stale_no" ]]; then
    ok "merge-gate.sh gates ${p}_APPROVAL_VALID on the norm_ts staleness verdict"
  else
    bad "merge-gate.sh no longer requires ${p}_APPROVAL_STALE == false before validating a ${p} approval — a substance-fresh but gate-stale approval could now satisfy the gate"
    return
  fi
  if [[ -n "$sub_no" ]]; then
    ok "merge-gate.sh tests the ${p} substance verdict inside that block"
  else
    bad "the ${p} substance check has left the ${p}_APPROVAL_VALID block in merge-gate.sh — substance may now be able to override a stale approval"
    return
  fi

  # Ordering: the freshness test must be the OUTER one. Strictly earlier also
  # proves the two are not folded onto a single condition line.
  if [[ "$stale_no" -lt "$sub_no" ]]; then
    ok "${p} substance is tested INSIDE the freshness guard, so it can only subtract coverage"
  else
    bad "${p}_SUBSTANTIVE is no longer nested inside the ${p}_APPROVAL_STALE guard in merge-gate.sh (staleness on block line $stale_no, substance on $sub_no) — substance may now be able to restore a gate-stale approval"
  fi

  # Neither test may be an OR: a disjunction lets either side alone validate the
  # approval, which is exactly the "substance overrides staleness" break.
  stale_line="$(sed -n "${stale_no}p" <<<"$block")"
  sub_line="$(sed -n "${sub_no}p" <<<"$block")"
  if [[ "$stale_line" != *"||"* ]]; then
    ok "${p} freshness test is a conjunction, not a disjunction"
  else
    bad "the ${p}_APPROVAL_STALE test in merge-gate.sh is now part of a disjunction ('$stale_line') — staleness can be bypassed by the other operand"
  fi
  if [[ "$sub_line" != *"||"* ]]; then
    ok "${p} substance test is a conjunction, not a disjunction"
  else
    bad "the ${p}_SUBSTANTIVE test in merge-gate.sh is now part of a disjunction ('$sub_line') — a norm_ts-stale approval could validate on substance alone"
  fi
}

check_guard_nesting CR
check_guard_nesting CA

############################################################################
echo "== structural guards: no re-inlined copy of the rule =="
############################################################################
# The whole point of #885 is that there is ONE bash definition and ONE jq mirror
# that a test can compare. Re-inlining a private copy into merge-gate.sh would
# put the drift back where no assertion can see it.
#
# These guards read EXECUTABLE lines only. A prose mention must never satisfy
# them: both files carry long comments that name `lib/ts-normalizer.sh`,
# `norm_ts` and `canon_ts`, so a plain `grep -q` over the whole file would still
# pass after someone deleted the actual `source` line or the last call site.
# `code_lines` strips comment-only lines — which covers jq comments too, since
# jq also uses `#`.
code_lines() { # <file>
  grep -v '^[[:space:]]*#' "$1"
}

# Without this, an unreadable merge-gate.sh makes code_lines emit nothing and
# every count below comes back 0 — which reads as "no local norm_ts, all good"
# on the one check whose passing value IS 0. Fail loudly instead.
[[ -r "$MERGE_GATE" ]] || die "merge-gate.sh not readable at $MERGE_GATE — the structural guards below would silently pass on an empty file"

# Matches `norm_ts() {`, `function norm_ts {`, and `function norm_ts() {` — all
# three are valid bash, and a re-inlined copy in any of them is the drift this
# guard exists to reject.
MG_LOCAL_DEFS="$(code_lines "$MERGE_GATE" | grep -cE '^[[:space:]]*(function[[:space:]]+)?norm_ts([[:space:]]*\(\))?[[:space:]]*\{')"
check_eq "merge-gate.sh defines no local norm_ts" "0" "$MG_LOCAL_DEFS"

# An executable `source`/`.` of the library, not a comment that mentions it.
# Two independent conditions on the same non-comment line — it must invoke
# `source` (or the `.` builtin) AND name the library, directly or via the
# variable holding its path. Deliberately not position-anchored: the real line is
# `if ! source "$TS_NORMALIZER_LIB"; then`, and a guard that only recognises one
# spelling of the wiring is a guard that breaks on a harmless refactor.
MG_SOURCE_STMTS="$(code_lines "$MERGE_GATE" \
  | grep -E '(^|[[:space:]])(source|\.)[[:space:]]' \
  | grep -cE 'TS_NORMALIZER_LIB|ts-normalizer\.sh')"
if [[ "$MG_SOURCE_STMTS" -ge 1 ]]; then
  ok "merge-gate.sh has an executable source of lib/ts-normalizer.sh"
else
  bad "merge-gate.sh has no executable 'source' of lib/ts-normalizer.sh — only prose. norm_ts has been re-inlined, renamed, or the wiring was deleted"
fi

# Sourcing it is pointless if nothing calls it: require real call sites.
MG_CALLS="$(code_lines "$MERGE_GATE" | grep -c 'norm_ts[[:space:]]*"')"
if [[ "$MG_CALLS" -ge 1 ]]; then
  ok "merge-gate.sh calls norm_ts in executable code ($MG_CALLS call sites)"
else
  bad "merge-gate.sh no longer calls norm_ts — the gate has stopped normalising and this suite guards nothing"
fi

# Guard the guard: if escalate-review.sh stops CALLING canon_ts, the def this
# suite extracts is dead code and parity would be asserted against something the
# gate path never runs. Count usages that are not the definition line itself.
ESC_CALLS="$(code_lines "$ESCALATE" | grep 'canon_ts' | grep -vc "$DEF_RE")"
if [[ "$ESC_CALLS" -ge 1 ]]; then
  ok "escalate-review.sh calls canon_ts in its jq program ($ESC_CALLS call sites)"
else
  bad "escalate-review.sh defines canon_ts but never calls it — this parity suite is testing dead code"
fi

# Same for review-substance.sh, whose divergence is pinned above.
SUB_CALLS="$(code_lines "$SUBSTANCE" | grep 'canon_ts' | grep -vc "$DEF_RE")"
if [[ "$SUB_CALLS" -ge 1 ]]; then
  ok "review-substance.sh calls canon_ts in its jq program ($SUB_CALLS call sites)"
else
  bad "review-substance.sh defines canon_ts but never calls it — the pinned divergence is meaningless"
fi

############################################################################
echo
echo "== summary == $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
