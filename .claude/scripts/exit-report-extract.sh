#!/usr/bin/env bash
# exit-report-extract.sh — Reduce a worker's final output to the few fields the completion protocols need (issue #2435).
# catalog: utilities — Extract the compact field set from the last EXIT_REPORT block in a worker's output; fails closed on a missing or malformed report
#
# The parent reads this one short result instead of the worker's transcript or
# full log. It decides nothing: classification of an absent report (crash vs
# usage-limit park) stays with phase-protocols.md §Limit-parked.
#
# USAGE: exit-report-extract.sh [--phase A|B|C|pm-worker|researcher] [FILE]
#   Reads FILE, or stdin when FILE is omitted or "-". Uses the LAST EXIT_REPORT
#   block, so a quoted example earlier in a long log cannot shadow the real one.
#   --phase NAME   Fail (exit 1) unless the report names this phase/agent.
#
# OUTPUT (exit 0): KEY=value lines — PHASE, PR, HEAD, REVIEWER, OUTCOME, NEXT,
#   HANDOFF, FILES_COUNT, FILES (cut to 300 chars), and VERDICTS /
#   FIXPR_WAIT_ITERATIONS / FIXPR_TOTAL_WAIT_SECS / FIXPR_WAIT_FINAL / RESULT (one-line task result, e.g. a pm-worker's
#   created issue number; required for pm-worker/completed) when present, then one
#   OWNER_ACTION=<reason>: <what> line per `OWNER_ACTION:` line in the prose above
#   the last EXIT_REPORT block (issue #2561).
#   Every value is cut to 300 chars, so output stays bounded for any input size.
#
# EXIT STATUS: 0 valid; 1 malformed (missing field, bad outcome for the phase,
#   phase mismatch) — prints `EXTRACT=malformed <reason>`; 2 usage error;
#   3 no EXIT_REPORT block at all — prints `EXTRACT=absent` (the caller then
#   classifies crash vs limit-park; this script never does).
# Compatible with macOS bash 3.2 (no mapfile, no associative arrays).
set -euo pipefail

want_phase=""
file="-"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) [[ $# -ge 2 ]] || { echo "exit-report-extract: --phase needs a value" >&2; exit 2; }
             want_phase="$2"; shift 2 ;;
    --help|-h) sed -n '2,26p' "$0"; exit 0 ;;
    -) file="-"; shift ;;
    -*) echo "exit-report-extract: unknown option $1" >&2; exit 2 ;;
    *) file="$1"; shift ;;
  esac
done
if [[ "$file" != "-" && ! -r "$file" ]]; then
  echo "exit-report-extract: cannot read $file" >&2
  exit 2
fi

if [[ "$file" == "-" ]]; then content=$(cat); else content=$(cat "$file"); fi
has_header=$(printf '%s\n' "$content" | awk '/^EXIT_REPORT[[:space:]]*$/ { f=1 } END { print f+0 }')
if [[ "$has_header" != "1" ]]; then
  echo "EXTRACT=absent"
  exit 3
fi
# Last EXIT_REPORT block: header line, then contiguous KEY: value lines.
# A multi-line NOTES field keeps the block open: its continuation lines are
# skipped, and any later KEY: line still counts.
block=$(printf '%s\n' "$content" | awk '
  /^EXIT_REPORT[[:space:]]*$/ { blk=""; inblk=1; last=""; next }
  inblk && /^[A-Z_]+:/ { split($0, kv, ":"); last=kv[1]; blk = blk $0 "\n"; next }
  inblk && last == "NOTES" { next }
  inblk { inblk=0 }
  END { printf "%s", blk }
')
if [[ -z "$block" ]]; then
  echo "EXTRACT=malformed header without fields"
  exit 1
fi

get() {
  local k=$1 line
  line=$(printf '%s' "$block" | grep -m1 "^$k:" || true)
  line=${line#"$k:"}
  line=${line# }
  printf '%s' "${line:0:300}"
}
has() { case $'\n'"$block" in *$'\n'"$1:"*) return 0 ;; *) return 1 ;; esac; }

bad() { echo "EXTRACT=malformed $1"; exit 1; }

agent=$(get AGENT)
phase=$(get PHASE_COMPLETE)
if [[ -z "$phase" && -n "$agent" ]]; then
  phase=$agent            # researcher uses the reduced schema
fi
[[ -n "$phase" ]] || bad "missing PHASE_COMPLETE"
if [[ -n "$want_phase" && "$phase" != "$want_phase" ]]; then
  bad "phase $phase does not match expected $want_phase"
fi

outcome=$(get OUTCOME)
[[ -n "$outcome" ]] || bad "missing OUTCOME"

case "$phase" in
  A) valid="pushed_fixes no_findings exhaustion blocked" ;;
  B) valid="clean fixes_pushed merge_ready exhaustion blocked blocked_self_review" ;;
  C) valid="merged blocked" ;;
  pm-worker) valid="completed blocked exhaustion" ;;
  researcher) valid="findings inconclusive blocked" ;;
  *) bad "unknown phase $phase" ;;
