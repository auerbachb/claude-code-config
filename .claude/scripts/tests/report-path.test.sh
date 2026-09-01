#!/usr/bin/env bash
# Tests for report-path.sh — the collision-free monthly report destination
# shared by /review-stack-audit and /harness-audit (issues #1345, #1519).
#
# THE BUG THIS PINS. Both skills used to derive their report path from the
# calendar month alone, so two audits in one month resolved to the SAME file and
# the second silently destroyed the first. It happened for real to
# /review-stack-audit in 2026-08 and PR #1338 had to rename its report by hand
# (#1345, fixed by PR #1511). /harness-audit carried the identical derivation
# until #1519, which is also what moved this engine out of one skill's directory
# into .claude/scripts/ — a helper with two consumers belongs in the shared home.
#
# Because the engine is shared, the core cases run over BOTH series: a fix that
# only held for the series it was written against would leave the other skill
# exactly where it started.
#
# A NEGATIVE CONTROL is included. These assertions would be worthless if they
# passed against the buggy derivation too, so the same acceptance criterion is
# run against a month-only stub and must FAIL there.
#
# Every case is OFFLINE and builds its own directory, so none can pass because of
# another's leftovers. HOME is sandboxed to a mktemp tree
# (script-usage-log-redirect.test.sh pattern) because the engine appends a
# telemetry line to $HOME/.claude/script-usage.log on every invocation.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPORT_PATH="$REPO_ROOT/.claude/scripts/report-path.sh"
RSA_SKILL_MD="$REPO_ROOT/.claude/skills/review-stack-audit/SKILL.md"
HA_SKILL_MD="$REPO_ROOT/.claude/skills/harness-audit/SKILL.md"

