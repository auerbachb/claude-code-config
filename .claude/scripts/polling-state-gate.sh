#!/usr/bin/env bash
# polling-state-gate.sh — Procedural gate for CodeRabbit polling (issue #315).
#
# Enforces before and during polling:
#   1) A handoff file exists at the path handoff-state.sh resolves for this PR —
#      the scoped ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json layout,
#      with the legacy flat ~/.claude/handoffs/pr-{N}-handoff.json as a fallback
#      (parent agent owns creation/refresh for the polling loop; Phase A/B
#      subagents write the same file for phase handoffs — see handoff-files.md,
#      and "Handoff resolution" below).
#   2) PR is registered in ~/.claude/session-state.json and scoped to this repo via
#      per-PR owner_repo / root_repo (issue #647), read from this repo's own
#      scope in session-state (`.repos["<owner>/<name>"].prs["N"]`, issue #638).
#   3) Each poll cycle evaluates exit via .claude/scripts/merge-gate.sh (not inline
#      paraphrase of cr-merge-gate.md).
#
# Repo scoping (issues #647 + #638 + #854). Two mechanisms, deliberately kept —
# they answer different questions and neither subsumes the other (audited in #651):
#   #638 decides WHICH SCOPE to read: `.repos["<owner>/<name>"]`, so two repos at
#        the same PR number never share an entry.
#   #647 decides WHETHER THIS CHECKOUT MAY POLL that entry, by comparing per-PR
#        `owner_repo`/`root_repo` against the active checkout's identity.
# `.root_repo` is no longer a single global scalar: session-state.sh rewrites a
# leading `.root_repo` into the active repo's own scope, so what this script reads
# below is THIS repo's recorded checkout, not whichever session wrote last. It is
# still never a refusal signal — a stale path from a removed worktree carries no
# authority over the checkout the caller is actually standing in.
#
# PR numbers are PER-REPO, so collisions across scopes are normal, not suspicious
# (issue #854). The scope this script reads is therefore one of exactly three
# things — the active repo's own scope, the reserved "_unknown" scope, or nothing
# at all. It never falls through to some other named repo's entry just because the
# number matches: that fallback both produced false refusals (a fresh
# --ensure-session for OUR PR #137 was rejected because ANOTHER repo tracked a
# #137) and, when it did not refuse, read the other repo's owner_repo and resolved
# the other repo's handoff path. A PR absent from our scope is simply not
# registered here; --ensure-session is the remedy, and other repos' entries are
# named in that message as diagnostics only.
#
# An inherited $CLAUDE_SESSION_REPO is supply-only (issue #967). When --repo is
# absent, a self-identifying invoking checkout (from --root-repo or the live cwd)
# overrides that ambient value before any state helper runs. The inherited value
# is retained only when the checkout cannot identify itself, such as an
# origin-less checkout. An explicit --repo remains authoritative as a declaration
# and still refuses when it contradicts the checkout being operated on.
#
# Scoping is validated per PR, by repo *identity* (normalized `origin` remote,
# falling back to the shared git common dir so sibling worktrees of one repo
# agree) rather than by checkout path:
#   a) .prs["N"].owner_repo present -> must equal the active checkout's identity
#   b) else .prs["N"].root_repo present -> its identity must equal the active one
#   c) scoping recorded but not comparable (no `origin`, stale path) -> refuse
#   d) else (state from an older version) -> notice on stderr, then pass
# A genuine cross-repo mismatch — one recorded INSIDE our own scope — is still
# refused, naming the PR and both repos.
#
# Usage:
#   polling-state-gate.sh <pr_number> --ensure-session [--root-repo <path>] [--repo <owner>/<name>] [--allow-nonauthor]
#   polling-state-gate.sh <pr_number> [--root-repo <path>] [--repo <owner>/<name>] [--allow-nonauthor]
#   polling-state-gate.sh <pr_number> --verify-state [--root-repo <path>] [--repo <owner>/<name>]
#
# Modes:
#   --ensure-session  Run once before the first poll tick: write/update session-state,
#                      create handoff if missing, record per-PR repo scoping
#                      (owner_repo + root_repo). Exits 0 on success.
#                      Does not require the merge gate to be met.
#                      Registering a PR number another repo already tracks is
#                      normal and succeeds; the other repo's entry is untouched.
#                      Authorship guard (issue #733): refuses to enrol a PR the
#                      authenticated user did not author (delegated to
#                      pr-authorship.sh; fail-closed). Enrolling a PR in polling is
#                      a write. Bypass with --allow-nonauthor ONLY under an explicit
#                      per-PR user override.
#                      The override decision is PERSISTED per PR (issue #1266) as
#                      the boolean `.prs["N"].allow_nonauthor`, inside the same
#                      atomic state write as root_repo/head_sha/owner_repo. It is
#                      written on every enrolment — `true` with the flag, `false`
#                      without — so re-enrolling without the override clears a
#                      stale `true` rather than leaving it latched on.
#   --verify-state     Offline recovery check: confirm handoff + session-state and
#                      root_repo consistency (no gh, no merge-gate). Exit 0 if OK.
#   (default)         Validate handoff + session-state, cd to resolved root_repo, run
#                      merge-gate.sh. Exit 0 iff merge gate is met (same as merge-gate).
#                      --allow-nonauthor is forwarded to merge-gate.sh so a PR
#                      enrolled under the override isn't re-blocked by
#                      merge-gate.sh's own authorship check every tick (issue
#                      #1251). Two independent sources turn it on, either alone
#                      sufficient (issue #1266):
#                        - the persisted enrolment decision, read back from
#                          `.prs["N"].allow_nonauthor == true`. This is what makes
#                          the documented per-cycle contract work: the polling loop
#                          calls `polling-state-gate.sh <PR_NUMBER>` with no extra
#                          flags, so without read-back the override applied only to
#                          the one enrolment call and merge-gate.sh re-added the
#                          authorship blocker on every later tick.
#                        - the flag passed on THIS invocation, retained so an
#                          explicit per-cycle override still works with no persisted
#                          state (e.g. state written before #1266).
#
# Flags:
#   --root-repo <path>       Which CHECKOUT to operate in (where gh/merge-gate run).
#   --repo <owner>/<name>    Which REPO KEY scopes session-state reads and writes,
#                            and the identity the active checkout is compared
#                            against. Exported as $CLAUDE_SESSION_REPO so every
#                            child helper (session-state.sh, poll-watermarks.sh,
#                            …) agrees. Precedence, resolved by
#                            `session-state.sh --repo-key`:
#                              --repo -> $CLAUDE_SESSION_REPO -> cwd `origin`.
#                            For this gate, a self-identifying invoking checkout
#                            replaces an inherited environment value before that
#                            precedence is evaluated. The environment is only a
#                            supply fallback when the checkout has no `origin`.
#                            An explicit --repo may SUPPLY an identity the checkout
#                            lacks; it may never OVERRIDE one the checkout states.
#                            `--repo` and `--root-repo` answer different
#                            questions, so when both resolve to a real owner/repo
#                            and disagree the invocation is refused rather than
#                            validating against one repo while acting on another.
#                            Value must match session-state.sh's key charset
#                            ([A-Za-z0-9._/-]); anything else is a usage error,
#                            never a silent fall-through to "_unknown".
#   --allow-nonauthor        See --ensure-session above, which persists the
#                            decision per PR. Also forwarded to merge-gate.sh in
#                            default (poll-cycle) mode — from the persisted
#                            decision or from this invocation's own flag; see
#                            (default) above.
#
# Exit codes (default mode): same as merge-gate.sh (0 met, 1 not met, 2 usage, 3 PR, 4 error)
#                            plus 5 — missing or unreadable handoff (below).
# --ensure-session: 0 success, 2 usage, 4 state/gh failure
# --verify-state: 0 valid, 2 usage, 4 invalid/missing, 5 missing/unreadable handoff
# Every refusal exits non-zero; only a *notice* (case (d) below) prints and passes.
#
# Exit 5 — missing or unreadable handoff (issue #1559). Minted as a fresh number
# rather than folded into 4, and deliberately outside the 0-4 vocabulary this
# script forwards verbatim from merge-gate.sh in poll-cycle mode, so a caller can
# tell "the gate could not run — its input is gone" from "not met, keep polling"
# (1) and from every other error (4). Covers three shapes of the same failure:
# no handoff at any resolved path, a handoff that exists but is not readable, and
# one that is not valid JSON (which previously surfaced as jq's status — 2, this
# script's *usage* code — from under `set -e`). Exit 0 is reserved for a
# validated gate result and is never emitted when the handoff is absent.
#
# Handoff resolution (issues #1507 + #1559). The handoff is resolved through
# handoff-state.sh over the scope precedence handoff-files.md documents —
# per-PR `owner_repo` -> $CLAUDE_SESSION_REPO -> the resolved checkout's `origin`
# — with the legacy flat path as a fallback, never as a default. Deriving it from
# the per-PR `owner_repo` field ALONE made the scoped layout invisible whenever
# that one field was absent (state from a writer that does not record it, or
# predating #655), which produced both reported failures from one omission:
# #1507, exit 4 naming the flat path for a PR whose scoped handoff was sitting
# right there; and #1559, a stale flat file answering silently in its place — the
# migration notice being gated on the very field that was missing — so the gate
# exited 0 having validated a file that was not this PR's record.
#
set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Shared case-normalizer (issue #704).  Use the library when available so
# repo_identity() and session-state.sh's repo_key_from_remote_url() share one
# definition and can never diverge.  Fall back to an inline equivalent if the
# lib is somehow absent so this script remains self-contained.
_NORMALIZER_LIB="${SCRIPT_DIR}/lib/repo-normalizer.sh"
if [[ -f "$_NORMALIZER_LIB" ]]; then
  # shellcheck source=./lib/repo-normalizer.sh
  source "$_NORMALIZER_LIB"
else
  normalize_repo_key() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
fi
unset _NORMALIZER_LIB

STATE_HELPER="${SCRIPT_DIR}/session-state.sh"
HANDOFF_HELPER="${SCRIPT_DIR}/handoff-state.sh"
MERGE_GATE="${SCRIPT_DIR}/merge-gate.sh"
POLL_WATERMARKS="${SCRIPT_DIR}/poll-watermarks.sh"
PR_AUTHORSHIP="${SCRIPT_DIR}/pr-authorship.sh"
STATE_FILE="${HOME}/.claude/session-state.json"
# There is deliberately no HANDOFF_DIR here (issue #1559). Every handoff path —
# scoped AND legacy flat — is computed by handoff-state.sh, which owns the
# layout; a second copy of `${HOME}/.claude/handoffs/pr-N-handoff.json` in this
# file is exactly how the flat path kept answering for scoped handoffs.

# Exit status for "the handoff this gate validates could not be read" — see the
# header. Named rather than inlined so the three sites that raise it (missing,
# unreadable, unparseable) can never drift apart.
HANDOFF_UNREADABLE_EXIT=5

PR_NUMBER=""
MODE="cycle"
ROOT_REPO_ARG=""
REPO_ARG=""
REPO_ARG_PASSED=0
# Authorship guard (issue #733): enrolling a PR in polling is a "touch", so
# --ensure-session refuses PRs the authenticated user did not author. A skill
# passes --allow-nonauthor only under an explicit per-PR user override.
ALLOW_NONAUTHOR=0

# Print the whole header comment block rather than a hard-coded line range: the
# old `sed -n '2,40p'` truncated mid-Modes the moment the header grew, so a newly
# documented flag could be invisible to --help (issue #854).
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --ensure-session)
      MODE="ensure"
      shift
      ;;
    --verify-state)
      MODE="verify"
      shift
      ;;
    --allow-nonauthor)
      ALLOW_NONAUTHOR=1
      shift
      ;;
    --root-repo)
      ROOT_REPO_ARG="${2:-}"
      if [[ -z "$ROOT_REPO_ARG" ]]; then
        echo "polling-state-gate.sh: --root-repo requires a path" >&2
        exit 2
      fi
      # An explicit repo also decides which repo's scope we read (issue #638).
      [[ -d "$ROOT_REPO_ARG" ]] && STATE_READ_DIR="$ROOT_REPO_ARG"
      shift 2
      ;;
    --repo)
      REPO_ARG_PASSED=1
      REPO_ARG="${2:-}"
      if [[ -z "$REPO_ARG" ]]; then
        echo "polling-state-gate.sh: --repo requires an <owner>/<name> value" >&2
        exit 2
      fi
      # Same shape check session-state.sh applies, made here so a typo is a usage
      # error rather than a silent fall-through to the "_unknown" bucket.
      # The character class must match session-state.sh's is_valid_repo_key()
      # exactly ([A-Za-z0-9._/-]): checking slash placement alone let values like
      # "org/repo name" through, which then got exported and silently rewritten
      # to "_unknown" by the helper — the exact silent-wrong-scope outcome this
      # validation exists to prevent (CodeAnt, PR #856).
      if [[ ! "$REPO_ARG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        echo "polling-state-gate.sh: --repo value is not a plausible repo key: $REPO_ARG" >&2
        exit 2
      fi
      shift 2
      ;;
    -*)
      echo "polling-state-gate.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        echo "polling-state-gate.sh: unexpected argument: $1" >&2
        exit 2
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]] || ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "polling-state-gate.sh: positive integer <pr_number> is required" >&2
  exit 2