esac
outcome_ok=0
for v in $valid; do
  if [[ "$outcome" == "$v" ]]; then outcome_ok=1; fi
done
[[ "$outcome_ok" == 1 ]] || bad "outcome $outcome is not valid for $phase"

if [[ "$phase" == "researcher" ]]; then
  printf 'PHASE=%s\nOUTCOME=%s\n' "$phase" "$outcome"
  exit 0
fi

required="PR_NUMBER HEAD_SHA REVIEWER FILES_CHANGED NEXT_PHASE HANDOFF_FILE"
for k in $required; do
  has "$k" || bad "missing $k"
done
if [[ "$phase" == "A" || "$phase" == "B" ]]; then
  has VERDICTS_POSTED || bad "missing VERDICTS_POSTED"
fi

pr=$(get PR_NUMBER)
head_sha=$(get HEAD_SHA)
reviewer=$(get REVIEWER)
handoff=$(get HANDOFF_FILE)
# Outcomes that claim a PR exists need an integer PR and non-blank identity
# fields. A blocked or exhaustion report raised before any PR exists, and the
# non-phase agents, may carry `none`.
claims_pr=0
case "$phase:$outcome" in
  A:pushed_fixes|A:no_findings|B:fixes_pushed|B:clean|B:merge_ready|C:merged) claims_pr=1 ;;
esac
if [[ "$claims_pr" == 1 ]]; then
  [[ "$pr" =~ ^[0-9]+$ ]] || bad "PR_NUMBER must be an integer for $phase/$outcome"
  [[ -n "$head_sha" && "$head_sha" != none ]] || bad "HEAD_SHA is blank for $phase/$outcome"
  [[ -n "$reviewer" ]] || bad "REVIEWER is blank for $phase/$outcome"
  [[ -n "$handoff" ]] || bad "HANDOFF_FILE is blank for $phase/$outcome"
else
  [[ -n "$pr" ]] || bad "PR_NUMBER is blank"
  if [[ "$pr" != "none" && ! "$pr" =~ ^[0-9]+$ ]]; then
    bad "PR_NUMBER is neither an integer nor none"
  fi
  if [[ "$phase" == "B" && "$outcome" == "blocked_self_review" ]]; then
    [[ "$pr" =~ ^[0-9]+$ ]] || bad "PR_NUMBER must be an integer for B/blocked_self_review"
  fi
fi
# A pm-worker that completed a task states its result on one RESULT line (an
# issue number, a deferral target), so the parent never reads prose for it.
if [[ "$phase" == "pm-worker" && "$outcome" == "completed" ]]; then
  [[ -n "$(get RESULT)" ]] || bad "RESULT is required for pm-worker/completed"
fi
files=$(get FILES_CHANGED)
files_count=0
if [[ -n "$files" ]]; then
  files_count=$(printf '%s' "$(printf '%s' "$block" | grep -m1 '^FILES_CHANGED:' | cut -d: -f2-)" | awk -F, '{print NF}')
fi

printf 'PHASE=%s\nPR=%s\nHEAD=%s\nREVIEWER=%s\nOUTCOME=%s\nNEXT=%s\nHANDOFF=%s\n' \
  "$phase" "$pr" "$head_sha" "$reviewer" "$outcome" "$(get NEXT_PHASE)" "$handoff"
printf 'FILES_COUNT=%s\nFILES=%s\n' "$files_count" "$files"
for pair in VERDICTS_POSTED:VERDICTS FIXPR_WAIT_ITERATIONS:FIXPR_WAIT_ITERATIONS \
            FIXPR_TOTAL_WAIT_SECS:FIXPR_TOTAL_WAIT_SECS FIXPR_WAIT_FINAL:FIXPR_WAIT_FINAL RESULT:RESULT; do
  src=${pair%%:*}; dst=${pair##*:}
  if has "$src"; then printf '%s=%s\n' "$dst" "$(get "$src")"; fi
done
# OWNER_ACTION lines sit in the prose directly above the last EXIT_REPORT
# (issue #2561), so the parent, which reads only this output, still saves them.
# Only lines between the previous header (or the start) and the last one count.
printf '%s\n' "$content" | awk '
  /^EXIT_REPORT[[:space:]]*$/ { saved=cur; cur=""; next }
  /^OWNER_ACTION: *[^ ]/ { sub(/^OWNER_ACTION: */, ""); cur = cur "OWNER_ACTION=" substr($0, 1, 300) "\n" }
  END { printf "%s", saved }
'
exit 0