TMP_DIR="$(mktemp -d)"
# u+rwx, not u+w: the unreadable-directory case leaves a dir at mode 000, and
# without READ and SEARCH restored neither chmod -R nor rm -rf can descend into
# it — the tree then survives the trap and leaks a temp dir on every run.
cleanup() { chmod -R u+rwx "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Sandbox HOME before any engine runs. `.claude/` is created so the telemetry
# append still succeeds — the goal is to redirect that write, not to silently
# exercise a different (log-disabled) path than production takes. Set after the
# REPO_ROOT lookup above, which is the suite's only HOME-sensitive command.
export HOME="$TMP_DIR/home"
mkdir -p "$HOME/.claude"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
ok() { echo "ok   — $*"; }

[[ -x "$REPORT_PATH" ]] || { echo "FAIL: report-path.sh missing or not executable at $REPORT_PATH" >&2; exit 1; }

RP_DIR="$TMP_DIR/report-path"
mkdir -p "$RP_DIR"

# rp <dir> <month> <series> [extra args...] — echoes the path, returns the exit code.
rp() { "$REPORT_PATH" --dir "$1" --month "$2" --series "$3" "${@:4}"; }

# ---------------------------------------------------------------------------
# Both consumers: a second audit in one month must never overwrite the first
#
# Run identically for each series. The engine is shared, so the guarantee has to
# be a property of the engine, not of whichever skill it was written for first.
# ---------------------------------------------------------------------------

for SERIES in review-stack-audit harness-audit; do
  SDIR="$RP_DIR/$SERIES"
  mkdir -p "$SDIR"

  # Case 1 — an empty directory yields the unsuffixed canonical name. The first
  # report of a month must read exactly as it always has; a fix that renamed every
  # report would be a different (and worse) change.
  D="$SDIR/empty"; mkdir -p "$D"
  got="$(rp "$D" 2026-08 "$SERIES")" \
    && [[ "$got" == "$D/$SERIES-2026-08.md" ]] \
    && ok "[$SERIES] a free month returns the canonical unsuffixed name — the common case is unchanged" \
    || fail "[$SERIES] empty dir should return $D/$SERIES-2026-08.md, got '$got'"

  # Case 2 — the base name taken yields a DISTINCT path. This is the collision the
  # issues report; before the fix both runs returned the same string.
  D="$SDIR/collide"; mkdir -p "$D"
  base="$D/$SERIES-2026-08.md"
  printf 'first audit\n' > "$base"
  second="$(rp "$D" 2026-08 "$SERIES")"
  [[ -n "$second" && "$second" != "$base" ]] \
    && ok "[$SERIES] a second same-month audit gets a distinct path — the month-mate is not overwritten" \
    || fail "[$SERIES] second run returned '$second', which must differ from '$base'"
  [[ "$second" == "$D/$SERIES-2026-08-2.md" ]] \
    && ok "[$SERIES] the first collision suffix is -2 — a stable, predictable series" \
    || fail "[$SERIES] expected the -2 suffix, got '$second'"

  # Case 3 — base AND -2 taken yields a third distinct path, so the counter walks
  # rather than parking on the first suffix (which would collide from run three on).
  printf 'second audit\n' > "$second"
  third="$(rp "$D" 2026-08 "$SERIES")"
  [[ "$third" == "$D/$SERIES-2026-08-3.md" ]] \
    && ok "[$SERIES] the counter advances past every taken name — run three lands on -3" \
    || fail "[$SERIES] expected the -3 suffix, got '$third'"

  # The acceptance criterion in one assertion: over a run of audits, EVERY path
  # handed back is free at the moment it is handed back, and every report survives.
  D="$SDIR/sequence"; mkdir -p "$D"
  collided=""
  for i in 1 2 3 4 5; do
    p="$(rp "$D" 2026-08 "$SERIES")" || { fail "[$SERIES] run $i exited non-zero"; break; }
    if [[ -e "$p" || -L "$p" ]]; then collided="$p"; fi
    printf 'audit %s\n' "$i" > "$p"
  done
  [[ -z "$collided" ]] \
    && ok "[$SERIES] five same-month audits never target an existing name — nothing is overwritten" \
    || fail "[$SERIES] returned an already-occupied path: $collided"
  n="$(ls -1 "$D" | wc -l | tr -d ' ')"
  [[ "$n" == "5" ]] \
    && ok "[$SERIES] all five same-month reports survive on disk (the #1345 / #1519 acceptance criterion)" \
    || fail "[$SERIES] expected 5 surviving reports, found $n"

  # The two series must not be able to land on each other's names — that is the
  # wrong-slot failure PR #1338 had to undo by hand, and the reason --series has
  # no default now that a second skill calls this engine.
  D="$SDIR/distinct"; mkdir -p "$D"
  mine="$(rp "$D" 2026-08 "$SERIES")"
  [[ "$(basename "$mine")" == "$SERIES-2026-08.md" ]] \
    && ok "[$SERIES] the returned name carries this skill's own series, never the sibling's" \
    || fail "[$SERIES] returned '$mine', which is not in the $SERIES series"
done

# Two audits of DIFFERENT skills in the same month and the same directory are not
# month-mates at all: each keeps its own unsuffixed canonical name.
D="$RP_DIR/shared-dir"; mkdir -p "$D"
a="$(rp "$D" 2026-08 review-stack-audit)"; printf 'a\n' > "$a"
b="$(rp "$D" 2026-08 harness-audit)"; printf 'b\n' > "$b"
[[ "$a" == "$D/review-stack-audit-2026-08.md" && "$b" == "$D/harness-audit-2026-08.md" ]] \
  && ok "series: two skills sharing a directory each keep their own canonical name — neither is pushed onto a suffix by the other" \
  || fail "series: expected distinct canonical names, got a='$a' b='$b'"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL — the same acceptance criterion, run against the bug
#
# Everything above would be worthless if it also passed against the month-only
# derivation both skills used to carry. This stub IS that derivation. The five-run
# sequence must collide here and leave fewer than five reports; if it does not,
# the assertions above are not testing what they claim to test.
# ---------------------------------------------------------------------------

MONTH_ONLY="$TMP_DIR/month-only-report-path.sh"
cat > "$MONTH_ONLY" <<'EOF'
#!/usr/bin/env bash
# The pre-#1519 derivation: the month and the series, and nothing about what is
# already on disk. Same CLI as the real engine so it is a drop-in stand-in.
set -euo pipefail
DIR=""; MONTH=""; SERIES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --month) MONTH="$2"; shift 2 ;;
    --series) SERIES="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s/%s-%s.md\n' "$DIR" "$SERIES" "$MONTH"