fi

# Directory whose repo identity scopes every session-state read below (issue
# #638). Defaults to the active checkout; --root-repo overrides it.
STATE_READ_DIR="${STATE_READ_DIR:-$PWD}"

# Which repo scope holds this PR (issue #638). Resolved once, then reused by
# state_pr_field() so every read below comes from one consistent entry.
#
# Preference order, and why (issue #854):
#   1. this repo's own scope — the normal case
#   2. the reserved "_unknown" scope — legacy state that predates scoping and
#      could not be attributed. Reading it here is what preserves #647's
#      "state from an older version -> notice, then pass" behavior: those
#      entries still reach validate_root_match() and are judged on their own
#      recorded owner_repo/root_repo exactly as before.
#   3. nothing. There is deliberately no third choice: another named repo's
#      scope is NEVER selected. PR numbers are per-repo, so another repo
#      holding a #84 says nothing about ours, and reading its entry was the
#      collision bug — it answered with the wrong owner_repo, resolved the
#      wrong handoff path, and made a fresh --ensure-session refuse outright.
# Empty output means the PR is registered nowhere *for this repo*, which
# --ensure-session exists to fix.
# Identity of the checkout the caller is ACTUALLY standing in, captured before
# resolve_root_repo() can redirect to a recorded path. Without this anchor the
# cross-repo check compares the redirected root against itself and always
# agrees — a poll from repo C for a PR scoped to repo A would silently operate
# on repo A's checkout instead of being refused.
ACTIVE_REPO_KEY=""
PR_SCOPE=""
PR_SCOPE_RESOLVED=0

