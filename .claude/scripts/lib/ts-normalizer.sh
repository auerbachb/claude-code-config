#!/usr/bin/env bash
# lib/ts-normalizer.sh — Shared ISO-8601 normaliser for merge-gate timestamp
# ordering (issue #885).
#
# Source this file (do NOT execute it directly) from merge-gate.sh — and from
# any future bash caller that orders GitHub review/commit timestamps against the
# gate's rule — so there is exactly one bash definition of that rule.
#
# PROBLEM SOLVED
#   GitHub returns mixed ISO-8601 UTC spellings for the same instant: "…Z",
#   "…+00:00", and the compact "…+0000". Bash [[ < ]] and jq's string compare are
#   both purely lexicographic, so the FIRST differing character decides — and
#   when two timestamps share a whole-second prefix, that character is the zone
#   suffix. Z (0x5A) > + (0x2B), so:
#
#       "2026-08-01T10:00:16+00:00"  <  "2026-08-01T10:00:16Z"
#
#   These are the SAME instant, but they do not compare equal. The #836 rule
#   asks whether an approval is at or after the HEAD commit, so a push stamped
#   "…16Z" against an approval stamped "…16+00:00" reads as approval-before-push
#   and a perfectly fresh approval is ruled stale. Nothing errors; the gate just
#   returns the wrong merge-readiness verdict.
#
#   Two of the three review rounds on PR #883 were this bug:
#     1. escalate-review.sh dropped fractional seconds while merge-gate.sh kept
#        them, so the two ordered the same pair differently and escalation could
#        report gate_met on an approval the gate rules stale.
#     2. The repair then normalised "+0000" on one side only — the same
#        divergence in a new spelling, introduced by the fix for the first.
#   When two implementations must agree, a superset on one side is divergence,
#   not a harmless extra.
#
# CONTRACT — the gate rule
#   Strip EXACTLY ONE trailing UTC zone suffix ("Z", "+00:00", or "+0000") and
#   change nothing else. In particular:
#     * KEEP fractional seconds. These are DIFFERENT instants, and dropping
#       ".900" collapses "…49.900Z" and "…49Z" to the same COMPARISON VALUE —
#       so a strictly-earlier approval compares equal to the push and an
#       approval the gate rules stale reads as fresh.
#     * Do NOT rewrite the suffix to "Z". A fraction retained under a trailing
#       "Z" sorts the WRONG WAY — "." (0x2E) is below "Z" (0x5A), so the LATER
#       instant "…49.900Z" compares below "…49Z". With the suffix gone, plain
#       lexicographic order is correct for whole and fractional seconds alike.
#     * A genuine non-UTC offset is left untouched rather than mangled into a
#       wrong instant.
#   Output is a bare "YYYY-MM-DDTHH:MM:SS[.fraction]" string. Empty input gives
#   empty output.
#
# CROSS-LANGUAGE MIRROR — escalate-review.sh
#   escalate-review.sh implements the same rule as a jq `def canon_ts:` inside a
#   single-quoted jq program. jq cannot source a bash function and this repo has
#   no jq-module convention, so that mirror stays inline by design. It is not
#   maintained by hand: `.claude/scripts/tests/ts-normalizer-parity.test.sh`
#   extracts the jq def from the shipped file and asserts it agrees with
#   norm_ts() byte for byte across the whole spelling matrix. Any edit that
#   diverges fails that test.
#
#   Escalation is a CALLER of the gate, so it must never be the more permissive
#   of the two — that asymmetry is why parity is enforced rather than trusted.
#
# OUT OF SCOPE — review-substance.sh
#   review-substance.sh has its own `canon_ts` that strips fractional seconds
#   AND folds the UTC spellings onto "Z". That is deliberately different, not
#   drift: every timestamp it compares passes through that one function, so it
#   is internally consistent and is never compared against a merge-gate value.
#   Do NOT "unify" it into this library. The parity test pins the divergence so
#   a future refactor that erases it fails loudly.
#
# USAGE
#   # In merge-gate.sh:
#   source "$SCRIPT_DIR/lib/ts-normalizer.sh"
#   if [[ "$(norm_ts "$approved_at")" < "$(norm_ts "$commit_ts")" ]]; then …
#
# norm_ts <iso8601-timestamp>
#   Prints the comparison-safe form. Idempotent — an already-stripped value is
#   unchanged.
#   Examples:
#     norm_ts "2026-08-01T10:00:16Z"          -> "2026-08-01T10:00:16"
#     norm_ts "2026-08-01T10:00:16+00:00"     -> "2026-08-01T10:00:16"
#     norm_ts "2026-08-01T10:00:16+0000"      -> "2026-08-01T10:00:16"
#     norm_ts "2026-08-01T10:00:16.900000Z"   -> "2026-08-01T10:00:16.900000"
#     norm_ts "2026-08-01T10:00:16-04:00"     -> "2026-08-01T10:00:16-04:00"
#     norm_ts ""                              -> ""

# Exactly one suffix is stripped per call, matching the jq alternation
# `sub("(Z|\\+00:00|\\+0000)$"; "")` in escalate-review.sh. The earlier
# merge-gate.sh form chained three `${t%…}` expansions, which would strip BOTH
# suffixes off a (never-observed) "…+00:00Z" while the jq mirror strips one —
# a latent parity gap. No real GitHub timestamp carries two suffixes, so this
# changes no live comparison.
norm_ts() {
  local t="${1-}"
  case "$t" in
    *Z)      printf '%s\n' "${t%Z}" ;;
    *+00:00) printf '%s\n' "${t%+00:00}" ;;
    *+0000)  printf '%s\n' "${t%+0000}" ;;
    *)       printf '%s\n' "$t" ;;
  esac
}