EOF
chmod +x "$MONTH_ONLY"

D="$RP_DIR/negative-control"; mkdir -p "$D"
nc_collided=""
for i in 1 2 3 4 5; do
  p="$("$MONTH_ONLY" --dir "$D" --month 2026-08 --series harness-audit)"
  if [[ -e "$p" || -L "$p" ]]; then nc_collided="$p"; fi
  printf 'audit %s\n' "$i" > "$p"
done
[[ -n "$nc_collided" ]] \
  && ok "negative control: the month-only derivation DOES hand back an occupied path — the collision assertions have teeth" \
  || fail "negative control: month-only derivation never collided, so the assertions above prove nothing"
nc_n="$(ls -1 "$D" | wc -l | tr -d ' ')"
[[ "$nc_n" == "1" ]] \
  && ok "negative control: five month-only audits leave ONE surviving report — four were silently destroyed, which is the bug" \
  || fail "negative control: expected 1 surviving report from the buggy derivation, found $nc_n"

# ---------------------------------------------------------------------------
# What counts as an occupied name, and what the engine refuses to guess
# ---------------------------------------------------------------------------

# A DIRECTORY or a DANGLING SYMLINK occupies the name just as a file does: `mv`
# onto either loses the report. A plain `-f` test would call both slots free.
D="$RP_DIR/nonfile"; mkdir -p "$D"
mkdir "$D/harness-audit-2026-09.md"
got="$(rp "$D" 2026-09 harness-audit)"
[[ "$got" != "$D/harness-audit-2026-09.md" ]] \
  && ok "occupancy: a directory occupying the name counts as taken — mv onto it would not produce a report" \
  || fail "occupancy: a directory at the base name was treated as free"
ln -s "$D/no-such-target" "$D/harness-audit-2026-10.md"
got="$(rp "$D" 2026-10 harness-audit)"
[[ "$got" != "$D/harness-audit-2026-10.md" ]] \
  && ok "occupancy: a dangling symlink counts as taken — -e alone reads it as absent" \
  || fail "occupancy: a dangling symlink at the base name was treated as free"

# It is a PURE function: the caller writes, never the script. A script that
# created its own placeholder would make both audits' advisory-only contract false.
D="$RP_DIR/pure"; mkdir -p "$D"
before="$(ls -A "$D" | sort)"
rp "$D" 2026-08 harness-audit >/dev/null
rp "$D" 2026-08 harness-audit >/dev/null
after="$(ls -A "$D" | sort)"
[[ "$before" == "$after" ]] \
  && ok "purity: resolving a path writes nothing — both skills stay advisory-only" \
  || fail "purity: the script mutated its target directory"

# --series keeps the manual ai-review-tool-audit-* series reachable without a
# second copy of the suffix logic living somewhere else.
D="$RP_DIR/series-extra"; mkdir -p "$D"
got="$(rp "$D" 2026-08 ai-review-tool-audit)"
[[ "$got" == "$D/ai-review-tool-audit-2026-08.md" ]] \
  && ok "usage: an arbitrary --series is honoured, so a further series needs no further implementation" \
  || fail "usage: --series override returned '$got'"

# Bad input is refused loudly. A malformed month would silently produce a name
# outside the series, so later runs would not recognise it as a month-mate — it
# would stop colliding by being unfindable rather than by being distinct.
months_ok=yes
for bad in 2026-13 2026-00 26-08 2026-8 "" ; do
  "$REPORT_PATH" --dir "$RP_DIR" --month "$bad" --series harness-audit >/dev/null 2>&1
  if [[ $? -ne 2 ]]; then
    fail "usage: month '$bad' must be a usage error (exit 2)"
    months_ok=no
  fi
done
[[ "$months_ok" == "yes" ]] \
  && ok "usage: malformed months are usage errors, never a silently off-series name" \
  || true

