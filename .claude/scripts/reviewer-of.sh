#!/usr/bin/env bash
# reviewer-of.sh — Determine which reviewer (cr/bugbot/greptile) owns a PR.
# catalog: pr-state-polling — Determine which reviewer (cr/bugbot/greptile) owns a PR; reads session-state then GitHub history
#
# PURPOSE
#   Centralizes the reviewer-ownership resolution contract defined in
#   .claude/rules/cr-merge-gate.md (Step 1 — CR/BugBot/Greptile paths). Reads
#   .prs["<N>"].reviewer from ~/.claude/session-state.json first, falls back
#   to a live GitHub-history scan when the state file has no entry, and
#   optionally persists an explicit sticky assignment back to session-state.
#
#   Normalizes the legacy short form "g" (written by pre-C-14 skills) to
#   "greptile". Output is always one of: cr / bugbot / greptile / unknown.
#
# USAGE
#   reviewer-of.sh <pr_number>
#   reviewer-of.sh <pr_number> --sticky <cr|bugbot|greptile>
#   reviewer-of.sh --help | -h
#
# MODES
#   Default  — Session-state lookup → live-history fallback. Prints the
#              resolved reviewer on stdout. Does NOT mutate state.
#   --sticky <value>
#            — Skip detection; write <value> atomically to
#              .prs["<pr_number>"].reviewer in ~/.claude/session-state.json
#              (preserving all sibling keys) and print <value> on stdout.
#              Callers are responsible for choosing a chain-consistent value
#              (cr → bugbot → greptile is one-way down per bugbot.md /
#              greptile.md sticky-assignment rules).
#
# RESOLUTION ORDER (default mode)
#   1. ~/.claude/session-state.json  .prs["<N>"].reviewer — if present and
#      one of cr / bugbot / greptile / g, return that (normalizing g →
#      greptile). Unknown or empty values fall through to step 2.
#   2. Live history — collect distinct `user.login` values across the three
#      endpoints (pulls/reviews, pulls/comments, issues/comments, paginated):
#        • greptile-apps[bot] present → greptile
#        • cursor[bot] present AND coderabbitai[bot] absent AND codeant-ai[bot] absent → bugbot
#        • coderabbitai[bot] or codeant-ai[bot] present → cr
#        • else → unknown (exit 1)
#      Matches the resolve_reviewer() logic in merge-gate.sh.
#
# OUTPUT
#   stdout: single word — one of cr / bugbot / greptile / unknown (no
#           trailing whitespace beyond the newline).
#   stderr: one-line error messages on failure.
#
# EXIT STATUS
#   0  Reviewer determined (printed on stdout). Also the success path for
#      --sticky writes.
#   1  Cannot determine — "unknown" printed on stdout, no matching bot
#      author found in session-state or live history.
#   2  Usage error (missing/invalid PR number, unknown flag, invalid
#      --sticky value).
#   3  PR not found (live-history fallback only — gh pr view returned a
#      not-found error).
#   5  Write/runtime failure during --sticky persistence (mkdir, jq
#      transform, atomic mv, or corrupt state-file guard) OR malformed
#      existing session-state.json on read (file present but not a JSON
#      object). Matches the write-failure code used by greptile-budget.sh
#      so callers can tell "bad flag value" (2) from "disk/state
#      write/parse failed" (5). Read-path malformed-state is fatal (rather
#      than a silent fall-through to live-history) because sticky
#      BugBot/Greptile escalation decisions are intentionally stored in
#      session-state and are not always recoverable from live-history
#      co-presence; a corrupt state file must be repaired or removed.
#   8  HOME unset — ~/.claude/session-state.json cannot be resolved, so no
#      mode that touches the state file can run (issue #1434). 8 is the next
#      free number in the session-state family's shared vocabulary (2 usage,
#      3 missing state file, 4 parse/type, 5 write, 6 lock timeout, 7 CAS
#      loss), chosen the way state-lock.sh chose 6 — a fresh code rather than
#      an overload of an existing one. --help and usage errors answer BEFORE
#      this guard, so they never need HOME. There is deliberately no
#      ${HOME:-} fallback: defaulting to empty would fabricate a
#      root-anchored /.claude/session-state.json and strew state at the
#      filesystem root.
#
# ATOMICITY (--sticky)
#   Writes go through `jq … > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp"
#   "$STATE_FILE"`. `mv` within the same filesystem is atomic on POSIX.
#   Sibling top-level keys (prs for other PRs, greptile_daily, cr_quota,
#   active_agents, etc.) are preserved by merging via jq's `.prs[$pr].reviewer
#   = $v` assignment rather than rewriting the whole object.
#
# DEPENDENCIES
#   - jq
#   - gh (only for the live-history fallback and PR-existence check)
#
# EXAMPLES
#   # Default: detect without persisting.
#   reviewer-of.sh 287
#   # -> cr
#
#   # Persist a sticky greptile assignment after CR+BugBot both failed.
#   reviewer-of.sh 287 --sticky greptile
#   # -> greptile  (also writes .prs["287"].reviewer = "greptile" to session-state)
#
#   # Unknown PR (no bot activity yet).
#   reviewer-of.sh 9999
#   # -> unknown  (exit 1)