# The repo-identity and per-PR scope-resolution seam is correctness-sensitive
# and has one implementation home (issue #971). Missing it must fail loudly;
# silently falling back to an inline copy would recreate the drift this boundary
# exists to prevent.
_SCOPE_RESOLVER_LIB="${SCRIPT_DIR}/lib/pr-scope-resolver.sh"
if [[ ! -r "$_SCOPE_RESOLVER_LIB" ]]; then
  echo "polling-state-gate.sh: required scope resolver not found: $_SCOPE_RESOLVER_LIB" >&2
  exit 4
fi
# shellcheck source=./lib/pr-scope-resolver.sh
if ! source "$_SCOPE_RESOLVER_LIB"; then
  echo "polling-state-gate.sh: failed to source required scope resolver: $_SCOPE_RESOLVER_LIB" >&2
  exit 4
fi
unset _SCOPE_RESOLVER_LIB

# --repo is implemented by exporting $CLAUDE_SESSION_REPO rather than by
# threading a flag through every helper invocation (issue #854). Resolve the
# invoking checkout first (issue #967), so a stale value inherited from a
# persistent parent shell cannot outrank a checkout that names itself.
#
# REPO_KEY_DECLARED retains the contradiction-guard meaning for an explicit
# --repo. An inherited value counts as declared only on the supply-only path,
# where the invoking checkout cannot provide an owner/repo identity itself.
REPO_KEY_DECLARED=0
INVOKING_CHECKOUT_PATH=""
INVOKING_CHECKOUT_ID=""
if [[ -n "$ROOT_REPO_ARG" ]]; then
  INVOKING_CHECKOUT_PATH="$ROOT_REPO_ARG"
else
  INVOKING_CHECKOUT_PATH="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [[ -n "$INVOKING_CHECKOUT_PATH" ]]; then
  INVOKING_CHECKOUT_ID="$(repo_identity "$INVOKING_CHECKOUT_PATH")"
fi

if [[ "$REPO_ARG_PASSED" -eq 1 ]]; then
  REPO_KEY_DECLARED=1
  export CLAUDE_SESSION_REPO="$REPO_ARG"

  # Preserve the explicit mismatch refusal even when no --root-repo was passed:
  # the live cwd is the invoking checkout and must not be silently redirected by
  # a stored root from the declared scope.
  if is_owner_repo_identity "$INVOKING_CHECKOUT_ID"; then
    declared_arg="$(normalize_repo_key "$REPO_ARG")"
    if [[ "$declared_arg" != "$INVOKING_CHECKOUT_ID" ]]; then
      echo "polling-state-gate.sh: repo key '$declared_arg' (from --repo) contradicts the checkout being operated on, which is '$INVOKING_CHECKOUT_ID' ($INVOKING_CHECKOUT_PATH) — refuse to validate against one repo while acting on another. Drop the override, or point --root-repo at a '$declared_arg' checkout." >&2
      exit 4
    fi
    unset declared_arg
  fi
elif is_owner_repo_identity "$INVOKING_CHECKOUT_ID"; then
  export CLAUDE_SESSION_REPO="$INVOKING_CHECKOUT_ID"
elif [[ -n "${CLAUDE_SESSION_REPO:-}" ]]; then
  REPO_KEY_DECLARED=1
fi

ACTIVE_REPO_KEY="$(cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --repo-key 2>/dev/null || true)"

# flat_handoff_path — the legacy flat handoff path, from handoff-state.sh rather
# than rebuilt here (issue #1559). --legacy-flat is the explicit per-call opt-in
# the helper has required since issue #1366: omitting it makes the helper DERIVE
# a scope from this script's cwd and hand back a scoped path, which is not what
# any caller of this function is asking for.
#
# stdout only. handoff-state.sh writes *notes* to stderr on successful calls
# (the CLAUDE_HANDOFF_FLAT_OK one, for instance), and a `2>&1` capture here
# would splice one of those into the path this returns. The diagnostic is
# re-read from stderr alone on the failure path, where --path — a pure
# computation that reads and writes no handoff — is safe to re-invoke.
flat_handoff_path() {
  local p why
  if ! p="$("$HANDOFF_HELPER" --legacy-flat --path "$PR_NUMBER" 2>/dev/null)" || [[ -z "$p" ]]; then
    why="$("$HANDOFF_HELPER" --legacy-flat --path "$PR_NUMBER" 2>&1 >/dev/null || true)"
    echo "polling-state-gate.sh: handoff-state.sh --legacy-flat --path failed for PR #$PR_NUMBER: ${why:-no output}" >&2
    return 1
  fi
  printf '%s' "$p"
}