"$REPORT_PATH" --month 2026-08 --series harness-audit >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "usage: missing --dir is a usage error" \
  || fail "usage: missing --dir should exit 2"
"$REPORT_PATH" --dir "$RP_DIR" --series harness-audit >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "usage: missing --month is a usage error" \
  || fail "usage: missing --month should exit 2"

# --series is REQUIRED (#1519). A default would file one skill's report under the
# other skill's name whenever a caller forgot the flag — the wrong-slot failure
# #1345 already had to undo by hand. Refusing is the only safe answer, and the
# refusal must print NO path so a caller doing REPORT=$(...) gets an empty string.
out="$("$REPORT_PATH" --dir "$RP_DIR" --month 2026-08 2>/dev/null)"; rc=$?
[[ $rc -eq 2 && -z "$out" ]] \
  && ok "usage: a missing --series is a usage error with no path printed — a shared engine never guesses whose report this is" \
  || fail "usage: missing --series should exit 2 with empty stdout (rc=$rc, out='$out')"
"$REPORT_PATH" --dir "$RP_DIR" --month 2026-08 --series "" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "usage: an empty --series value is refused too, not treated as absent-and-defaulted" \
  || fail "usage: an empty --series should exit 2"

"$REPORT_PATH" --dir "$RP_DIR" --month 2026-08 --series ../escape >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "usage: a --series with path separators is refused — the report cannot land outside --dir" \
  || fail "usage: --series ../escape should exit 2"

# The failure this script exists to prevent, in its subtlest form: a directory it
# cannot read cannot prove a name is free. Returning the base name there would
# launder "I could not check" into "no collision" — the exact
# guards-that-pass-by-not-running shape. It must refuse, and print NO path, so a
# caller doing `REPORT=$(...)` gets an empty string rather than a live target.
"$REPORT_PATH" --dir "$RP_DIR/definitely-not-here" --month 2026-08 --series harness-audit >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "fail-closed: a missing target directory is refused, never assumed empty" \
  || fail "fail-closed: a missing --dir should exit 1"

D="$RP_DIR/locked"; mkdir -p "$D"
printf 'prior audit\n' > "$D/harness-audit-2026-08.md"
chmod 000 "$D"
out="$("$REPORT_PATH" --dir "$D" --month 2026-08 --series harness-audit 2>/dev/null)"; rc=$?
chmod 755 "$D"
if [[ $rc -eq 0 ]] && [[ "$(id -u)" == "0" ]]; then
  # root ignores the permission bits, so this case cannot be staged there.
  ok "fail-closed: unreadable-directory case skipped as root (chmod 000 is not enforced for uid 0)"
else
  [[ $rc -eq 1 && -z "$out" ]] \
    && ok "fail-closed: an unreadable directory refuses and prints no path — 'cannot check' never becomes 'no collision'" \
    || fail "fail-closed: unreadable dir should exit 1 with empty stdout (rc=$rc, out='$out')"
fi

# ---------------------------------------------------------------------------
# The caller's reservation — resolve, then CLAIM with O_EXCL
#
# report-path.sh creates nothing, so its answer is only true at the instant it
# is given (CodeAnt Critical + CodeRabbit major on PR #1511). Both skills close
# that window by reserving the returned path with `set -o noclobber`. These cases
# pin the contract that fix depends on: the reservation is atomic, and a reserved
# path is subsequently seen as taken by the resolver.
# ---------------------------------------------------------------------------

D="$RP_DIR/reserve"; mkdir -p "$D"

# Interleave two audits the way concurrency would: A resolves and reserves, then
# B resolves. B must be handed a different name — the reservation, not luck, is
# what makes A's path safe to write.
a_path="$(rp "$D" 2026-08 harness-audit)"
( set -o noclobber; : > "$a_path" ) 2>/dev/null \
  && ok "claim: a freshly resolved path can be reserved with O_EXCL — the claim succeeds on the happy path" \
  || fail "claim: could not reserve freshly resolved path $a_path"