set -uo pipefail
# Best-effort usage telemetry — must never change this script's exit contract
# (issue #1430); stderr muted BEFORE the append per issue #1406's ordering.
if [[ -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

print_help() {
  # Print from PURPOSE through end of the header block (the first non-comment
  # line terminates). Extending the range to EOF would print the rest of the
  # script body too; terminating at the first line that doesn't start with "#"
  # keeps output scoped to the leading comment header while still including
  # the EXAMPLES section (previously cut off at the EXAMPLES heading).
  sed -n '/^# PURPOSE$/,/^[^#]/{/^[^#]/!p;}' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "reviewer-of.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# One named line + exit 8 instead of bash's `HOME: unbound variable` trace
# (issue #1434). Same shape as die_usage above; see the EXIT STATUS header for
# why 8 and why no ${HOME:-} fallback.
die_home_unset() {
  echo "reviewer-of.sh: HOME is unset; cannot resolve ~/.claude/session-state.json" >&2
  exit 8
}

# --- arg parsing ---
PR_NUMBER=""
STICKY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --sticky)
      if [[ $# -lt 2 || -z "${2-}" ]]; then
        die_usage "--sticky requires a value (cr|bugbot|greptile)"
      fi
      STICKY="$2"
      shift 2
      ;;
    --sticky=*)
      STICKY="${1#--sticky=}"
      if [[ -z "$STICKY" ]]; then
        die_usage "--sticky requires a value (cr|bugbot|greptile)"
      fi
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        die_usage "unexpected positional argument: $1"
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  die_usage "<pr_number> is required"
fi
if ! [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  die_usage "<pr_number> must be a positive integer, got: $PR_NUMBER"
fi

if [[ -n "$STICKY" ]]; then
  case "$STICKY" in
    cr|bugbot|greptile) ;;
    *) die_usage "--sticky must be one of: cr, bugbot, greptile (got: $STICKY)" ;;
  esac
fi

# --- dependency check ---
if ! command -v jq >/dev/null 2>&1; then
  echo "reviewer-of.sh: 'jq' not found on PATH" >&2
  exit 2
fi

# --- state-file path (requires HOME) ---
# Deliberately BELOW argument parsing (issue #1434). Both remaining modes —
# --sticky and the default lookup — read or write ~/.claude/session-state.json,
# so HOME is genuinely load-bearing from here on. Everything above (--help and
# every usage error) answers without it.
if [[ -z "${HOME:-}" ]]; then
  die_home_unset
fi
STATE_FILE="${HOME}/.claude/session-state.json"

# --- atomic write helper (--sticky path) ---
# Writes .prs["$PR_NUMBER"].reviewer = "$1", scoped to the active repo
# (issue #638): the value actually lands at
# .repos["<owner>/<name>"].prs["$PR_NUMBER"].reviewer, so a sticky escalation
# recorded for PR #84 here cannot overwrite PR #84's reviewer in a different
# repo. Delegated to session-state.sh, which owns the atomic replace, the
# sibling-preservation contract, the field-type guard, and the scoping rule —
# this used to be a hand-rolled duplicate of that same write, and keeping a
# second raw-jq writer would mean two places to teach about scoping.
SESSION_STATE="$(cd "$(dirname "$0")" && pwd)/session-state.sh"

write_sticky() {
  local value="$1"
  # session-state.sh exits 4 on a corrupt/multi-document state file and 5 on
  # a failed write — it refuses to overwrite rather than discarding unrelated
  # session data, which is the same contract this function had before. A
  # missing file is created from `{}` (exit 0), also as before.
  if ! "$SESSION_STATE" --set ".prs[\"$PR_NUMBER\"].reviewer=$value"; then
    echo "reviewer-of.sh: failed to persist sticky reviewer for PR #$PR_NUMBER" >&2
    exit 5
  fi
}

# --- --sticky short-circuit ---
# --sticky is authoritative: skip detection, persist, print.
if [[ -n "$STICKY" ]]; then
  write_sticky "$STICKY"
  printf '%s\n' "$STICKY"
  exit 0
fi

# --- session-state lookup (default mode, step 1) ---
# Distinguishes three cases:
#   (a) File missing                 → fall through to live-history scan.
#   (b) File present and is a valid  → use session state (the normal path).
#       JSON object
#   (c) File present but malformed   → fail fast with exit 5, matching the
#       (not an object, or not JSON)   write-failure code. The escalation
#                                      decision for sticky BugBot/Greptile
#                                      PRs is intentionally stored in
#                                      session-state and is NOT always
#                                      recoverable from live-history
#                                      co-presence. Silently degrading to
#                                      live-history on a corrupt state file
#                                      can mis-route sticky PRs back to CR
#                                      (or `unknown`), so the operator must
#                                      repair the file before resolution
#                                      proceeds.
# `jq -e 'type == "object"'` rather than `jq -e .` so valid-JSON non-objects
# (null, false, arrays, scalars) are treated as malformed instead of silently
# accepted — `jq -e .` treats `null`/`false` as falsy but also accepts
# arrays/scalars as truthy, neither of which matches the sibling-preservation
# contract.
if [[ -f "$STATE_FILE" ]]; then
  # Validate both the top-level shape AND the `.prs` subtree shape. A valid
  # top-level object with a malformed `.prs` (e.g. `{"prs":"oops"}` or
  # `{"prs":[]}`) would otherwise pass the top-level guard and then silently
  # fail the `.prs[$pr]` lookup below — masking the error and falling through
  # to live-history, defeating the fail-fast contract. Accept `.prs` missing
  # (null) because a fresh session-state legitimately has no PRs recorded yet.
  #
  # Both the guard and the read go through session-state.sh so they see the
  # repo-scoped view (issue #638) — including a legacy flat file, which the
  # helper migrates in memory on read. Asking for `.prs | type` rather than
  # `.prs` deliberately bypasses the helper's safe-default masking, so a
  # corrupt map still fails fast here instead of reading as an empty one.
  if ! STATE_PRS_TYPE="$("$SESSION_STATE" --get '.prs | type' 2>/dev/null)"; then
    echo "reviewer-of.sh: could not read .prs from $STATE_FILE; refusing to fall back to live-history (sticky escalation decisions are stored in session-state). Repair or remove the file to continue." >&2
    exit 5
  fi
  case "$STATE_PRS_TYPE" in
    object|null) ;;
    *)
      echo "reviewer-of.sh: $STATE_FILE is not a JSON object with an object-shaped .prs (found $STATE_PRS_TYPE); refusing to fall back to live-history (sticky escalation decisions are stored in session-state). Repair or remove the file to continue." >&2
      exit 5
      ;;
  esac
  # No `|| echo ""` mask: the guard above guarantees `.prs` is an object (or
  # null), so jq's `.prs[$pr].reviewer // ""` will always succeed. If jq does
  # fail here it means the state file raced underneath us (truncated, removed,
  # or clobbered between the validation guard above and this read) — surface
  # that as a non-zero exit rather than a silent empty string. The script
  # runs with `set -uo pipefail` (no `-e`), so a failed command substitution
  # in an assignment does NOT halt execution on its own — we MUST wrap the
  # assignment in an explicit `if !` check to enforce the fail-fast contract.
  if ! FROM_STATE="$("$SESSION_STATE" --get ".prs[\"$PR_NUMBER\"].reviewer // \"\"")"; then
    echo "reviewer-of.sh: jq read of $STATE_FILE failed after validation (file may have been modified or removed mid-read); refusing to fall back to live-history. Repair or remove the file to continue." >&2
    exit 5
  fi
  case "$FROM_STATE" in
    cr|bugbot|greptile)
      printf '%s\n' "$FROM_STATE"
      exit 0
      ;;
    g)
      # Legacy short form — normalize to full word.
      printf '%s\n' "greptile"
      exit 0
      ;;
    "" | *)
      # Empty or unrecognized — fall through to live scan.
      :
      ;;
  esac