# unsearchable_ancestor <path>
#
# Echo the ancestor directory that makes <path>'s existence UNKNOWABLE, or
# return 1 when absence is a real answer.
#
# `[[ -f x ]]` is false for two different facts: "x is not there" and "the stat
# failed", and an unsearchable directory anywhere above x produces the second
# while looking exactly like the first. Collapsing them is how a present-but-
# unreachable scoped handoff gets reported as missing and quietly replaced by
# whatever the flat path holds — the same wrong-record substitution issue #1559
# fixed one layer up, arriving through a permission error instead of a scope
# miss. Never let "cannot determine" mean "absent" (memory:
# portable-stat-and-mkdir-lock-traps).
#
# Walks up to the deepest ancestor that can actually be stat'd: that is the
# first one whose own parent is searchable, so its verdict is trustworthy. If
# that ancestor is a directory we may not search, everything beneath it is
# indeterminate; if it is searchable, the child is genuinely absent.
unsearchable_ancestor() {
  local p="${1%/*}"
  while [[ -n "$p" && "$p" != "/" ]]; do
    if [[ -e "$p" ]]; then
      if [[ -d "$p" && ! -x "$p" ]]; then
        printf '%s' "$p"
        return 0
      fi
      return 1
    fi
    p="${p%/*}"
  done
  return 1
}

# handoff_scope_candidates <resolved_checkout> [recorded_owner_repo]
#
# The owner/repo scopes this PR's handoff may legitimately live under, most
# specific first, deduped, one per line. Composed inline from the primitives
# lib/pr-scope-resolver.sh already provides rather than added to that library:
# handoff-state.sh, session-state.sh --repo-key and this script each keep their
# own composition of the same precedence, and this ticket is not the place to
# rewire all three.
#
#   1. the per-PR `owner_repo` recorded in session-state — the scope THIS PR was
#      enrolled under, so it outranks anything about the ambient session.
#   2. $CLAUDE_SESSION_REPO — already resolved and exported above from
#      --repo -> invoking checkout -> inherited value (issue #967), so this one
#      entry covers the declared and the self-identifying-checkout cases both.
#   3. the resolved checkout's own identity. Taken from the RESOLVED path, not
#      the cwd, so a --root-repo override resolves that checkout's handoff.
#
# Every candidate is normalized and admitted only by is_strict_owner_repo():
# the loose is_owner_repo_identity() test accepts values that name no
# {owner}/{repo} directory pair (`org/repo name`, `org/a/b`, `org/`, `.`), and
# turning one of those into a path is how a handoff lands where no reader looks
# (PR #1423). A rejected candidate is skipped, never guessed at.
handoff_scope_candidates() {
  local resolved="$1"
  local recorded="${2:-}"
  local raw cand seen=""
  for raw in "$recorded" "${CLAUDE_SESSION_REPO:-}" "$(repo_identity "$resolved")"; do
    [[ -n "$raw" && "$raw" != "null" ]] || continue
    cand="$(normalize_repo_key "$raw")"
    is_strict_owner_repo "$cand" || continue
    # Substring dedupe over a delimited accumulator — bash 3.2 has no
    # associative arrays, and the delimiters keep `a/b` from matching `xa/by`.
    case "$seen" in
      *"|${cand}|"*) continue ;;
    esac
    seen="${seen}|${cand}|"
    printf '%s\n' "$cand"
  done
}

write_checkpoint_handoff() {
  local head_sha="$1"
  local reviewer="${2:-cr}"
  local owner_repo="${3:-}"
  # "init" (default) never touches an existing file; "replace" overwrites one.
  # Only the repair path below passes "replace", and only for a handoff that is
  # already unusable — see the call site for why that is not data loss.
  local write_mode="${4:-init}"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Build the JSON body first, then route through handoff-state.sh --create so the
  # write is protected by the shared state-lock.sh advisory lock (issue #682).
  # Include owner_repo in the JSON body so migrate and read-time assertions can use it.
  local json_body
  # Every "${arr[@]}" below is written as "${arr[@]+...}" (issue #854): macOS
  # system bash is 3.2, where an EMPTY array expanded under `set -u` aborts with
  # "unbound variable" rather than expanding to nothing. That is not theoretical
  # here — it crashed --ensure-session (exit 1, after the state write) on the
  # ordinary path where a repo has no resolvable owner_repo, or where an existing
  # flat handoff is refreshed and set_or_flag is deliberately left empty.
  local owner_repo_jq_arg=()
  local owner_repo_jq_field=""
  if [[ -n "$owner_repo" ]]; then
    owner_repo_jq_arg=(--arg "or_" "$owner_repo")
    owner_repo_jq_field=', owner_repo: $or_'
  fi
  if ! json_body="$(jq -n \
    --argjson pr "$PR_NUMBER" \
    --arg sha "$head_sha" \
    --arg rev "$reviewer" \
    --arg now "$now" \
    ${owner_repo_jq_arg[@]+"${owner_repo_jq_arg[@]}"} \
    "{
      schema_version: \"1.0\",
      pr_number: \$pr,
      head_sha: \$sha,
      reviewer: \$rev,
      phase_completed: \"B\",
      created_at: \$now,
      findings_fixed: [],
      findings_dismissed: [],
      threads_replied: [],
      threads_resolved: [],
      files_changed: [],
      push_timestamp: \$now,
      notes: \"Polling checkpoint — written by polling-state-gate.sh --ensure-session; Phase A/B handoffs supersede when present from subagents.\"${owner_repo_jq_field}
    }")"; then
    echo "polling-state-gate.sh: failed to build handoff JSON" >&2
    exit 4
  fi
  # Use --init (not --create) so the existence check and write are both inside
  # the advisory lock: if Phase A writes a richer handoff between our check and
  # this call, --init is a no-op that preserves Phase A's data (Greptile P1, #682).
  # Pass --owner-repo when available so the file lands in the scoped subdirectory
  # (issue #655: ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json).
  # Scope is always declared explicitly (issue #1366): handoff-state.sh no
  # longer falls back to the flat path on omission, and this script's cwd is not
  # necessarily $canon, so letting it derive could name a different repo than
  # the one this checkpoint belongs to. An empty owner_repo here means all three
  # sources failed — `gh repo view`, repo_identity(), and the session's declared
  # $CLAUDE_SESSION_REPO — i.e. genuinely repo-less, which is what the legacy
  # flat path is for.
  local or_flag=(--legacy-flat)
  [[ -n "$owner_repo" ]] && or_flag=(--owner-repo "$owner_repo")
  # "replace" routes to --repair, not --create. --create overwrites
  # unconditionally, so the caller's corruption verdict would be acted on after
  # it was formed: a Phase A writer that repairs the record between our read and
  # this call would have its valid, richer handoff destroyed by a bare polling
  # checkpoint. --repair re-tests readability inside the same lock that guards
  # the write and no-ops on a usable record (CodeAnt Major, PR #1598).
  local mode_flag="--init"
  [[ "$write_mode" == "replace" ]] && mode_flag="--repair"
  if ! "$HANDOFF_HELPER" ${or_flag[@]+"${or_flag[@]}"} "$mode_flag" "$PR_NUMBER" "$json_body"; then
    echo "polling-state-gate.sh: handoff-state.sh $mode_flag failed for PR #$PR_NUMBER" >&2
    exit 4
  fi
}