b_path="$(rp "$D" 2026-08 harness-audit)"
[[ -n "$b_path" && "$b_path" != "$a_path" ]] \
  && ok "claim: a path reserved by O_EXCL is seen as taken by the next run — interleaved audits cannot share a name" \
  || fail "claim: second run returned the reserved path '$a_path' again"

# The reservation must REFUSE an occupied name rather than truncating it. If
# noclobber were inert here the claim would be the thing destroying the report.
printf 'prior report body\n' > "$D/harness-audit-2026-09.md"
( set -o noclobber; : > "$D/harness-audit-2026-09.md" ) 2>/dev/null \
  && fail "claim: O_EXCL reservation overwrote an existing report — the guard is inert" \
  || ok "claim: reserving an already-claimed path fails instead of truncating it"
[[ "$(cat "$D/harness-audit-2026-09.md")" == "prior report body" ]] \
  && ok "claim: the refused reservation left the prior report byte-for-byte intact" \
  || fail "claim: prior report was damaged by a refused reservation"

# noclobber must agree with the resolver about dangling symlinks, or a name the
# resolver skips would still be writable through — straight onto the link target.
ln -s "$D/nowhere" "$D/harness-audit-2026-11.md"
( set -o noclobber; : > "$D/harness-audit-2026-11.md" ) 2>/dev/null \
  && fail "claim: O_EXCL wrote through a dangling symlink the resolver treats as taken" \
  || ok "claim: O_EXCL and the resolver agree that a dangling symlink is an occupied name"

# ---------------------------------------------------------------------------
# The whole documented recipe — claim, retry, and clean up
#
# The claim introduced two failure modes of its own, both caught in review on
# PR #1511: a lost race must not discard the audit (CodeAnt Major), and a failed
# compose must not park an empty file on the canonical name (Bugbot Medium).
# claim_recipe mirrors the documented block exactly so those are pinned behaviour,
# not just prose. `mode=fail` aborts after claiming, standing in for a compose
# that dies before `mv`. Both skills ship this block, so the doc assertions at the
# end of this file check it in both SKILL.md files.
# ---------------------------------------------------------------------------

# claim_recipe <dir> <month> <series> <mode> [resolver]
claim_recipe() {
  bash -c '
    set -u
    REPORT_PATH="$1"; REPORT_DIR="$2"; MONTH="$3"; SERIES="$4"; MODE="$5"
    REPORT=""
    for _attempt in 1 2 3 4 5; do
      CANDIDATE="$("$REPORT_PATH" --dir "$REPORT_DIR" --month "$MONTH" --series "$SERIES")" || exit 1
      if ( set -o noclobber; : > "$CANDIDATE" ) 2>/dev/null; then REPORT="$CANDIDATE"; break; fi
    done
    [[ -n "$REPORT" ]] || exit 1
    TMP_REPORT="$REPORT_DIR/.$(basename "$REPORT").tmp"
    cleanup_report() { rm -f "$TMP_REPORT"; [[ -s "$REPORT" ]] || rm -f "$REPORT"; }
    trap cleanup_report EXIT
    printf "%s\n" "$REPORT"
    [[ "$MODE" == "fail" ]] && exit 9
    printf "report body\n" > "$TMP_REPORT"
    mv "$TMP_REPORT" "$REPORT"
  ' _ "${5:-$REPORT_PATH}" "$1" "$2" "$3" "$4"
}

# A resolver that loses the race exactly once: it creates the very path it
# returns, but only on its first call. That is the window between resolving and
# claiming — the only thing the retry loop exists for. A merely pre-existing file
# cannot exercise it, because report-path.sh would skip that name up front.
RACER="$TMP_DIR/racing-report-path.sh"
cat > "$RACER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
P="\$("$REPORT_PATH" "\$@")"
if [[ ! -e "$TMP_DIR/racer-fired" ]]; then
  : > "$TMP_DIR/racer-fired"
  : > "\$P"
fi
printf '%s\n' "\$P"
EOF
chmod +x "$RACER"

D="$RP_DIR/recipe"; mkdir -p "$D"