fi

# --- live-history fallback (default mode, step 2) ---
if ! command -v gh >/dev/null 2>&1; then
  echo "reviewer-of.sh: 'gh' not found on PATH — cannot fall back to live history" >&2
  exit 2
fi

# Verify the PR exists. Distinguishes "not found" (exit 3) from generic gh
# errors. We use `gh api repos/{owner}/{repo}/pulls/$N` rather than
# `gh pr view --json number` because the latter has a quirk where it exits
# 0 and echoes `{"number":N}` even for PR numbers that don't exist.
PR_CHECK_ERR="$(mktemp)"
trap "rm -f '$PR_CHECK_ERR' 2>/dev/null" EXIT
if ! gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER" >/dev/null 2>"$PR_CHECK_ERR"; then
  # Use ERE (-E) for portability: BSD grep on macOS treats basic-regex `\|`
  # as a literal pipe, so the original `\|` alternation silently failed to
  # match 404 error bodies and downgraded them to exit 2.
  if grep -qiE "http 404|not found|could not resolve|no pull request|no such" "$PR_CHECK_ERR"; then
    echo "reviewer-of.sh: PR #$PR_NUMBER not found" >&2
    exit 3
  fi
  echo "reviewer-of.sh: gh api failed: $(cat "$PR_CHECK_ERR")" >&2
  exit 2