ensure_session() {
  local resolved=""
  # Prefer live checkout root unless --root-repo is explicit (avoids stale session-state roots).
  if [[ -n "$ROOT_REPO_ARG" ]]; then
    if ! resolved="$(resolve_root_repo "$ROOT_REPO_ARG")"; then
      exit 4
    fi
  else
    resolved="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      if ! resolved="$(resolve_root_repo "")"; then
        exit 4
      fi
    else
      resolved="$(cd "$resolved" && git rev-parse --show-toplevel)"
    fi
  fi
  if [[ -z "$resolved" || ! -d "$resolved" ]]; then
    echo "polling-state-gate.sh: could not resolve root for --ensure-session" >&2
    exit 4
  fi
  if ! validate_root_match "$resolved" quiet; then
    exit 4
  fi
  local canon
  canon="$(cd "$resolved" && git rev-parse --show-toplevel)"
  # Everything from here reads and writes THIS repo's scope.
  STATE_READ_DIR="$canon"
  local pr_json head_sha owner_repo
  if ! pr_json="$(cd "$canon" && gh pr view "$PR_NUMBER" --json headRefOid,state 2>/dev/null)"; then
    echo "polling-state-gate.sh: gh pr view failed for PR #$PR_NUMBER in $canon" >&2
    exit 4
  fi
  head_sha="$(echo "$pr_json" | jq -r '.headRefOid // empty')"
  local state
  state="$(echo "$pr_json" | jq -r '.state // ""')"
  if [[ "$state" != "OPEN" ]]; then
    echo "polling-state-gate.sh: PR #$PR_NUMBER is not OPEN" >&2
    exit 4
  fi
  if [[ -z "$head_sha" ]]; then
    echo "polling-state-gate.sh: could not read head SHA" >&2
    exit 4
  fi

  # Authorship guard (issue #733). Enrolling a PR in polling is a write; only the
  # authenticated user's own PRs may be enrolled. Delegated to pr-authorship.sh
  # (single source of truth) so this fail-safe agrees with the skill-layer gate.
  # Fail-closed: any non-zero (not_mine / unknown / not_found) refuses. Bypassed
  # only when the caller passed --allow-nonauthor under an explicit user override.
  if [[ "$ALLOW_NONAUTHOR" -eq 0 && -x "$PR_AUTHORSHIP" ]]; then
    local a_out a_rc=0
    a_out="$(cd "$canon" && "$PR_AUTHORSHIP" "$PR_NUMBER" 2>&1)" || a_rc=$?
    if [[ "$a_rc" -ne 0 ]]; then
      echo "polling-state-gate.sh: refusing to enroll PR #$PR_NUMBER in polling — authorship guard (.claude/rules/safety.md): ${a_out}. Pass --allow-nonauthor only under an explicit per-PR user override." >&2
      exit 4
    fi
  fi

  owner_repo="$(cd "$canon" && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  if [[ -z "$owner_repo" ]]; then
    # gh unavailable/unauthenticated: derive the same owner/repo identity from the
    # `origin` remote so later ticks still have per-PR scoping to validate against.
    local derived
    derived="$(repo_identity "$canon")"
    if [[ "$derived" == */* && "$derived" != gitdir:* && "$derived" != path:* ]]; then
      owner_repo="$derived"
    fi
  fi
  if [[ -z "$owner_repo" ]] && is_owner_repo_identity "${CLAUDE_SESSION_REPO:-}"; then
    # Last resort before the flat path: the session's own declared scope, set
    # from --repo or inherited supply-only (issue #967) and already exported
    # above. Reaching here means $canon names no owner/repo of its own — an
    # origin-less checkout, or one whose `origin` is a local filesystem path.
    #
    # Without this the checkpoint lands flat while session-state is written
    # under .repos["$CLAUDE_SESSION_REPO"] (session-state.sh derives its own key
    # from the same variable), so the two halves of one poll's state disagree
    # and no scoped reader ever finds the handoff. The flat file is also shared
    # by every repo, so falling back to it is strictly more collision-prone than
    # honouring a scope the session has already declared — the same precedence
    # handoff-state.sh itself applies (--owner-repo -> $CLAUDE_SESSION_REPO ->
    # cwd origin) when the flag is omitted (issue #1366).
    # is_owner_repo_identity() only rejects the empty/_unknown/gitdir:/path:
    # sentinels and then tests for a slash — too loose to turn into a path. It
    # admits `org/repo name` (session-state.sh keys on ^[A-Za-z0-9._/-]+$ and
    # routes anything else to `_unknown`, so the handoff lands where session
    # state never looks) and equally `org/a/b`, `org/`, `/repo`, which name no
    # {owner}/{repo} pair at all — this value is passed straight to
    # handoff-state.sh as --owner-repo, which now refuses them, so accepting one
    # here would update session state and then fail to resolve the checkpoint
    # (CodeAnt, PR #1423). One strict validator, shared with handoff-state.sh,
    # keeps both ends agreeing on what a scope is; the flat path is the right
    # fallback for anything they cannot.
    local _sess_key
    _sess_key="$(normalize_repo_key "$CLAUDE_SESSION_REPO")"
    if is_strict_owner_repo "$_sess_key"; then
      owner_repo="$_sess_key"
      echo "polling-state-gate.sh: notice: '$canon' names no owner/repo; scoping PR #$PR_NUMBER's handoff to the session repo '$owner_repo' (\$CLAUDE_SESSION_REPO) rather than the shared flat path" >&2
    else
      echo "polling-state-gate.sh: notice: \$CLAUDE_SESSION_REPO '$CLAUDE_SESSION_REPO' is not a usable repo key (session-state.sh would route it to '_unknown'); leaving PR #$PR_NUMBER's handoff on the flat path rather than scoping it somewhere session state will never look" >&2
    fi
  fi
  local reviewer="cr"
  if [[ -f "$STATE_FILE" ]]; then
    local r
    r="$(state_pr_field reviewer)"
    [[ -n "$r" ]] && reviewer="$r"
  fi

  # Persist the authorship-override decision for this PR (issue #1266). The
  # documented per-cycle contract calls `polling-state-gate.sh <PR_NUMBER>` with
  # no extra flags, so an override supplied only here would be forgotten on the
  # very next tick and merge-gate.sh's own authorship check would re-add the
  # blocker forever. Written unconditionally — `false` when the flag is absent —
  # so a re-enrolment without the override clears a stale `true` instead of
  # leaving the bypass latched on. Typed `boolean` in
  # .claude/reference/session-state-schema.json's `_field_types.pr_nested`, so a
  # corrupted value is rejected by session-state.sh rather than silently read as
  # permission.
  local allow_nonauthor_json="false"
  [[ "$ALLOW_NONAUTHOR" -eq 1 ]] && allow_nonauthor_json="true"

  # Single atomic write — session-state.sh merges multiple --set in one
  # transaction. Running it from $canon scopes every path to THIS repo
  # (issue #638), so PR #84 here cannot overwrite PR #84 elsewhere.
  # owner_repo stays recorded: it is both #647's scoping signal and the
  # migration key for state written before scoping existed.
  if [[ -n "$owner_repo" ]]; then
    ( cd "$canon" && "$STATE_HELPER" \
        --set ".root_repo=\"$canon\"" \
        --set ".prs[\"$PR_NUMBER\"].root_repo=\"$canon\"" \
        --set ".prs[\"$PR_NUMBER\"].head_sha=\"$head_sha\"" \
        --set ".prs[\"$PR_NUMBER\"].allow_nonauthor=$allow_nonauthor_json" \
        --set ".prs[\"$PR_NUMBER\"].owner_repo=\"$owner_repo\"" )
  else
    ( cd "$canon" && "$STATE_HELPER" \
        --set ".root_repo=\"$canon\"" \
        --set ".prs[\"$PR_NUMBER\"].root_repo=\"$canon\"" \
        --set ".prs[\"$PR_NUMBER\"].head_sha=\"$head_sha\"" \
        --set ".prs[\"$PR_NUMBER\"].allow_nonauthor=$allow_nonauthor_json" )
  fi

  # Resolve the canonical handoff path (scoped when owner_repo is known).
  # Use handoff-state.sh --path so path computation is in one place (issue #655).
  # --legacy-flat is the explicit default here (issue #1366): with no owner_repo
  # — none of `gh repo view`, repo_identity(), or $CLAUDE_SESSION_REPO could name
  # one — this checkpoint IS the repo-less case the flat path exists for, and
  # omitting the scope would now make handoff-state.sh derive one from THIS
  # script's cwd, which is not necessarily $canon — a different repo's path,
  # or exit 2.
  local or_flag=(--legacy-flat)
  [[ -n "$owner_repo" ]] && or_flag=(--owner-repo "$owner_repo")
  local handoff_path
  handoff_path="$("$HANDOFF_HELPER" ${or_flag[@]+"${or_flag[@]}"} --path "$PR_NUMBER")"
  # Backward-compat: also check the flat path so a polling session started before
  # this change can refresh an already-existing flat handoff without moving it.
  local flat_path
  if ! flat_path="$(flat_handoff_path)"; then
    exit 4
  fi
  if [[ ! -f "$handoff_path" && -f "$flat_path" && "$handoff_path" != "$flat_path" ]]; then
    echo "polling-state-gate.sh: notice: using existing flat handoff $flat_path (not yet migrated to $handoff_path)" >&2
    handoff_path="$flat_path"
  fi
  if [[ ! -f "$handoff_path" ]]; then
    write_checkpoint_handoff "$head_sha" "$reviewer" "$owner_repo"
  elif [[ ! -r "$handoff_path" ]] || ! jq -e . "$handoff_path" >/dev/null 2>&1; then
    # Repair, not refresh. The poll-cycle gate now exits 5 on a handoff it
    # cannot read and tells the caller to run --ensure-session; that advice has
    # to be true. The refresh below is a read-modify-write, so on an unparseable
    # file handoff-state.sh --set would fail and leave the loop with no way out.
    # Overwriting is not data loss: a file that cannot be parsed or opened
    # carries no readable phase record to preserve. But that verdict is formed
    # HERE, outside the lock, so it cannot also authorize the write: being
    # serialized behind a concurrent Phase A writer is not the same as being
    # safe from one — losing the race means overwriting the valid handoff it
    # just wrote. The write therefore goes out as --repair, which re-tests the
    # file under the lock and no-ops if it has become readable (CodeAnt, #1598).
    #
    # Repair the file the branch above actually selected: an empty scope routes
    # write_checkpoint_handoff to --legacy-flat, so a corrupt flat handoff is
    # rewritten in place instead of being left behind next to a fresh scoped one.
    local repair_scope="$owner_repo"
    [[ "$handoff_path" == "$flat_path" ]] && repair_scope=""
    echo "polling-state-gate.sh: notice: handoff $handoff_path is unreadable or not valid JSON; re-creating it as a polling checkpoint" >&2
    write_checkpoint_handoff "$head_sha" "$reviewer" "$repair_scope" replace
  else
    # Refresh head_sha only — preserve phase_completed, reviewer, and other Phase A/B fields.
    # Route through handoff-state.sh --set so the whole RMW cycle is under the advisory lock
    # (issue #682 — same fix as #639 applied to session-state.json).
    # Pass --owner-repo when path is the scoped one so we hold the right lock.
    # Otherwise we are deliberately refreshing an already-flat handoff, so say
    # --legacy-flat rather than omitting the scope: omission now derives or
    # refuses (issue #1366), and either outcome would move this write off the
    # very file the branch above chose.
    local set_or_flag=(--legacy-flat)
    [[ "$handoff_path" != "$flat_path" ]] && [[ -n "$owner_repo" ]] && set_or_flag=(--owner-repo "$owner_repo")
    if ! "$HANDOFF_HELPER" ${set_or_flag[@]+"${set_or_flag[@]}"} --set "$PR_NUMBER" ".head_sha=$head_sha"; then
      echo "polling-state-gate.sh: handoff-state.sh --set .head_sha failed for PR #$PR_NUMBER" >&2
      exit 4
    fi
  fi

  # Initialize poll watermarks for all three comment endpoints (issue #741).
  if [[ -x "$POLL_WATERMARKS" ]]; then
    if ! ( cd "$canon" && "$POLL_WATERMARKS" "$PR_NUMBER" --init >/dev/null ); then
      echo "polling-state-gate.sh: poll-watermarks.sh --init failed for PR #$PR_NUMBER" >&2
      exit 4
    fi
  fi

  exit 0
}

require_handoff_and_state() {
  local resolved="$1"
  local gate_mode="${2:-live}"
  # Pin every scoped read below to the repo we actually resolved to (#638).
  [[ -d "$resolved" ]] && STATE_READ_DIR="$resolved"

  # Not registered for THIS repo — checked first, before the handoff path is
  # resolved (issue #854). The handoff path is derived from the per-PR
  # owner_repo, so running this check later meant a PR that only another repo
  # tracks produced an error naming the OTHER repo's handoff directory. Every
  # exit from here is 4; the foreign-scope note is diagnostics, never a scope
  # this run reads from.
  if [[ -f "$STATE_FILE" && -z "$(resolve_pr_scope)" ]]; then
    local active_for_msg foreign foreign_list=""
    active_for_msg="$(active_scope_key)"
    [[ -n "$active_for_msg" ]] || active_for_msg="this repo"
    while IFS= read -r foreign; do
      [[ -n "$foreign" ]] || continue
      foreign_list="${foreign_list:+$foreign_list, }'$foreign'"
    done < <(foreign_pr_scopes)
    local msg="polling-state-gate.sh: PR #$PR_NUMBER is not registered in session-state for '$active_for_msg' — run: polling-state-gate.sh $PR_NUMBER --ensure-session"
    if [[ -n "$foreign_list" ]]; then
      msg="$msg (note: PR #$PR_NUMBER is also registered under $foreign_list; PR numbers are per-repo, so that entry is not used here)"
    fi
    echo "$msg" >&2
    exit 4
  fi

  # Resolve the handoff over the scope precedence handoff-files.md documents
  # (issues #1507 + #1559), not from the per-PR `owner_repo` field alone. See the
  # header for both failure shapes that single-source resolution produced. The
  # scoped layout of issue #655 is preferred; the legacy flat path remains a
  # fallback for the migration window, but is now reached only after every
  # candidate scope has been tried, and always says so.
  local owner_repo_for_path
  owner_repo_for_path="$(state_pr_field owner_repo)"
  [[ "$owner_repo_for_path" == "null" ]] && owner_repo_for_path=""
  local handoff_path="" expected_path="" expected_scope=""
  local cand cand_path cand_why blocked_path="" blocked_dir=""
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    cand_path=""
    # Surfaced, not swallowed: the previous `2>/dev/null || true` turned a
    # helper refusal into an empty path and then into a flat-path fallback,
    # with nothing on any stream to say the scoped layout had been skipped.
    # Streams stay separate — a successful --path call can still print a note
    # (CLAUDE_HANDOFF_FLAT_OK), and a merged capture would make that note part
    # of the path. The failure text is re-read from stderr alone.
    if ! cand_path="$("$HANDOFF_HELPER" --owner-repo "$cand" --path "$PR_NUMBER" 2>/dev/null)" || [[ -z "$cand_path" ]]; then
      cand_why="$("$HANDOFF_HELPER" --owner-repo "$cand" --path "$PR_NUMBER" 2>&1 >/dev/null || true)"
      echo "polling-state-gate.sh: notice: handoff-state.sh could not resolve a path for scope '$cand' (PR #$PR_NUMBER): ${cand_why:-no output}" >&2
      continue
    fi
    # The first candidate names the path the error message reports, so a gate
    # that finds nothing still points at where the handoff was expected.
    if [[ -z "$expected_path" ]]; then
      expected_path="$cand_path"
      expected_scope="$cand"
    fi
    if [[ -f "$cand_path" ]]; then
      handoff_path="$cand_path"
      break
    fi
    # Not found — but distinguish "absent" from "unknowable" before any later
    # branch is allowed to treat this scope as empty and let the flat path
    # answer in its place. Recorded, not fatal here: a later candidate may
    # still hold a readable handoff, and that is a better answer than an error.
    if [[ -z "$blocked_path" ]]; then
      if blocked_dir="$(unsearchable_ancestor "$cand_path")"; then
        blocked_path="$cand_path"
      else
        blocked_dir=""
      fi
    fi
  done < <(handoff_scope_candidates "$resolved" "$owner_repo_for_path")
  local flat_path
  if ! flat_path="$(flat_handoff_path)"; then
    exit 4
  fi
  # An indeterminate scoped path outranks the flat fallback. Falling through
  # here would validate an unrelated record and announce it as "scoped handoff
  # not found", which is a false statement about a file that is very likely
  # sitting right there — exactly the failure mode exit 5 exists to report.
  # Actionable, because the remedy is a permission fix, not --ensure-session:
  # --ensure-session cannot repair what it cannot stat either.
  if [[ -z "$handoff_path" && -n "$blocked_path" ]]; then
    echo "polling-state-gate.sh: unreadable handoff $blocked_path — directory $blocked_dir is not searchable, so whether that handoff exists cannot be determined; refusing to let $flat_path answer for PR #$PR_NUMBER. Run: chmod u+x '$blocked_dir'" >&2
    exit "$HANDOFF_UNREADABLE_EXIT"
  fi
  if [[ -z "$handoff_path" && -f "$flat_path" ]]; then
    # Always announced. The old notice was gated on `owner_repo_for_path`, the
    # very field whose absence caused the misresolution, so the one case where
    # the flat file answered for a scoped handoff was also the one case that
    # printed nothing (issue #1559).
    if [[ -n "$expected_scope" ]]; then
      echo "polling-state-gate.sh: notice: scoped handoff not found for '$expected_scope' PR #$PR_NUMBER; falling back to flat $flat_path (run handoff-migrate.sh to migrate)" >&2
    else
      echo "polling-state-gate.sh: notice: no owner/repo scope could be derived for PR #$PR_NUMBER (no per-PR owner_repo, no \$CLAUDE_SESSION_REPO, and the checkout names none); falling back to flat $flat_path (run: polling-state-gate.sh $PR_NUMBER --ensure-session to record a scope)" >&2
    fi
    handoff_path="$flat_path"
  fi
  if [[ -z "$handoff_path" || ! -f "$handoff_path" || ! -r "$handoff_path" ]]; then
    local reported="${expected_path:-$flat_path}"
    local detail="missing handoff $reported"
    # An existing-but-unreadable file is its own diagnosis: naming the path it
    # "expected" would send the reader looking for a file that is right there.
    [[ -n "$handoff_path" && -e "$handoff_path" ]] && detail="unreadable handoff $handoff_path (exists but is not readable)"
    echo "polling-state-gate.sh: $detail — run: polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
    exit "$HANDOFF_UNREADABLE_EXIT"
  fi
  # Parse-check once, here, rather than letting the first `jq` read below abort
  # under `set -e` with jq's own status — which is 2, this script's documented
  # *usage* code, for what is actually corrupt state (issue #1559).
  if ! jq -e . "$handoff_path" >/dev/null 2>&1; then
    echo "polling-state-gate.sh: unreadable handoff $handoff_path — not valid JSON — run: polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
    exit "$HANDOFF_UNREADABLE_EXIT"
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "polling-state-gate.sh: missing $STATE_FILE — run --ensure-session first" >&2
    exit 4
  fi
  if [[ -z "$(state_pr_field head_sha)$(state_pr_field root_repo)$(state_pr_field reviewer)" ]]; then
    echo "polling-state-gate.sh: PR $PR_NUMBER not registered in session-state for $(cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --repo-key 2>/dev/null || echo "this repo") — run --ensure-session first" >&2
    exit 4
  fi
  local rr state_sha handoff_sha handoff_pr canon live_head
  rr="$(state_pr_field root_repo)"
  state_sha="$(state_pr_field head_sha)"
  handoff_sha=$(jq -r '.head_sha // empty' "$handoff_path")
  handoff_pr=$(jq -r 'if .pr_number == null then "" else (.pr_number | tostring) end' "$handoff_path")
  # The scope-level .root_repo is deliberately NOT required or validated here
  # (issue #647): it records a checkout for the repo as a whole, not for this PR,
  # so it says nothing about whether THIS PR belongs to the active checkout.
  if [[ -z "$rr" || "$rr" == "null" ]]; then
    echo "polling-state-gate.sh: session-state missing .prs[\"$PR_NUMBER\"].root_repo" >&2
    exit 4
  fi
  if [[ -z "$state_sha" || "$state_sha" == "null" ]]; then
    echo "polling-state-gate.sh: session-state missing .prs[\"$PR_NUMBER\"].head_sha" >&2
    exit 4
  fi
  if [[ -z "$handoff_sha" || "$handoff_sha" == "null" ]]; then
    echo "polling-state-gate.sh: handoff missing .head_sha ($handoff_path)" >&2
    exit 4
  fi
  if [[ -z "$handoff_pr" || "$handoff_pr" == "null" ]]; then
    echo "polling-state-gate.sh: handoff missing .pr_number ($handoff_path)" >&2
    exit 4
  fi
  if [[ "$handoff_pr" != "$PR_NUMBER" ]]; then
    echo "polling-state-gate.sh: handoff .pr_number ($handoff_pr) does not match PR $PR_NUMBER ($handoff_path)" >&2
    exit 4
  fi
  if [[ "$state_sha" != "$handoff_sha" ]]; then
    # Name the file. Which handoff answered is the whole question when a scoped
    # and a flat file both exist for one PR (issue #1559).
    echo "polling-state-gate.sh: head_sha mismatch between session-state ($state_sha) and handoff $handoff_path ($handoff_sha) — run polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
    exit 4
  fi
  canon="$(cd "$resolved" && git rev-parse --show-toplevel)"
  if [[ "$gate_mode" == "live" ]]; then
    if ! live_head="$(cd "$canon" && gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>/dev/null)"; then
      echo "polling-state-gate.sh: gh pr view failed (cannot verify live HEAD for PR #$PR_NUMBER)" >&2
      exit 4
    fi
    if [[ -z "$live_head" || "$live_head" == "null" ]]; then
      echo "polling-state-gate.sh: could not read live HEAD for PR #$PR_NUMBER" >&2
      exit 4
    fi
    if [[ "$state_sha" != "$live_head" ]]; then
      echo "polling-state-gate.sh: stored head_sha does not match GitHub HEAD — run polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
      exit 4
    fi
  fi
  if ! validate_root_match "$resolved"; then
    exit 4
  fi
}

if [[ "$MODE" == "ensure" ]]; then
  ensure_session
fi

if [[ "$MODE" == "verify" ]]; then
  resolved=""
  if ! resolved="$(resolve_root_repo "$ROOT_REPO_ARG")"; then
    exit 4
  fi
  require_handoff_and_state "$resolved" verify
  exit 0
fi

# --- default: poll cycle -> merge gate ---
resolved=""
if ! resolved="$(resolve_root_repo "$ROOT_REPO_ARG")"; then
  exit 4
fi
require_handoff_and_state "$resolved" live
canon="$(cd "$resolved" && git rev-parse --show-toplevel)"
GATE_ARGS=("$PR_NUMBER")
# Forward the authorship override (issue #733) so a PR enrolled under
# --allow-nonauthor isn't re-blocked by merge-gate.sh's own independent
# authorship check on every poll cycle (issue #1251).
#
# Read the enrolment-time decision back out of session-state (issue #1266). The
# per-cycle contract in cr-github-review.md passes no flags on these ticks, so
# without this read-back the override survived exactly one invocation and the
# gate could never report "met" for an overridden PR. `state_pr_field` is safe
# here: require_handoff_and_state() above already pinned STATE_READ_DIR to the
# resolved checkout and refused if the PR is not registered for this repo.
#
# Only the literal boolean `true` enables the bypass. Absent, `false`, `null`,
# and any other value all mean "not overridden" — an authorship bypass must be
# granted affirmatively, never inferred from a value we cannot read.
#
# What the persisted value does NOT do, deliberately: it never satisfies an
# authorship check other than merge-gate.sh's, and merge-gate.sh only REPORTS.
# --ensure-session re-reads the flag from its own invocation, never from state,
# so re-enrolling a foreign PR still refuses; admin-merge.sh keeps its own
# independent check, so no merge is authorized by this field. It suppresses one
# blocker line for a PR the user already named in chat to enrol.
#
# safety.md requires a tool operating under the override to SAY SO. On stderr,
# because merge-gate.sh's stdout is the JSON its callers parse — a notice there
# would corrupt the payload. One line per tick, only for overridden PRs, is the
# audit trail a persisted bypass has to carry.
PERSISTED_ALLOW_NONAUTHOR="$(state_pr_field allow_nonauthor)"
if [[ "$ALLOW_NONAUTHOR" -eq 1 || "$PERSISTED_ALLOW_NONAUTHOR" == "true" ]]; then
  GATE_ARGS+=(--allow-nonauthor)
  if [[ "$ALLOW_NONAUTHOR" -eq 1 ]]; then
    echo "polling-state-gate.sh: notice: PR #$PR_NUMBER — operating under an explicit per-PR authorship override passed on this invocation (.claude/rules/safety.md §Authorship); merge-gate.sh's authorship block is suppressed." >&2
  else
    echo "polling-state-gate.sh: notice: PR #$PR_NUMBER — operating under the per-PR authorship override recorded at enrolment (.prs[\"$PR_NUMBER\"].allow_nonauthor, .claude/rules/safety.md §Authorship); merge-gate.sh's authorship block is suppressed. Clear it by re-running --ensure-session without --allow-nonauthor." >&2
  fi
fi
(cd "$canon" && exec "$MERGE_GATE" "${GATE_ARGS[@]}")