# Happy path: the claimed name is the canonical one and survives with content.
got="$(claim_recipe "$D" 2026-08 harness-audit ok)"
[[ "$got" == "$D/harness-audit-2026-08.md" && -s "$got" ]] \
  && ok "recipe: a successful run keeps its claimed report, non-empty, at the canonical name" \
  || fail "recipe: expected a non-empty canonical report, got '$got'"

# Lost race, injected in the real window: the first resolve is stolen out from
# under the claim. The run must retry onto the next suffix, NOT abort — aborting
# would throw away a completed audit over a moment's contention.
D2="$RP_DIR/recipe-race"; mkdir -p "$D2"
got="$(claim_recipe "$D2" 2026-08 harness-audit ok "$RACER")"; rc=$?
[[ $rc -eq 0 && "$got" == "$D2/harness-audit-2026-08-2.md" && -s "$got" ]] \
  && ok "recipe: a claim stolen mid-window is retried onto the next suffix, not discarded" \
  || fail "recipe: race path returned rc=$rc path='$got' (expected the -2 suffix, written)"
[[ -e "$D2/harness-audit-2026-08.md" ]] \
  && ok "recipe: the winner's claim is left untouched by the audit that lost the race" \
  || fail "recipe: the losing run removed the winner's claimed file"

# Failed compose: the claim is a zero-byte placeholder, so the trap must remove
# it. Otherwise the canonical name stays occupied by a blank file and every later
# audit that month is pushed onto a suffix — the confusion these issues are about.
D3="$RP_DIR/recipe-crash"; mkdir -p "$D3"
got="$(claim_recipe "$D3" 2026-08 harness-audit fail)"; rc=$?
[[ $rc -eq 9 ]] \
  && ok "recipe: a compose failure propagates its exit status" \
  || fail "recipe: expected rc=9 from the failing compose, got $rc"
[[ ! -e "$got" ]] \
  && ok "recipe: a failed run removes its empty claim — the canonical name is not left occupied by a blank file" \
  || fail "recipe: empty placeholder survived a failed run at $got"
[[ -z "$(ls -A "$D3")" ]] \
  && ok "recipe: a failed run leaves the directory exactly as it found it (temp file included)" \
  || fail "recipe: failed run left debris: $(ls -A "$D3")"

# ...and because the name was released, the next audit gets the canonical name
# back rather than being pushed onto -2 forever.
got="$(claim_recipe "$D3" 2026-08 harness-audit ok)"
[[ "$got" == "$D3/harness-audit-2026-08.md" && -s "$got" ]] \
  && ok "recipe: after a failed run the canonical name is reusable — no permanent suffix drift" \
  || fail "recipe: expected the canonical name to be free again, got '$got'"

# ---------------------------------------------------------------------------
# Both SKILL.md files must still ship the recipe this suite certifies
#
# claim_recipe above is a REPLICA of the documented block. On its own it would
# keep passing while either SKILL.md quietly lost the retry or the trap, so the
# tests would certify a recipe nobody ships. #1519 is exactly that shape — the
# engine existed and one of its two callers still derived the path by hand — so
# both callers are asserted here, not just the one this suite was written for.
# ---------------------------------------------------------------------------

# The resolver-call pattern, defined ONCE. The controls below prove the
# behaviour of this exact string, so there is no second copy to drift out of
# agreement with the assertion that actually runs. `printf '%s'` passes the
# pattern through with no escape interpretation — the `\$` and `\(` reach grep
# as written.
call_pattern() { printf '%s' '^[[:space:]]*CANDIDATE="\$\(.*--series '"$1"; }