fi

# Collect distinct bot authors across all three endpoints (paginated).
# Each endpoint is queried separately so a transient failure aborts with a
# clear error rather than silently returning a wrong reviewer from a partial
# author set. stderr is captured for diagnostics.
AUTHORS_TMP="$(mktemp)"
GH_ERR="$(mktemp)"
trap "rm -f '$PR_CHECK_ERR' '$AUTHORS_TMP' '$GH_ERR' 2>/dev/null" EXIT

for endpoint in \
  "repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews" \
  "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments" \
  "repos/{owner}/{repo}/issues/$PR_NUMBER/comments"; do
  if ! gh api --paginate "${endpoint}?per_page=100" \
       --jq '.[]?.user.login // empty' >>"$AUTHORS_TMP" 2>"$GH_ERR"; then
    echo "reviewer-of.sh: failed to scan $endpoint: $(cat "$GH_ERR")" >&2
    exit 2
  fi
done

AUTHORS="$(sort -u "$AUTHORS_TMP")"

# Detection priority matches merge-gate.sh resolve_reviewer(): greptile wins
# over anything else (sticky); bugbot only when cursor is the sole AI reviewer
# among CR-path bots (CodeAnt without CodeRabbit still uses the cr path — #408);
# otherwise cr if CodeRabbit or CodeAnt has activity.
if grep -q '^greptile-apps\[bot\]$' <<<"$AUTHORS"; then
  printf '%s\n' "greptile"
  exit 0
fi
if grep -q '^cursor\[bot\]$' <<<"$AUTHORS" \
   && ! grep -q '^coderabbitai\[bot\]$' <<<"$AUTHORS" \
   && ! grep -q '^codeant-ai\[bot\]$' <<<"$AUTHORS"; then
  printf '%s\n' "bugbot"
  exit 0
fi
if grep -q '^coderabbitai\[bot\]$' <<<"$AUTHORS" \
   || grep -q '^codeant-ai\[bot\]$' <<<"$AUTHORS"; then
  printf '%s\n' "cr"
  exit 0
fi

printf '%s\n' "unknown"
exit 1