assert_caller() {
  local label="$1" md="$2" series="$3"
  if [[ ! -r "$md" ]]; then
    fail "$label: SKILL.md not readable at $md"
    return
  fi

  # Match the resolver CALL as a CALL. A flag fragment on its own is satisfied by
  # any line that merely mentions the flag — a comment, or prose naming it — so
  # deleting the real invocation and leaving a `#` line behind would keep this
  # assertion green (CodeAnt Major, PR #1523). Requiring the assignment-from-
  # command-substitution shape at the START of a line rejects both: a comment
  # opens with `#`, and prose does not open a line with `CANDIDATE="$(`.
  #
  # It anchors on the OPENING of the substitution, never the closing `)` —
  # anchoring on the close is what failed a correct-but-rewrapped caller before.
  # Everything between the open and `--series` is unconstrained, so a caller may
  # still reorder or rewrap its flags. Pinning the name `CANDIDATE` adds no new
  # coupling: the O_EXCL assertion below already requires that exact name.
  #
  # The `-e` guard is gone with the leading `--`: this pattern starts with `^`,
  # so grep cannot mistake it for one of its own options. Restore `-e` for any
  # future pattern that does start with a dash — that bug cost a whole assertion.
  grep -qE "$(call_pattern "$series")" "$md" \
    && ok "$label: resolves its report path through report-path.sh with its own --series" \
    || fail "$label: no report-path.sh call passing --series $series — the report could land in the sibling's series"

  grep -qF 'if ( set -o noclobber; : > "$CANDIDATE" ) 2>/dev/null; then REPORT="$CANDIDATE"; break; fi' "$md" \
    && ok "$label: still claims the resolved path with O_EXCL" \
    || fail "$label: lost its 'set -o noclobber' claim — the resolve/write race is reopened"
  grep -qF 'for _attempt in 1 2 3 4 5; do' "$md" \
    && ok "$label: still retries a lost claim instead of discarding the audit" \
    || fail "$label: lost its claim retry loop — a lost race would discard the audit"

  # A retry loop that runs out must ABORT. Without this guard the shipped block
  # would fall through with REPORT empty and compose onto "$REPORT_DIR/" — the
  # loop above would look intact while the failure it exists for went unhandled.
  grep -qF '[[ -n "$REPORT" ]]' "$md" \
    && ok "$label: still aborts when every claim attempt is lost, rather than writing to an empty path" \
    || fail "$label: lost its post-loop '[[ -n \"\$REPORT\" ]]' guard — an exhausted retry would compose onto an empty path"

  grep -qF 'trap cleanup_report EXIT' "$md" \
    && ok "$label: still clears its claim on failure" \
    || fail "$label: lost its EXIT trap — a failed compose would park an empty file on the canonical name"

  # The trap is only as good as the handler it installs. Asserting the `trap`
  # line alone leaves `cleanup_report` free to degrade to `rm -f "$TMP_REPORT"`,
  # which reintroduces the PR #1511 Bugbot Medium verbatim — the claim survives
  # as an empty file on the canonical name and every later audit that month is
  # pushed onto -2, -3, … The `-s` test is the whole fix, so pin the BODY too.
  # This is the concrete half of "a replica can drift from the shipped block"
  # (CodeAnt Major, PR #1523): claim_recipe cleans up correctly, and until now
  # nothing required the shipped handler to do the same.
  grep -qF '[[ -s "$REPORT" ]] || rm -f "$REPORT"' "$md" \
    && ok "$label: its cleanup still drops an unfilled claim, not just the temp file" \
    || fail "$label: cleanup_report no longer removes an empty claim — a failed compose parks a blank file on the canonical name"

  # The bug itself: a path built from the month alone, with nothing consulting
  # what is already on disk. Its return in either file is the regression.
  grep -qE '(REPORT|CANDIDATE)="\$(REPORT_DIR|\{REPORT_DIR\})/'"$series"'-\$(MONTH|\{MONTH\})' "$md" \
    && fail "$label: derives a report path from the month alone again — that is the #1519 / #1345 collision" \
    || ok "$label: no month-only report path derivation remains"
}

# POSITIVE CONTROL for the detector inside assert_caller. A "this bad pattern is
# absent" check is worthless until the pattern is shown to fire on the bad shape —
# otherwise it reports success by never matching anything (the
# guards-that-pass-by-not-running failure). Assert it fires here first, so the two
# clean verdicts below mean the files are clean rather than the regex being dead.
DETECTOR_FIXTURE="$TMP_DIR/regressed-skill.md"
printf 'REPORT="$REPORT_DIR/harness-audit-$MONTH.md"\n' > "$DETECTOR_FIXTURE"
grep -qE '(REPORT|CANDIDATE)="\$(REPORT_DIR|\{REPORT_DIR\})/harness-audit-\$(MONTH|\{MONTH\})' "$DETECTOR_FIXTURE" \
  && ok "detector: the month-only derivation pattern fires on a regressed file — the two absence checks below are live" \
  || fail "detector: the month-only pattern does not match the bug it describes, so its absence proves nothing"

# CONTROLS for the resolver-call pattern. The assertion it backs is a text match
# against Markdown — there is no binary to execute — so its worth rests entirely
# on matching a live invocation and nothing else. Both directions are checked:
# too loose and a deleted call still passes; too tight and a correct caller fails.
CALL_FIXTURE="$TMP_DIR/call-shape.md"

# POSITIVE: the shape both skills actually ship — indented, line-continued —
# must match, or the pattern is over-anchored and the verdicts below would be
# reporting on the pattern rather than on the callers. Anchoring on the closing
# `)` failed exactly this way before.
printf '%s\n' '  CANDIDATE="$("$REPORT_PATH" --dir "$REPORT_DIR" --month "$MONTH" --series harness-audit)" \' > "$CALL_FIXTURE"
grep -qE "$(call_pattern harness-audit)" "$CALL_FIXTURE" \
  && ok "call shape: the real indented, line-continued invocation matches — the pattern is not over-anchored" \
  || fail "call shape: the pattern rejects the invocation both skills ship — it is over-anchored"

# NEGATIVE: the false pass this pattern was tightened to close — the real call
# deleted, a commented-out copy left behind. A fragment match would call that a
# healthy caller.
printf '%s\n' '# CANDIDATE="$("$REPORT_PATH" --dir "$REPORT_DIR" --month "$MONTH" --series harness-audit)"' > "$CALL_FIXTURE"
grep -qE "$(call_pattern harness-audit)" "$CALL_FIXTURE" \
  && fail "call shape: a commented-out call satisfies the pattern — the assertion can pass with no live invocation" \
  || ok "call shape: a commented-out call does not satisfy the pattern"

# NEGATIVE: prose naming the flags is not an invocation either.
printf '%s\n' 'Run it with `--month "$MONTH" --series harness-audit` to select the series.' > "$CALL_FIXTURE"
grep -qE "$(call_pattern harness-audit)" "$CALL_FIXTURE" \
  && fail "call shape: prose naming the flags satisfies the pattern" \
  || ok "call shape: prose naming the flags does not satisfy the pattern"

# NEGATIVE: the series name is load-bearing, not decoration. A caller resolving
# with the SIBLING's series is the #1519 wrong-slot bug wearing a correct-looking
# call, so the pattern must discriminate on it.
printf '%s\n' '  CANDIDATE="$("$REPORT_PATH" --dir "$REPORT_DIR" --month "$MONTH" --series review-stack-audit)"' > "$CALL_FIXTURE"
grep -qE "$(call_pattern harness-audit)" "$CALL_FIXTURE" \
  && fail "call shape: a call passing the sibling's --series matches anyway — the series is not being checked" \
  || ok "call shape: a call passing the sibling's --series does not match — the series is discriminated"

assert_caller "review-stack-audit" "$RSA_SKILL_MD" review-stack-audit
assert_caller "harness-audit" "$HA_SKILL_MD" harness-audit

# The engine is shared, so neither skill may keep a private copy: a second
# implementation is what would drift, and only one of them would get fixed.
strays="$(find "$REPO_ROOT/.claude/skills" -name 'report-path.sh' 2>/dev/null)"
[[ -z "$strays" ]] \
  && ok "shared: no skill keeps a private copy of report-path.sh — one engine, two callers" \
  || fail "shared: a skill-local report-path.sh still exists and will drift: $strays"

[[ $FAILED -eq 0 ]] && echo "All report-path tests passed."
exit $FAILED
