#!/usr/bin/env bash
# session-state.sh — Surgical read/write helper for ~/.claude/session-state.json.
#
# PURPOSE
#   Single helper for read-modify-write operations on ~/.claude/session-state.json
#   with sibling-field preservation and atomic replace. Replaces the verbose
#   inline `jq … > tmp && mv tmp file` blocks scattered across agents and skills,
#   and provides the canonical handle for ad-hoc inspection/mutation of the
#   state file. Models the same atomic-write pattern as
#   .claude/scripts/repair-trust-all.sh and .claude/scripts/greptile-budget.sh.
#
#   Multiple --set flags merge into ONE atomic write (not N sequential writes),
#   so callers can mutate several paths in a single transaction without a
#   partial-write race window between them.
#
# USAGE
#   session-state.sh [--repo <owner/name>] --get <jq-path>
#   session-state.sh [--repo <owner/name>] --set <jq-path>=<value> [--set ...]
#   session-state.sh [--repo <owner/name>] --cas <jq-path>=<new-value> --expect <expected-value>
#   session-state.sh [--repo <owner/name>] --session-view [--all-repos]
#   session-state.sh --repo-key
#   session-state.sh --migrate [--dry-run]
#   session-state.sh --help | -h
#
# REPO SCOPING (issue #638)
#   PR state is scoped per repository: `.repos["<owner>/<name>"].prs["<N>"]`.
#   Before this, `.prs` was a flat map keyed by bare PR number, so two repos
#   that both reached PR #84 silently overwrote each other's tracking data.
#   `.root_repo` had the same defect at the top level — one global scalar
#   naming whichever repo wrote last, which is what made
#   polling-state-gate.sh refuse a perfectly valid checkout as "wrong".
#
#   Callers do NOT have to rewrite their jq paths. A path whose leading
#   component is `.prs` or `.root_repo` is transparently rewritten into the
#   active repo's scope, so `--get '.prs["84"].reviewer'` reads
#   `.repos["<repo>"].prs["84"].reviewer`. Pass --raw-path to address the
#   literal top-level path instead (migration, inspection, tests).
#
#   The active repo key is resolved in this order:
#     1. --repo <owner/name>
#     2. $CLAUDE_SESSION_REPO
#     3. the `origin` remote of the current working directory's git repo
#     4. "_unknown" — a reserved bucket (no `/`, so it can never collide with
#        a real owner/name) used when no repo context is available. A warning
#        is printed to stderr; state is kept, not dropped.
#
# MIGRATION (issue #638)
#   A legacy flat file (`.prs` and/or `.root_repo` at the top level) is
#   migrated into the scoped layout on read and on write, keyed by each
#   entry's own `owner_repo`. Entries with no `owner_repo` fall back to the
#   repo identity of their recorded `root_repo` path when that path still
#   resolves, and otherwise land in `_unknown` — they are preserved, never
#   dropped. Where a scoped entry already exists, its fields win over the
#   legacy ones. `--get` migrates in memory only (a read never rewrites the
#   file); `--set` and `--migrate` persist the migrated layout and stamp
#   `.schema_version = 2`.
#
# MODES
#   --cas <path>=<new> Compare-and-set: read the current value at <jq-path>,
#   --expect <val>     compare it with <expected-value>, and write <new-value>
#                      only when they match — all under one lock hold.
#                      <expected-value> follows the same JSON-or-string rules as
#                      --set: valid JSON is treated as a JSON value (so
#                      `--expect null` compares against JSON null, not the
#                      string "null"); anything that fails JSON parsing is a
#                      bare string. Comparison is jq's `==` (deep equality).
#                      Exits 0 when the write is applied (CAS win). Exits 7
#                      when the current value does not match (CAS loss — a
#                      distinct code so callers can tell a loss from an I/O
#                      error). Other exit codes (2 usage, 4 parse, 5 write,
#                      6 lock-timeout) are unchanged from --set. On exit 7
#                      the state file is left unmodified.
#
#                      Use this instead of a separate --get + --set pair for
#                      any claim that must be atomic: the gap between two
#                      invocations is a race window; --cas eliminates it.
#
#   --get <jq-path>    Read the value at <jq-path> from the state file and
#                      print it on stdout (raw via `jq -r`). Exits 3 if the
#                      state file does not exist; exits 4 on jq parse errors.
#                      Returns "null" with exit 0 if the path is absent but
#                      the file is a valid JSON object — matches jq semantics.
#
#   --repo-key         Print the resolved repo key (see REPO SCOPING) and
#                      exit 0. For consumers that must build their own jq
#                      paths against the state file — e.g.
#                      `jq --arg r "$(session-state.sh --repo-key)" \
#                          '.repos[$r].prs'`.
#
#   --session-view     Print a repo-scoped projection of the WHOLE state file
#                      (issue #687) — the read every orchestration skill (`/pm`,
#                      `/pm-handoff`, …) uses instead of `--get .` so its default
#                      view stays in the invoking repo's lane. The invoking repo
#                      is resolved by the same precedence as every other mode
#                      (see REPO SCOPING: --repo / $CLAUDE_SESSION_REPO / cwd
#                      origin). The projection, applied to the migrated document:
#                        • .prs        = .repos[<key>].prs // {}   (this repo only)
#                        • .root_repo  = .repos[<key>].root_repo // null
#                        • .active_agents = the global array with every entry
#                          that belongs to a DIFFERENT repo removed. Attribution,
#                          in order: an explicit .owner_repo on the entry wins
#                          (kept iff it equals <key>) — the array has no repo
#                          field today, but honoring it here means stamping it at
#                          the write sites later needs no reader change. Absent
#                          that, an entry with no .pr is kept (unattributable);
#                          otherwise it is kept UNLESS its .pr is tracked by some
#                          other repo, which drops both other-repo agents and the
#                          ambiguous same-PR-number-in-two-repos case (a scoped
#                          view under-showing a thread beats leaking another
#                          repo's — the entry is still visible via --all-repos).
#                        • .repos is deleted (no other repo's block remains) and
#                          .repo = <key> is added for reference.
#                        • all other top-level fields (monitoring_active,
#                          cr_hourly, greptile_daily, pmm*, …) pass through — they
#                          are account/session-global, not another repo's PR data.
#                      A read: never rewrites the file (migration is in memory).
#                      Exits 3 if the state file is missing, 4 on a parse error —
#                      same as --get, so `--session-view 2>/dev/null || echo
#                      NO_SESSION_STATE` is a safe caller idiom.
#
#                      With --all-repos, the projection is skipped and the whole
#                      migrated document is printed verbatim — the explicit,
#                      user-initiated cross-repo opt-in (issue #687 AC6). Default
#                      output is always scoped; spanning repos requires the flag.
#
#   --migrate          Persist the legacy -> scoped migration described above
#                      and exit. Idempotent: a already-scoped file is left
#                      alone (beyond the `.last_updated` refresh). With
#                      --dry-run, print the migrated document to stdout and
#                      leave the state file untouched.
#
# FLAGS
#   --repo <owner/name>  Override the active repo key for this invocation.
#   --raw-path           Disable repo-scope path rewriting; `--get`/`--set`
#                        paths address the document root verbatim.
#   --dry-run            With --migrate, print instead of writing.
#   --all-repos          With --session-view, emit the whole (migrated) document
#                        unscoped instead of the invoking-repo projection — the
#                        explicit cross-repo reporting opt-in (issue #687). No
#                        effect on other modes.
#
#   --set <path>=<v>   Set <jq-path> to <value> in the state file, preserving
#                      all other top-level fields. <value> may be:
#                        • A JSON literal — number, boolean, null, JSON object,
#                          JSON array, or quoted string. Detected by attempting
#                          to parse <value> as JSON first.
#                        • A bare string — anything that fails JSON parsing is
#                          treated as a literal string.
#                      Multiple --set flags accumulate into ONE atomic jq
#                      pipeline → ONE temp-file → ONE mv. If the state file is
#                      missing, it is initialized with `{}` and the writes are
#                      applied to that fresh object (exit 0, NOT 3).
#                      Auto-updates `.last_updated` to the current ISO 8601
#                      timestamp on every write — matches the pattern in
#                      greptile-budget.sh and reviewer-of.sh.
#
# EXIT STATUS
#   0  Success — value printed (--get) or write completed (--set). A --get on
#      a corrupted known-typed field (see FIELD-TYPE CONTRACT) also exits 0,
#      printing a safe default instead of the corrupt value.
#   2  Usage error — missing/invalid mode, unknown flag, malformed --set
#      argument (no `=`), no jq path given for --get, or a --repo value that
#      is not a plausible repo key (`[A-Za-z0-9._/-]+`).
#   3  State file missing on --get. (--set creates the file from `{}`.)
#   4  jq failed to parse the file or evaluate the path/expression, OR a
#      --set or --cas would leave a known-typed field (see FIELD-TYPE
#      CONTRACT) holding the wrong JSON type — the write is rejected and the
#      state file is left unmodified.
#   5  Write failed — could not create temp file, could not mv into place,
#      or jq filter pipeline failed during the atomic write. Also returned
#      when the state-lock library (see LOCKING) cannot be loaded.
#   6  Lock timeout — another writer held the state-file lock for longer than
#      the acquisition timeout (default 30s, CLAUDE_STATE_LOCK_TIMEOUT). The
#      write is ABANDONED and the state file is left unmodified; this script
#      never falls back to writing unserialized.
#   7  CAS mismatch (--cas only) — the current value at the given path does
#      not match the --expect value. The state file is left unmodified. This
#      code is distinct from all I/O or locking failures so callers can
#      differentiate a lost race from a broken environment.
#   8  HOME unset — ~/.claude/session-state.json cannot be resolved, so no
#      mode that touches the state file can run (issue #1434). A fresh number
#      rather than an overload of 2-7 above, chosen the way state-lock.sh
#      chose 6, so callers can tell "no HOME in this environment" from a
#      usage error or a genuine I/O failure. --help, every usage error, and
#      --repo-key answer BEFORE this guard — none of them read the state
#      file. There is deliberately no ${HOME:-} fallback: defaulting to empty
#      would fabricate a root-anchored /.claude/session-state.json and strew
#      state at the filesystem root.
#
# LOCKING (issue #639)
#   --set and --cas take an exclusive advisory lock around the ENTIRE
#   read-modify-write cycle — read, compare (--cas), jq pipeline, type-contract
#   check, and the final mv — not just the mv. Without it, two writers could
#   each read the same document, each apply their own change, and each write
#   back, silently losing one of the two changes (last writer wins, no error).
#
#   The lock is a `mkdir`-based lock directory at `<state-file>.lock`, because
#   this fleet runs on macOS where `flock(1)` is not installed by default.
#   A stale lock (holder died mid-write) is detected via the pid/host/epoch
#   metadata inside the lock and broken automatically, so a dead writer cannot
#   wedge every future session. Full contract, tunables, and failure modes:
#   `.claude/scripts/state-lock.sh`.
#
#   --get does NOT lock: `mv` is atomic, so a reader always observes either
#   the pre-write or the post-write document, never a partial one. Reads stay
#   contention-free.
#
#   Every writer of this file must go through this script (or source the same
#   state-lock library) — a lock only one writer respects is not a lock. See
#   `.claude/rules/handoff-files.md`.
#
# FIELD-TYPE CONTRACT (issues #625, #640)
#   Known fields and their required JSON types are loaded at runtime from
#   .claude/reference/session-state-schema.json's `_field_types.top_level`
#   and `_field_types.pr_nested` maps. That file is the single source of
#   truth; fields absent from both maps are unvalidated, preserving the
#   "preserve unknown fields" forward-compatibility convention.
#
#   If the schema file can't be
#   found or parsed (unusual invocation context, e.g. this script copied
#   somewhere without its .claude/reference/ sibling), the contract is
#   disabled for this run with a warning on stderr — --get/--set still work,
#   just without the type guard, rather than hard-failing every state-file
#   operation because a side file is missing.
#
#   Repo scoping (issue #638) moves PR state one level down, so the same
#   contract follows it there: `repos` itself must be an object, every
#   `.repos[*]` must be an object, and every `.repos[*].prs` present must be
#   an object. The `pr_nested` checks apply to entries under each repo's
#   `prs` map. Classification runs on the caller's ORIGINAL path (which
#   still reads `.prs["<N>"].<field>`) while the jq check path is scoped,
#   so #640's guarantee is not quietly lost to the restructure.
#
#   --set and --cas both check the FINAL value of any touched known field
#   after the whole write is applied (not just the raw value passed in), so
#   both whole-field writes (`--set '.active_agents=...'`) and element/
#   sub-path writes (`--set '.active_agents[0]=...'` or, for a per-PR nested
#   field, `--set '.prs["287"].babysit.active=...'`) are covered. If a touched
#   known field would end up the wrong type, the entire write is rejected
#   (exit 4) and the state file is left unmodified — this is what should
#   have caught the original corruption: a caller passed an unevaluated jq
#   filter expression (e.g.
#   `(.active_agents // [] | map(select(.pr_number != 71)))`) as a --set
#   value; since it isn't valid JSON it fell into the --arg (string) branch
#   below and was written verbatim as `.active_agents`'s value. Callers must
#   evaluate any filter locally first (read → jq-filter → pass the
#   resulting JSON array/object as the --set value) — see the
#   read-filter-write pattern in .claude/skills/pr-monitor-and-manage/SKILL.md.
#
#   --cas runs the identical check on its own candidate document once the
#   compare has succeeded and before the commit (issue #1283), so the two
#   write paths accept and reject exactly the same values. Both call
#   enforce_field_type_contract(); there is no second implementation to drift.
#
#   --get on a known top-level field whose *stored* value doesn't match the
#   contract (state corrupted before this guard existed, or written by
#   something bypassing this script) prints a warning to stderr and returns
#   a safe default (`[]`/`{}`) on stdout instead of the corrupt value,
#   exiting 0 so existing read-modify-write callers keep working — the next
#   validated --set through this same field then heals the corruption for
#   good. Per-PR nested fields are validated on --set only (not --get):
#   callers read them through infer-pr.sh or ad-hoc jq, not this script's
#   --get, so there's no read-modify-write caller to protect symmetrically.
#
# OUTPUT
#   --get: raw value on stdout (one line per jq output, like `jq -r`).
#   --set: nothing on stdout when the write succeeds.
#   stderr: one-line error messages on failure.
#
# ATOMICITY
#   The state file is read into a temp file (or seeded as `{}` if missing),
#   piped through a jq pipeline that builds all --set assignments + the
#   `.last_updated` refresh, written to `${STATE_FILE}.tmp.$$`, and then
#   atomically renamed via `mv`. `mv` within the same filesystem is atomic
#   on POSIX. Sibling fields outside the assigned paths are preserved
#   verbatim, and since issue #639 the surrounding read-modify-write cycle is
#   serialized by the lock described in LOCKING — a concurrent writer's change
#   is no longer lost, it simply lands before or after ours.
#
# DEPENDENCIES
#   - jq
#   - mktemp, mv (POSIX)
#   - .claude/scripts/state-lock.sh (sibling library — write serialization)
#   - date (any platform — only TZ-agnostic `date -u +'%Y-%m-%dT%H:%M:%SZ'`)
#
# EXAMPLES
#   # Read a value:
#   session-state.sh --get '.greptile_daily.reviews_used'
#   # -> 3
#
#   # Set a single value (string auto-detected). The path is scoped to the
#   # repo of the current working directory, so this writes
#   # .repos["org/repo"].prs["287"].reviewer:
#   session-state.sh --set '.prs["287"].reviewer=greptile'
#
#   # Same write, against an explicitly named repo (no cwd dependency):
#   session-state.sh --repo org/other --set '.prs["287"].reviewer=greptile'
#
#   # Two repos, same PR number, no collision:
#   session-state.sh --repo org/a --set '.prs["84"].phase=B'
#   session-state.sh --repo org/b --set '.prs["84"].phase=C'
#   session-state.sh --repo org/a --get '.prs["84"].phase'   # -> B
#
#   # Address the document root verbatim (no scoping) — e.g. to inspect a
#   # not-yet-migrated legacy file, or read a genuinely global field:
#   session-state.sh --raw-path --get '.repos | keys'
#
#   # Repo-scoped session view — what /pm and /pm-handoff read instead of
#   # `--get .`, so their default output never spans repos (issue #687):
#   session-state.sh --session-view          # scoped to the cwd repo
#   session-state.sh --repo org/x --session-view
#
#   # Explicit cross-repo opt-in (whole migrated document, unscoped):
#   session-state.sh --session-view --all-repos
#
#   # Build your own scoped jq path in a consumer script:
#   REPO_KEY="$(session-state.sh --repo-key)"
#   jq --arg r "$REPO_KEY" '.repos[$r].prs' ~/.claude/session-state.json
#
#   # Preview the legacy -> scoped migration without touching the file:
#   session-state.sh --migrate --dry-run | jq '.repos | keys'
#
#   # Set multiple values atomically (all in one write):
#   session-state.sh \
#     --set '.prs["287"].phase=B' \
#     --set '.prs["287"].head_sha=abc1234'
#
#   # Set a JSON object literal:
#   session-state.sh --set '.greptile_daily={"date":"","reviews_used":0,"budget":40}'
#
#   # Cache that BugBot is installed for PR 287 (used by escalate-review.sh):
#   session-state.sh --set '.prs["287"].bugbot_installed=true'
#
#   # Rejected: .active_agents is a known array-typed field (issue #625) — a
#   # jq filter expression is not a JSON array, so this exits 4 and leaves
#   # the state file unmodified. Evaluate the filter locally first, then pass
#   # the resulting array (see pr-monitor-and-manage/SKILL.md's read-filter-
#   # write pattern):
#   session-state.sh --set '.active_agents=(.active_agents // [] | map(select(.pr_number != 71)))'
#   # -> exit 4: field '.active_agents' would become type 'string' but must be 'array'
#
#   # Rejected: last_cron_action is a known object-typed per-PR nested field
#   # (issue #640) — a bare string isn't a JSON object, so this exits 4 and
#   # leaves the state file unmodified:
#   session-state.sh --set '.prs["287"].last_cron_action=some bare string'
#   # -> exit 4: field '.prs["287"].last_cron_action' would become type 'string' but must be 'object'
#
#   # Atomic claim: write a record only if the slot is currently unoccupied.
#   # Exits 0 on win, 7 if another caller already owns the slot:
#   session-state.sh --raw-path --cas '.repos["org/repo"].release.in_flight={"claim":"mine"}' \
#     --expect null
#
#   # Update the claim only if it still matches exactly (safe release pattern):
#   session-state.sh --raw-path --cas '.repos["org/repo"].release.in_flight=null' \
#     --expect '{"claim":"mine"}'

set -euo pipefail
# Usage telemetry. `script-usage-report.sh` derives adherence ratios from this
# log, which assumes one line per DELIBERATE invocation — a choice some agent or
# human made. Render-loop callers break that assumption: statusline.sh invokes
# this script on a refresh timer, so it sets CLAUDE_SCRIPT_USAGE_LOG=0 to keep
# thousands of automatic reads a day out of the denominator (issue #779).
# Opt-out only, and never the default: every ordinary call still logs.
# Best-effort — must never change this script's exit contract (issue #1430):
# skipped when HOME is unset, stderr muted BEFORE the append per issue #1406's
# ordering.
if [[ "${CLAUDE_SCRIPT_USAGE_LOG:-1}" != "0" && -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

# NOTE: $STATE_FILE is deliberately NOT computed here. Its ${HOME} expansion
# used to sit at this line and aborted every HOME-less invocation under `set -u`
# before argument parsing could answer --help (issue #1434). It is now
# initialized, behind an explicit guard, just below the --repo-key block — the
# first point past which every remaining mode reads or writes the state file.
#
# Saved before any parsing consumes them, so a read-modify-write whose lock was
# stolen mid-flight can be retried from scratch by re-exec'ing this script (see
# the state_lock_assert_held branch just before the commit, near the end).
ORIG_ARGS=("$@")

# Sibling reference file that is the single source of truth for the
# FIELD-TYPE CONTRACT (issues #625, #640) — resolved relative to this
# script's own location (not $STATE_FILE's directory) so it works from every
# known invocation path (repo-local .claude/scripts/, the skills worktree,
# or a caller's own $SELF_DIR-relative lookup) without hardcoding an
# absolute path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="${SCRIPT_DIR}/../reference/session-state-schema.json"

# Write serialization (issue #639). Sourced rather than exec'd so the lock is
# owned by THIS process and released by its EXIT trap. Reuses $SCRIPT_DIR
# above rather than resolving this script's directory a second time.
if [[ ! -f "$SCRIPT_DIR/state-lock.sh" || ! -r "$SCRIPT_DIR/state-lock.sh" ]]; then
  echo "session-state.sh: missing sibling library: $SCRIPT_DIR/state-lock.sh" >&2
  exit 5
fi
# shellcheck source=./state-lock.sh
if ! source "$SCRIPT_DIR/state-lock.sh"; then
  echo "session-state.sh: failed to load $SCRIPT_DIR/state-lock.sh" >&2
  exit 5
fi

# Shared case-normalizer (issue #704). Provides normalize_repo_key() so every
# path that produces a .repos["<key>"] scope key lowercases consistently,
# preventing a mixed-case origin remote from splitting PR tracking across two
# scopes.  Sourced by session-state.sh, polling-state-gate.sh, and
# handoff-state.sh — that single shared definition means the three scripts
# can never drift on case normalization again.
NORMALIZER_LIB="${SCRIPT_DIR}/lib/repo-normalizer.sh"
if [[ ! -f "$NORMALIZER_LIB" || ! -r "$NORMALIZER_LIB" ]]; then
  echo "session-state.sh: missing sibling library: $NORMALIZER_LIB" >&2
  exit 5
fi
# shellcheck source=./lib/repo-normalizer.sh
if ! source "$NORMALIZER_LIB"; then
  echo "session-state.sh: failed to load $NORMALIZER_LIB" >&2
  exit 5
fi

print_help() {
  sed -n '/^# PURPOSE$/,/^$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die_usage() {
  echo "session-state.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# One named line + exit 8 instead of bash's `HOME: unbound variable` trace
# (issue #1434). Same shape as die_usage above; see the EXIT STATUS header for
# why 8 and why no ${HOME:-} fallback.
die_home_unset() {
  echo "session-state.sh: HOME is unset; cannot resolve ~/.claude/session-state.json" >&2
  exit 8
}

# Validate that the state file contains exactly ONE top-level JSON object.
# `jq empty` and `jq -e 'type == "object"'` both succeed on multi-document
# files like `{}\n{}` because jq processes documents independently — the
# slurp (-s) check folds them into an array so we can assert length == 1.
# Without this guard, --get returns N values per path and --set rewrites N
# objects, corrupting the state file. Non-zero exit on any of: parse error,
# multi-document, scalar/array/null at top level.
is_single_object_state_file() {
  jq -s -e 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
}

# Field-type contract (issues #625, #640) — loaded once, lazily, from
# .claude/reference/session-state-schema.json's `_field_types` object (the
# single source of truth; see the FIELD-TYPE CONTRACT header comment). Two
# newline-separated "key=type" caches, one for top-level fields and one for
# per-PR nested fields, parsed by known_field_type()/known_nested_field_type()
# below. Plain variables (not associative arrays) so this script stays
# compatible with bash 3.2 (macOS system bash has no `declare -A`).
FIELD_TYPES_LOADED=0
FIELD_TYPES_TOP=""
FIELD_TYPES_NESTED=""

load_field_types() {
  if [[ "$FIELD_TYPES_LOADED" -eq 1 ]]; then
    return 0
  fi
  FIELD_TYPES_LOADED=1
  if [[ ! -f "$SCHEMA_FILE" ]]; then
    echo "session-state.sh: warning: field-type contract schema not found at $SCHEMA_FILE — type guard disabled for this run (see issue #640)" >&2
    return 0
  fi
  local top nested
  if ! top="$(jq -r '._field_types.top_level // {} | to_entries[] | "\(.key)=\(.value)"' "$SCHEMA_FILE" 2>/dev/null)"; then
    echo "session-state.sh: warning: could not parse field-type contract from $SCHEMA_FILE — type guard disabled for this run (see issue #640)" >&2
    return 0
  fi
  nested="$(jq -r '._field_types.pr_nested // {} | to_entries[] | "\(.key)=\(.value)"' "$SCHEMA_FILE" 2>/dev/null)" || nested=""
  FIELD_TYPES_TOP="$top"
  FIELD_TYPES_NESTED="$nested"
}

# Prints the expected JSON type ("array"/"object"/etc) for a known top-level
# field per the schema-driven contract, or nothing for fields outside it
# (left unvalidated for forward-compatibility).
known_field_type() {
  load_field_types
  local key="$1" line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<<"$FIELD_TYPES_TOP"
}

# Prints the expected JSON type for a known per-PR nested field (e.g.
# "last_cron_action" -> "object"), or nothing for fields outside the
# contract. Field name only — callers resolve the concrete `.prs["<N>"].<key>`
# check path themselves via pr_number_of()/pr_nested_key_of() below.
known_nested_field_type() {
  load_field_types
  local key="$1" line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<<"$FIELD_TYPES_NESTED"
}

# ---------------------------------------------------------------------------
# Repo scoping (issue #638)
# ---------------------------------------------------------------------------

# Reserved bucket for state we cannot attribute to a repo. Contains no `/`,
# so it can never be confused with a real `owner/name` key.
UNKNOWN_REPO_KEY="_unknown"

# Accept only plausible repo keys. This value is interpolated into a jq path,
# so anything with quotes/brackets/backslashes is rejected outright rather
# than escaped — there is no legitimate owner/name containing them.
is_valid_repo_key() {
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]]
}

# Derive `owner/name` from a git remote URL. Handles every form git uses:
#   https://github.com/owner/name(.git)
#   git@github.com:owner/name(.git)          (scp-like, no scheme)
#   ssh://git@github.com:22/owner/name(.git) (explicit port)
# Prints nothing when the URL doesn't yield two trailing path segments.
#
# The scp-like form is why this normalizes the separator instead of stripping
# a host segment: after the scheme and `user@` come off, `github.com/owner/name`
# still carries a host to drop but `github.com:owner/name` does not — stripping
# one path segment from both collapses the scp form to just `name`, losing the
# owner entirely and sending every SSH-remote checkout into the "_unknown"
# bucket. Turning `:` into `/` first makes both shapes the same problem: take
# the last two segments.
repo_key_from_remote_url() {
  local url="${1%.git}"
  url="${url%/}"
  url="${url##*://}"   # drop scheme
  url="${url##*@}"     # drop user@
  url="${url/:/\/}"    # scp-like (and :port) separator -> path separator
  local name="${url##*/}"
  local owner_path="${url%/*}"
  local owner="${owner_path##*/}"
  # A single-segment remainder leaves owner == name; that is not a repo key.
  # Lowercase via the shared normalizer (issue #704) so a mixed-case origin
  # remote ("AuerbachB/Skingod") produces the same scope key as the lowercase
  # form ("auerbachb/skingod") that polling-state-gate.sh's repo_identity()
  # has always emitted.
  if [[ -n "$owner" && -n "$name" && "$owner_path" != "$url" ]]; then
    normalize_repo_key "${owner}/${name}"
  fi
}

# Repo identity of a checkout path (worktrees included — `git -C` resolves
# them to the same origin as their root repo, which is exactly the property
# that makes this a safer scope key than the checkout path itself).
repo_key_of_path() {
  local path="$1" url=""
  [[ -d "$path" ]] || return 0
  url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
  [[ -n "$url" ]] || return 0
  repo_key_from_remote_url "$url"
}

# Resolve the active repo key per the order documented in REPO SCOPING.
# Warns exactly once when falling through to the reserved bucket, so a caller
# running outside any git repo still works instead of failing hard.
REPO_KEY=""
resolve_repo_key() {
  if [[ -n "$REPO_KEY" ]]; then
    printf '%s' "$REPO_KEY"
    return 0
  fi
  local key=""
  if [[ -n "$REPO_ARG" ]]; then
    key="$REPO_ARG"
  elif [[ -n "${CLAUDE_SESSION_REPO:-}" ]]; then
    key="$CLAUDE_SESSION_REPO"
  else
    key="$(repo_key_of_path "$PWD")"
  fi
  # Lowercase-normalize at a single point covering all three key sources:
  #   (a) cwd origin via repo_key_from_remote_url (already normalized, but
  #       belt-and-suspenders is cheap),
  #   (b) --repo <REPO_ARG> (caller may pass mixed-case "Owner/Repo"),
  #   (c) $CLAUDE_SESSION_REPO (same concern).
  # Issue #704: this is what prevents a caller like `--repo AuerbachB/Skingod`
  # from landing in a different .repos scope than `auerbachb/skingod`.
  [[ -n "$key" ]] && key="$(normalize_repo_key "$key")"
  if [[ -z "$key" ]] || ! is_valid_repo_key "$key"; then
    if [[ -n "$key" ]]; then
      echo "session-state.sh: ignoring implausible repo key '$key'; using '$UNKNOWN_REPO_KEY'" >&2
    else
      echo "session-state.sh: no repo context (not in a git repo with an 'origin' remote, and no --repo/\$CLAUDE_SESSION_REPO); scoping to '$UNKNOWN_REPO_KEY'" >&2
    fi
    key="$UNKNOWN_REPO_KEY"
  fi
  REPO_KEY="$key"
  printf '%s' "$REPO_KEY"
}

# Rewrite a caller's jq path into the active repo's scope when its leading
# component is one of the per-repo fields. Only the leading component is
# touched, so trailing jq syntax survives intact:
#   .prs["84"].reviewer  ->  .repos["org/x"].prs["84"].reviewer
#   .prs | keys          ->  .repos["org/x"].prs | keys
#   .prs // {}           ->  .repos["org/x"].prs // {}
# Any other path (including `.` and genuinely global fields like
# .active_agents) is returned unchanged.
scope_path() {
  local path="$1"
  if [[ "$RAW_PATH" == "1" ]]; then
    printf '%s' "$path"
    return 0
  fi
  local field rest=""
  for field in prs root_repo; do
    # Match `.<field>` only at a real token boundary — `.prs_backup` and
    # `.root_repo_history` must not be rewritten. `?` is included because
    # jq's optional-index form (`.prs?[...]`) is a legal way to spell the
    # same read, and silently leaving it unscoped would return null from the
    # now-empty top level: a wrong answer rather than an error.
    if [[ "$path" == ".${field}" || "$path" == ".${field}?" ]]; then
      rest="${path#.${field}}"
    elif [[ "$path" == ".${field}."* || "$path" == ".${field}["* || "$path" == ".${field} "* || \
            "$path" == ".${field}|"* || "$path" == ".${field})"* || "$path" == ".${field}?"* ]]; then
      rest="${path#.${field}}"
    else
      continue
    fi
    printf '.repos["%s"].%s%s' "$(resolve_repo_key)" "$field" "$rest"
    return 0
  done
  printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Legacy -> scoped migration (issue #638)
# ---------------------------------------------------------------------------

# Build a JSON map of {<root_repo path>: <owner/name>} for every distinct
# checkout path recorded in the legacy document. Entries that never carried
# an `owner_repo` can then still be attributed correctly whenever their
# recorded path still resolves to a checkout on disk.
build_path_map() {
  local file="$1" path key
  local map="{}"
  local paths
  paths="$(jq -r '
      [ (.root_repo // empty),
        ( if (.prs | type) == "object" then (.prs[] | .root_repo // empty) else empty end )
      ] | map(select(type == "string" and length > 0)) | unique | .[]' "$file" 2>/dev/null || true)"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    key="$(repo_key_of_path "$path")"
    [[ -n "$key" ]] && is_valid_repo_key "$key" || continue
    map="$(jq -c --arg p "$path" --arg k "$key" '. + {($p): $k}' <<<"$map")"
  done <<<"$paths"
  printf '%s' "$map"
}

# jq program text. Applied to the whole document; a no-op on an
# already-scoped file beyond stamping `.schema_version`.
#
# Conflict rule: `$e.value + (existing // {})` — the already-scoped entry's
# fields win over the legacy ones, since scoped state is by definition newer
# than the flat state it replaced.
MIGRATE_JQ='
def _scoped($pathmap; $unknown):
  . as $doc
  | (if ($doc.prs | type) == "object" then $doc.prs else {} end) as $legacy
  | reduce ($legacy | to_entries[]) as $e (
      $doc;
      ( ($e.value.owner_repo? // null) as $o
      | ($e.value.root_repo? // null) as $r
      | (if ($o | type) == "string" and ($o | length) > 0 then $o
         elif ($r | type) == "string" and ($pathmap[$r] != null) then $pathmap[$r]
         else $unknown end | ascii_downcase) as $key
      | .repos = ( (.repos // {})
          | .[$key] = ( (.[$key] // {})
              | .prs = ( (.prs // {})
                  | .[$e.key] = ($e.value + (.[$e.key] // {})) ) ) )
      )
    )
  | ( if ($doc.root_repo | type) == "string" and ($doc.root_repo | length) > 0
      then ( ($pathmap[$doc.root_repo] // $unknown | ascii_downcase) as $rk
             | .repos = ( (.repos // {})
                 | .[$rk] = ( (.[$rk] // {})
                     | if (.root_repo // null) == null then .root_repo = $doc.root_repo else . end ) ) )
      else . end )
  | del(.prs) | del(.root_repo)
  | .schema_version = 2;

def migrate($pathmap; $unknown):
  if (.prs != null and (.prs | type) != "object")
     or (.root_repo != null and (.root_repo | type) != "string")
  then .
  elif (.prs != null) or (.root_repo != null)
  then _scoped($pathmap; $unknown)
  else (.schema_version // 2) as $v | .schema_version = $v
  end;
'

# True when the document carries legacy top-level keys whose shape we refuse
# to migrate (corrupt `.prs`/`.root_repo`). Callers warn rather than silently
# leaving the data stranded.
has_unmigratable_legacy() {
  jq -e '(.prs != null and (.prs | type) != "object")
         or (.root_repo != null and (.root_repo | type) != "string")' "$1" >/dev/null 2>&1
}

# Extract the leading top-level key from a jq path, e.g.
# ".active_agents[0].id" -> "active_agents", `.prs["287"].reviewer` -> "prs".
# Also handles bracket notation for the top-level key itself, e.g.
# `.["active_agents"]` -> "active_agents" — without this, a path starting
# with `[` fell straight through the dot-form pattern below (which cuts at
# the first `.` or `[`) and produced an empty string, silently exempting
# that field from the contract (CodeAnt finding on PR #630, issue #625).
# Used to look up known_field_type() regardless of how deep the caller's
# path indexes below that top-level field.
top_level_key_of() {
  local path="${1#.}"
  if [[ "$path" == \[* ]]; then
    path="${path#\[}"
    path="${path%%]*}"
    path="${path#[\"\']}"
    path="${path%[\"\']}"
    printf '%s' "$path"
  else
    printf '%s' "${path%%[.[]*}"
  fi
}

# Extract the PR-number key from a path whose top-level key is "prs", e.g.
# `.prs["287"].last_cron_action` -> "287". Every known caller uses bracket
# notation for the PR-number selector (`.prs["<N>"]`), so only that form is
# recognized; a bare `.prs.287...` (unusual — jq requires bracket or quoted-
# dot notation for a numeric key) returns empty, same as an absent selector.
pr_number_of() {
  local path="${1#.prs}"
  if [[ "$path" != \[* ]]; then
    printf '%s' ""
    return 0
  fi
  path="${path#\[}"
  path="${path%%]*}"
  path="${path#[\"\']}"
  path="${path%[\"\']}"
  printf '%s' "$path"
}

# Extract the per-PR nested field name immediately after the PR-number
# selector, e.g. `.prs["287"].babysit.active` -> "babysit" (the known field
# two levels up from a subpath write — the same principle top_level_key_of()
# applies for top-level fields, e.g. `.active_agents[0].id` -> "active_agents").
# Returns empty if the path's top-level key isn't "prs", there's no bracket
# PR-number selector, or nothing follows it (a whole-`.prs["<N>"]` entry
# replacement isn't checked here — the existing top-level object-type check
# on `prs` itself still applies).
pr_nested_key_of() {
  if [[ "$(top_level_key_of "$1")" != "prs" ]]; then
    printf '%s' ""
    return 0
  fi
  local path
  path="$(pr_number_of "$1")"
  if [[ -z "$path" ]]; then
    printf '%s' ""
    return 0
  fi
  # Re-derive the remainder after the PR-number selector (pr_number_of()
  # only returns the extracted number, not the leftover path).
  path="${1#.prs}"
  path="${path#\[*\]}"
  path="${path#.}"
  if [[ -z "$path" ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ "$path" == \[* ]]; then
    path="${path#\[}"
    path="${path%%]*}"
    path="${path#[\"\']}"
    path="${path%[\"\']}"
    printf '%s' "$path"
  else
    printf '%s' "${path%%[.[]*}"
  fi
}

# Returns the PR number when `path` is a WHOLE-entry write, e.g. `.prs["999"]`
# -> "999" (nothing follows the PR-number selector) — as opposed to a nested
# write like `.prs["999"].reviewer`, which returns empty here even though
# "reviewer" isn't a known field. This distinction matters (CodeAnt finding,
# issue #640, PR #654): pr_nested_key_of() deliberately returns empty for a
# whole-entry write since there's no single nested key to check — but that
# left a real gap, since a whole-entry write's value can still embed a
# malformed known nested field (e.g. `--set '.prs["999"]={"last_cron_action":
# "bare string"}'`) that the top-level `.prs` object-type check alone can't
# catch. Used below to trigger a full per-known-field scan of the written
# entry, not just the single-path check pr_nested_key_of() enables.
pr_whole_entry_write_number_of() {
  if [[ "$(top_level_key_of "$1")" != "prs" ]]; then
    printf '%s' ""
    return 0
  fi
  local num
  num="$(pr_number_of "$1")"
  if [[ -z "$num" ]]; then
    printf '%s' ""
    return 0
  fi
  local rest="${1#.prs}"
  rest="${rest#\[*\]}"
  if [[ -n "$rest" ]]; then
    printf '%s' ""
    return 0
  fi
  printf '%s' "$num"
}

# Field-type contract enforcement, shared by --set and --cas (issue #1283).
# Both modes build a candidate document in a temp file and then commit it with
# `mv`; this runs every contract check against that candidate BEFORE the
# commit, so a rejected write leaves $STATE_FILE untouched. Extracted rather
# than duplicated so the two write paths can never drift apart — the whole
# point of #1283 was that --cas silently accepted values --set rejects.
#
# $1 is the candidate file. The touched-field records are read from three
# variables the caller populates while classifying its write path(s):
#   TOUCHED_KNOWN_FIELDS  — space-separated known-typed top-level keys
#   TOUCHED_NESTED_CHECKS — space-separated "<PR-number>:<nested-key>" pairs
#   WHOLE_ENTRY_PRS       — space-separated PRs written as a whole entry
#
# On any violation this exits 4 directly instead of returning — both callers
# want exactly that, and it keeps the message and exit behavior identical
# between them. MUST therefore be invoked as a plain statement: calling it in
# an `if`/`&&`/`||` context would disable `set -e` for the entire body.
enforce_field_type_contract() {
  local candidate="$1"
  local set_touched_key set_expected_type set_actual_type
  local nested_pair nested_pr_number nested_field_key nested_expected_type
  local nested_check_path nested_actual_type
  local whole_entry_pr whole_entry_key whole_entry_expected_type
  local whole_entry_check_path whole_entry_actual_type
  local known_nested_keys bad_scope bad_path bad_actual

  # The input document was already required to be exactly one JSON object; a
  # candidate that is not is a jq-pipeline surprise, and committing it would
  # corrupt the file in exactly the way that input guard exists to prevent.
  if ! is_single_object_state_file "$candidate"; then
    echo "session-state.sh: refusing to write — the resulting document is not a single top-level JSON object; $STATE_FILE left unmodified" >&2
    exit 4
  fi

  # Field-type contract (issue #625): reject the write if any known
  # array/object-typed field touched by this batch would end up the wrong
  # type in the FINAL document — not just the raw written value, so subpath/
  # element writes (e.g. `.active_agents[0]=...`) are covered too, not just
  # whole-field writes. This is what should have caught the original
  # corruption: an unevaluated jq filter expression passed as a value falls
  # into the --arg (string) branch at the call site and would otherwise be
  # written verbatim, turning an array field into a literal string.
  for set_touched_key in $TOUCHED_KNOWN_FIELDS; do
    set_expected_type="$(known_field_type "$set_touched_key")"
    set_actual_type="$(jq -r ".${set_touched_key} | type" "$candidate" 2>/dev/null)"
    if [[ "$set_actual_type" != "$set_expected_type" ]]; then
      echo "session-state.sh: refusing to write — field '.$set_touched_key' would become type '$set_actual_type' but must be '$set_expected_type' (see issue #625); $STATE_FILE left unmodified" >&2
      exit 4
    fi
  done

  # Field-type contract, per-PR nested fields (issue #640): same principle as
  # the top-level loop above, extended to reach fields nested under a specific
  # `.prs["<N>"]` entry — e.g. PR #542's `last_cron_action` holding a bare
  # string where every consumer (infer-pr.sh, wrap, babysit-pr) expects an
  # object. Checked against the FINAL value at the concrete `.prs["<N>"].<key>`
  # path, so sub-path writes (e.g. `.prs["287"].babysit.active=...`) are
  # covered by checking the whole `babysit` object's final type, not just the
  # raw written value.
  for nested_pair in $TOUCHED_NESTED_CHECKS; do
    nested_pr_number="${nested_pair%%:*}"
    nested_field_key="${nested_pair#*:}"
    nested_expected_type="$(known_nested_field_type "$nested_field_key")"
    nested_check_path="$(scope_path ".prs[\"${nested_pr_number}\"].${nested_field_key}")"
    nested_actual_type="$(jq -r "${nested_check_path} | type" "$candidate" 2>/dev/null)"
    if [[ "$nested_actual_type" != "$nested_expected_type" ]]; then
      echo "session-state.sh: refusing to write — field '$nested_check_path' would become type '$nested_actual_type' but must be '$nested_expected_type' (see issue #640); $STATE_FILE left unmodified" >&2
      exit 4
    fi
  done

  # Field-type contract, whole-PR-entry writes (issue #640, CodeAnt finding on
  # PR #654): a write like `.prs["999"]={...}` replaces the whole entry, so the
  # per-path tracking never sees a specific nested-field path to check — but
  # the embedded object can still carry a malformed known field (e.g.
  # `last_cron_action` as a bare string) that the top-level `.prs` object-type
  # check alone can't catch. For every PR written as a whole entry, check
  # EVERY known nested key present in the FINAL entry (absent keys are type
  # "null" and are skipped — a whole-entry write simply omitting a known field
  # is not corruption, same as any other unset nested field).
  if [[ -n "$WHOLE_ENTRY_PRS" ]]; then
    load_field_types
    known_nested_keys="$(printf '%s\n' "$FIELD_TYPES_NESTED" | cut -d= -f1)"
    for whole_entry_pr in $WHOLE_ENTRY_PRS; do
      while IFS= read -r whole_entry_key; do
        [[ -z "$whole_entry_key" ]] && continue
        whole_entry_expected_type="$(known_nested_field_type "$whole_entry_key")"
        whole_entry_check_path="$(scope_path ".prs[\"${whole_entry_pr}\"].${whole_entry_key}")"
        whole_entry_actual_type="$(jq -r "${whole_entry_check_path} | type" "$candidate" 2>/dev/null)"
        if [[ "$whole_entry_actual_type" != "null" && "$whole_entry_actual_type" != "$whole_entry_expected_type" ]]; then
          echo "session-state.sh: refusing to write — field '$whole_entry_check_path' would become type '$whole_entry_actual_type' but must be '$whole_entry_expected_type' (see issue #640); $STATE_FILE left unmodified" >&2
          exit 4
        fi
      done <<<"$known_nested_keys"
    done
  fi

  # Per-repo scope contract (issue #638): `.prs` kept its object-typed
  # guarantee when it moved down a level, so check the shape of every repo
  # scope — `.repos` an object, each `.repos[*]` an object, each
  # `.repos[*].prs` present an object. Without this, the write-time guard that
  # #625 added for a top-level `.prs` would have been quietly lost to the
  # restructure. Reported as the offending scope's own path so the message
  # still names the exact field, as before.
  #
  # The offending scope is emitted as `<path><US><actual-type>` (U+001F unit
  # separator) rather than whitespace-joined: repo keys are caller data and a
  # whitespace split would mangle any key containing one.
  bad_scope="$(jq -r '
    def bad:
      if (.repos // null) == null then empty
      elif (.repos | type) != "object" then ".repos\u001f" + (.repos | type)
      else
        ( .repos | to_entries[]
          | if (.value | type) != "object"
            then ".repos[\"" + .key + "\"]\u001f" + (.value | type)
            elif (.value.prs != null) and ((.value.prs | type) != "object")
            then ".repos[\"" + .key + "\"].prs\u001f" + (.value.prs | type)
            else empty end )
      end;
    [bad] | (first // "")' "$candidate" 2>/dev/null || echo "")"
  if [[ -n "$bad_scope" ]]; then
    bad_path="${bad_scope%%$'\x1f'*}"
    bad_actual="${bad_scope##*$'\x1f'}"
    echo "session-state.sh: refusing to write — field '$bad_path' would become type '$bad_actual' but must be 'object' (see issue #638); $STATE_FILE left unmodified" >&2
    exit 4
  fi
}

# --- arg parsing ---
MODE=""
GET_PATH=""
REPO_ARG=""
RAW_PATH="0"
DRY_RUN="0"
ALL_REPOS="0"
# Parallel arrays for --set: SET_PATHS[i] is the jq path, SET_VALUES[i] is
# the literal text the user passed after the `=`. They are interpreted as
# JSON-or-string at write time so we keep their raw form here.
SET_PATHS=()
SET_VALUES=()
# For --cas: the path=new-value pair (split same as --set) and the expected value.
CAS_PATH=""
CAS_VALUE=""
CAS_EXPECT=""
CAS_EXPECT_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --repo)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        die_usage "--repo requires an <owner/name> value"
      fi
      if ! is_valid_repo_key "$2"; then
        die_usage "--repo value is not a plausible repo key: $2"
      fi
      REPO_ARG="$2"
      shift 2
      ;;
    --raw-path)
      RAW_PATH="1"
      shift
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    --all-repos)
      ALL_REPOS="1"
      shift
      ;;
    --repo-key)
      if [[ -n "$MODE" ]]; then
        die_usage "--repo-key cannot be combined with --$MODE"
      fi
      MODE="repo-key"
      shift
      ;;
    --session-view)
      if [[ -n "$MODE" ]]; then
        die_usage "--session-view cannot be combined with --$MODE"
      fi
      MODE="session-view"
      shift
      ;;
    --migrate)
      if [[ -n "$MODE" ]]; then
        die_usage "--migrate cannot be combined with --$MODE"
      fi
      MODE="migrate"
      shift
      ;;
    --get)
      if [[ -n "$MODE" && "$MODE" != "get" ]]; then
        die_usage "--get cannot be combined with --$MODE"
      fi
      if [[ $# -lt 2 ]]; then
        die_usage "--get requires a jq path"
      fi
      if [[ -n "$GET_PATH" ]]; then
        die_usage "--get may only be given once"
      fi
      MODE="get"
      GET_PATH="$2"
      shift 2
      ;;
    --set)
      if [[ -n "$MODE" && "$MODE" != "set" ]]; then
        die_usage "--set cannot be combined with --$MODE"
      fi
      if [[ $# -lt 2 ]]; then
        die_usage "--set requires <jq-path>=<value>"
      fi
      MODE="set"
      local_arg="$2"
      # Split on the FIRST `=` only — values may contain `=` (e.g., a JSON
      # string with `=` inside it).
      if [[ "$local_arg" != *=* ]]; then
        die_usage "--set argument must be <jq-path>=<value>, got: $local_arg"
      fi
      # Reject empty LHS so `--set =foo` fails at the usage-error stage
      # (exit 2) instead of falling through to a cryptic jq pipeline error
      # (exit 5). The `*=*` glob above accepts "=foo"; this guard rejects it.
      if [[ -z "${local_arg%%=*}" ]]; then
        die_usage "--set requires a non-empty jq path, got: $local_arg"
      fi
      SET_PATHS+=("${local_arg%%=*}")
      SET_VALUES+=("${local_arg#*=}")
      shift 2
      ;;
    --cas)
      if [[ -n "$MODE" && "$MODE" != "cas" ]]; then
        die_usage "--cas cannot be combined with --$MODE"
      fi
      if [[ $# -lt 2 ]]; then
        die_usage "--cas requires <jq-path>=<new-value>"
      fi
      if [[ -n "$CAS_PATH" ]]; then
        die_usage "--cas may only be given once"
      fi
      MODE="cas"
      cas_arg="$2"
      if [[ "$cas_arg" != *=* ]]; then
        die_usage "--cas argument must be <jq-path>=<new-value>, got: $cas_arg"
      fi
      if [[ -z "${cas_arg%%=*}" ]]; then
        die_usage "--cas requires a non-empty jq path, got: $cas_arg"
      fi
      CAS_PATH="${cas_arg%%=*}"
      CAS_VALUE="${cas_arg#*=}"
      shift 2
      ;;
    --expect)
      if [[ $# -lt 2 ]]; then
        die_usage "--expect requires a value"
      fi
      if [[ "$CAS_EXPECT_SET" -eq 1 ]]; then
        die_usage "--expect may only be given once"
      fi
      CAS_EXPECT="$2"
      CAS_EXPECT_SET=1
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      die_usage "unexpected positional argument: $1"
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  die_usage "one of --get, --set, --cas, --session-view, --repo-key or --migrate is required"
fi

# --cas requires --expect; --expect without --cas is a usage error.
if [[ "$MODE" == "cas" && "$CAS_EXPECT_SET" -eq 0 ]]; then
  die_usage "--cas requires --expect <expected-value>"
fi
if [[ "$MODE" != "cas" && "$CAS_EXPECT_SET" -eq 1 ]]; then
  die_usage "--expect is only valid with --cas"
fi
if [[ "$MODE" == "cas" && "$DRY_RUN" == "1" ]]; then
  die_usage "--dry-run is not supported with --cas (--dry-run is only valid with --migrate)"
fi

# --- dependency check ---
if ! command -v jq >/dev/null 2>&1; then
  echo "session-state.sh: 'jq' not found on PATH" >&2
  exit 5
fi

# ============================================================================
# --repo-key
# ============================================================================
# Ordered ahead of the state-path init below: resolving the repo key reads
# --repo / $CLAUDE_SESSION_REPO / the cwd's origin remote and never opens the
# state file, so this mode has no reason to require HOME (issue #1434).
if [[ "$MODE" == "repo-key" ]]; then
  resolve_repo_key
  echo
  exit 0
fi

# --- state-file path (requires HOME) ---
# Every mode from here down reads or writes ~/.claude/session-state.json, so
# HOME is genuinely load-bearing past this point. Everything above — --help,
# every usage error, the dependency check, and --repo-key — answers without it.
if [[ -z "${HOME:-}" ]]; then
  die_home_unset
fi
STATE_FILE="${HOME}/.claude/session-state.json"
# --- ensure state-file directory exists (only needed for --set) ---
STATE_DIR="$(dirname "$STATE_FILE")"

# Warn (once) when the file carries legacy keys we refuse to reshape, so the
# data is never silently stranded under an old path nobody reads any more.
warn_if_unmigratable() {
  if [[ -f "$1" ]] && has_unmigratable_legacy "$1"; then
    echo "session-state.sh: legacy '.prs'/'.root_repo' present but malformed (expected object/string); leaving them in place unmigrated — repair them, then re-run --migrate (see issue #638)" >&2
  fi
}

# Emit the jq args that make the migration program available to a filter.
# Building the path map is only worth the git calls when legacy keys exist.
migrate_jq_args() {
  local file="$1" pathmap="{}"
  if [[ -f "$file" ]] && jq -e '(.prs != null) or (.root_repo != null)' "$file" >/dev/null 2>&1; then
    pathmap="$(build_path_map "$file")"
  fi
  printf '%s' "$pathmap"
}

# ============================================================================
# --get
# ============================================================================
if [[ "$MODE" == "get" ]]; then
  if [[ -z "$GET_PATH" ]]; then
    die_usage "--get requires a jq path"
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "session-state.sh: state file not found: $STATE_FILE" >&2
    exit 3
  fi
  # Reject multi-document, scalar/array/null, and unparseable state files
  # before evaluating the user's path — see is_single_object_state_file().
  if ! is_single_object_state_file "$STATE_FILE"; then
    echo "session-state.sh: $STATE_FILE must contain exactly one top-level JSON object" >&2
    exit 4
  fi

  # Read-time type guard (issue #625): if GET_PATH addresses a known
  # top-level field exactly (not a deeper sub-path) and the stored value's
  # type doesn't match the field-type contract, warn and return a safe
  # default instead of the corrupt value — a "null" (field absent) is not
  # corruption and falls through to the normal read below, matching existing
  # caller idioms like `[ "$X" = "null" ] && X='[]'`. Callers that
  # read-modify-write this field (e.g. pr-monitor-and-manage/SKILL.md) then
  # self-heal it on their next validated --set.
  #
  # "Exactly" is checked against both dot form (.active_agents) and jq's
  # equivalent bracket form (.["active_agents"]) — comparing only against
  # the dot form let a bracket-form GET_PATH slip past this guard even after
  # top_level_key_of() learned to parse it (CodeAnt finding on PR #630). A
  # bracket group with no leading dot (`["active_agents"]`) is deliberately
  # NOT matched here — in jq that's an array-literal constructor, not a way
  # to index the input document, so it never reads the real field either way.
  #
  # The path is scoped BEFORE the guard runs, so the check follows `.prs`
  # down into its new per-repo home: `--get '.prs'` guards
  # `.repos["org/x"].prs` and still returns `{}` if that is corrupt.
  warn_if_unmigratable "$STATE_FILE"
  GET_PATHMAP="$(migrate_jq_args "$STATE_FILE")"
  SCOPED_GET_PATH="$(scope_path "$GET_PATH")"

  get_expected_type=""
  if [[ "$SCOPED_GET_PATH" == "$GET_PATH" ]]; then
    get_top_level_key="$(top_level_key_of "$GET_PATH")"
    get_expected_type="$(known_field_type "$get_top_level_key")"
    if [[ -n "$get_expected_type" ]]; then
      case "$GET_PATH" in
        ".$get_top_level_key"|".[\"$get_top_level_key\"]") ;;
        *) get_expected_type="" ;;
      esac
    fi
  else
    # A rewritten path addresses exactly one per-repo field; only the
    # whole-field forms (`.prs`, `.root_repo`) carry a type contract.
    case "$GET_PATH" in
      ".prs") get_expected_type="object" ;;
    esac
  fi
  if [[ -n "$get_expected_type" ]]; then
    get_actual_type="$(jq -r --argjson __pathmap "$GET_PATHMAP" --arg __unknown "$UNKNOWN_REPO_KEY" \
      "$MIGRATE_JQ migrate(\$__pathmap; \$__unknown) | $SCOPED_GET_PATH | type" "$STATE_FILE" 2>/dev/null)"
    if [[ "$get_actual_type" != "$get_expected_type" && "$get_actual_type" != "null" ]]; then
      echo "session-state.sh: field '$GET_PATH' is corrupted — expected $get_expected_type but found $get_actual_type; returning a safe default (see issue #625)" >&2
      if [[ "$get_expected_type" == "array" ]]; then
        echo '[]'
      else
        echo '{}'
      fi
      exit 0
    fi
  fi

  # Use jq -r so callers get the raw value (string without quotes, number
  # as-is, etc.). jq exits non-zero on parse errors — translate to 4.
  #
  # The migration runs in memory only: a read never rewrites the state file,
  # but it still sees legacy entries in their scoped home, so a session that
  # only ever reads is not blind to state written before the restructure.
  jq_err="$(mktemp)"
  trap "rm -f '$jq_err' 2>/dev/null" EXIT
  if ! jq -r --argjson __pathmap "$GET_PATHMAP" --arg __unknown "$UNKNOWN_REPO_KEY" \
       "$MIGRATE_JQ migrate(\$__pathmap; \$__unknown) | $SCOPED_GET_PATH" "$STATE_FILE" 2>"$jq_err"; then
    echo "session-state.sh: jq failed reading $STATE_FILE: $(cat "$jq_err")" >&2
    exit 4
  fi
  exit 0
fi

# ============================================================================
# --session-view (issue #687)
#   Repo-scoped projection of the whole document — the read orchestration skills
#   use instead of `--get .` so their default view never spans repos. Modeled on
#   --get: file-missing -> 3, non-single-object -> 4, migration in memory only
#   (a read never rewrites the file). See the --session-view MODES header for the
#   projection contract and the active_agents attribution rule.
# ============================================================================
if [[ "$MODE" == "session-view" ]]; then
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "session-state.sh: state file not found: $STATE_FILE" >&2
    exit 3
  fi
  if ! is_single_object_state_file "$STATE_FILE"; then
    echo "session-state.sh: $STATE_FILE must contain exactly one top-level JSON object" >&2
    exit 4
  fi
  warn_if_unmigratable "$STATE_FILE"
  SV_PATHMAP="$(migrate_jq_args "$STATE_FILE")"
  SV_ERR="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$SV_ERR' 2>/dev/null" EXIT

  SV_ARGS=(--argjson __pathmap "$SV_PATHMAP" --arg __unknown "$UNKNOWN_REPO_KEY")
  SV_PROGRAM="$MIGRATE_JQ
migrate(\$__pathmap; \$__unknown)"
  if [[ "$ALL_REPOS" != "1" ]]; then
    # Resolve the invoking repo only on the scoped path, so --all-repos never
    # emits the spurious "no repo context" warning resolve_repo_key prints when
    # it falls through to the _unknown bucket.
    SV_RK="$(resolve_repo_key)"
    SV_ARGS+=(--arg __rk "$SV_RK")
    # active_agents attribution (issue #687). Entries carry no repo field, so:
    #   1. Honor an explicit .owner_repo when present (exact match) — this reader
    #      already respects it, so a later change that stamps owner_repo at the
    #      write sites needs no change here.
    #   2. Else keep an entry with no .pr (unattributable).
    #   3. Else correlate by PR number: keep UNLESS .pr is tracked by some OTHER
    #      repo ($otherpr = every PR key under a real repo != this one). The
    #      _unknown bucket is excluded from $otherpr (issue #712): it holds
    #      unattributed/legacy entries and is not a real repo, so a PR number
    #      there is not evidence the PR belongs to someone else. That drops
    #      genuine other-repo agents AND, conservatively, the ambiguous case
    #      where the same PR number is tracked by two real repos — a scoped
    #      view that under-shows a thread is safer than one that leaks another
    #      repo's. The entry stays visible via --all-repos. Numeric .pr is
    #      stringified to compare against the string PR-map keys.
    SV_PROGRAM="$SV_PROGRAM
| (.repos[\$__rk] // {}) as \$mine
| ([ (.repos // {}) | to_entries[] | select(.key != \$__rk and .key != \$__unknown) | (.value.prs // {}) | keys[] ]) as \$otherpr
| .prs = (\$mine.prs // {})
| .root_repo = (\$mine.root_repo // null)
| .active_agents = ((.active_agents // [])
    | if type != \"array\" then [] else . end
    | map(select(type == \"object\"
        and (
        if (.owner_repo != null) then (.owner_repo == \$__rk)
        elif (.pr == null) then true
        else ((.pr | tostring) as \$p | (\$otherpr | index(\$p)) == null)
        end
        ))))
| del(.repos)
| .repo = \$__rk"
  fi

  if ! jq "${SV_ARGS[@]}" "$SV_PROGRAM" "$STATE_FILE" 2>"$SV_ERR"; then
    echo "session-state.sh: jq failed building session view of $STATE_FILE: $(cat "$SV_ERR")" >&2
    exit 4
  fi
  exit 0
fi

# ============================================================================
# --migrate
# ============================================================================
if [[ "$MODE" == "migrate" ]]; then
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "session-state.sh: state file not found: $STATE_FILE" >&2
    exit 3
  fi
  if ! is_single_object_state_file "$STATE_FILE"; then
    echo "session-state.sh: $STATE_FILE must contain exactly one top-level JSON object" >&2
    exit 4
  fi
  warn_if_unmigratable "$STATE_FILE"
  MIG_PATHMAP="$(migrate_jq_args "$STATE_FILE")"
  MIG_ERR="$(mktemp)"
  MIG_TMP="$STATE_FILE.tmp.$$"
  # shellcheck disable=SC2064
  trap "rm -f '$MIG_TMP' '$MIG_ERR' 2>/dev/null" EXIT
  MIG_FILTER="$MIGRATE_JQ migrate(\$__pathmap; \$__unknown)"
  if [[ "$DRY_RUN" != "1" ]]; then
    MIG_FILTER="$MIG_FILTER | .last_updated = \$__last_updated"
  fi
  if ! jq --argjson __pathmap "$MIG_PATHMAP" \
          --arg __unknown "$UNKNOWN_REPO_KEY" \
          --arg __last_updated "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
          "$MIG_FILTER" "$STATE_FILE" > "$MIG_TMP" 2>"$MIG_ERR"; then
    echo "session-state.sh: migration failed: $(cat "$MIG_ERR")" >&2
    exit 5
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    cat "$MIG_TMP"
    exit 0
  fi
  if ! mv "$MIG_TMP" "$STATE_FILE" 2>/dev/null; then
    echo "session-state.sh: could not write $STATE_FILE" >&2
    exit 5
  fi
  exit 0
fi

# ============================================================================
# --cas (compare-and-set, issue #1195)
# ============================================================================
# Compare the current value at CAS_PATH with CAS_EXPECT under one lock hold;
# write CAS_VALUE only when they match. Exits 0 on win, 7 on mismatch, other
# codes per the exit-status contract (2/4/5/6 unchanged). Runs the SAME
# field-type contract check --set runs, against the candidate document and
# before the commit (issue #1283): a wrong-typed value is rejected with exit 4
# and the state file is left unmodified, so neither write path can accept a
# value the other rejects. Exit 4 stays distinct from 5 (jq/write mechanics)
# and 7 (CAS mismatch).
if [[ "$MODE" == "cas" ]]; then
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "session-state.sh: could not create state dir: $STATE_DIR" >&2
    exit 5
  fi

  # Acquire the lock — read, compare, and write all run under it.
  state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"
  # Install the lock-release trap immediately so every exit path (including
  # the exit 4 below) releases the lock. Temp-file cleanup is added once the
  # files are known (CR finding: lock was held past the validation exit).
  trap "state_lock_release" EXIT

  SEEDED_TMP=""
  input_file="$STATE_FILE"
  if [[ ! -f "$STATE_FILE" ]]; then
    SEEDED_TMP="$(mktemp)"
    printf '%s\n' '{}' > "$SEEDED_TMP"
    input_file="$SEEDED_TMP"
  elif ! is_single_object_state_file "$STATE_FILE"; then
    echo "session-state.sh: $STATE_FILE must contain exactly one top-level JSON object; refusing to overwrite" >&2
    exit 4
  fi

  CAS_ERR="$(mktemp)"
  CAS_OUT_TMP="$STATE_FILE.tmp.$$"
  # shellcheck disable=SC2064
  # Update the trap to also clean up temp files now that they are defined.
  trap "state_lock_release; rm -f '$CAS_OUT_TMP' '$CAS_ERR' ${SEEDED_TMP:+'$SEEDED_TMP'} 2>/dev/null" EXIT

  warn_if_unmigratable "$input_file"
  CAS_PATHMAP="$(migrate_jq_args "$input_file")"
  SCOPED_CAS_PATH="$(scope_path "$CAS_PATH")"

  # Classify the CAS target the way --set classifies each of its touched
  # paths, so enforce_field_type_contract() below checks the same things
  # (issue #1283). Two views of the same write, exactly as in --set:
  #   CAS_PATH        — what the caller asked for, e.g. `.prs["287"].babysit`
  #   SCOPED_CAS_PATH — where it lands, e.g. `.repos["org/x"].prs["287"]...`
  # The TOP-LEVEL check uses the scoped path, because that is the shape of the
  # final document; the per-PR helpers use the original path, because they
  # match on a leading `.prs` and would return empty for every scoped path,
  # silently disabling #640's nested guard here.
  TOUCHED_KNOWN_FIELDS=""
  TOUCHED_NESTED_CHECKS=""
  WHOLE_ENTRY_PRS=""
  cas_top_level_key="$(top_level_key_of "$SCOPED_CAS_PATH")"
  if [[ -n "$(known_field_type "$cas_top_level_key")" ]]; then
    TOUCHED_KNOWN_FIELDS="$cas_top_level_key"
  fi
  cas_nested_key="$(pr_nested_key_of "$CAS_PATH")"
  if [[ -n "$cas_nested_key" ]] && [[ -n "$(known_nested_field_type "$cas_nested_key")" ]]; then
    cas_pr_number="$(pr_number_of "$CAS_PATH")"
    # Digits-only, same as --set: $cas_pr_number is interpolated into the jq
    # filter string built for the nested check path, and requiring that shape
    # keeps the interpolation injection-safe without full jq-string escaping.
    if [[ "$cas_pr_number" =~ ^[0-9]+$ ]]; then
      TOUCHED_NESTED_CHECKS="${cas_pr_number}:${cas_nested_key}"
    fi
  fi
  cas_whole_entry_pr="$(pr_whole_entry_write_number_of "$CAS_PATH")"
  if [[ "$cas_whole_entry_pr" =~ ^[0-9]+$ ]]; then
    WHOLE_ENTRY_PRS="$cas_whole_entry_pr"
  fi

  # Build jq --argjson or --arg for the expected value (same JSON-or-string
  # probe as --set: `--argjson` probe, not `jq -e .`, to reject null/false
  # from the argjson branch — issue #853).
  CAS_COMPARE_ARGS=(--argjson __pathmap "$CAS_PATHMAP" --arg __unknown "$UNKNOWN_REPO_KEY")
  if jq -n --argjson __casexpect "$CAS_EXPECT" 'empty' >/dev/null 2>&1; then
    CAS_COMPARE_ARGS+=(--argjson __casexpect "$CAS_EXPECT")
  else
    CAS_COMPARE_ARGS+=(--arg __casexpect "$CAS_EXPECT")
  fi

  # Read the current value and compare with the expected value in one jq call
  # (inside the lock), so no concurrent writer can slip in between.
  # Use RC=0; VAR="$(cmd)" || RC=$? to capture jq's exit code under set -e;
  # a bare command-substitution assignment terminates the script on failure
  # before CAS_COMPARE_RC=$? is ever evaluated.
  CAS_COMPARE_RC=0
  CAS_COMPARE_RESULT="$(jq -r "${CAS_COMPARE_ARGS[@]}" \
    "$MIGRATE_JQ migrate(\$__pathmap; \$__unknown) | $SCOPED_CAS_PATH as \$cur | if \$cur == \$__casexpect then \"match\" else \"mismatch\" end" \
    "$input_file" 2>"$CAS_ERR")" || CAS_COMPARE_RC=$?

  if [[ "$CAS_COMPARE_RC" -ne 0 ]]; then
    echo "session-state.sh: jq failed reading $STATE_FILE for CAS compare: $(cat "$CAS_ERR")" >&2
    exit 4
  fi

  if [[ "$CAS_COMPARE_RESULT" != "match" ]]; then
    # CAS mismatch — exit 7 so callers can distinguish a lost race from an
    # I/O or locking failure. State file is left unmodified.
    exit 7
  fi

  # Match: apply the write (same pipeline as --set).
  CAS_LAST_UPDATED="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  CAS_WRITE_ARGS=(--argjson __pathmap "$CAS_PATHMAP" --arg __unknown "$UNKNOWN_REPO_KEY"
                  --arg __last_updated "$CAS_LAST_UPDATED")
  if jq -n --argjson __casnew "$CAS_VALUE" 'empty' >/dev/null 2>&1; then
    CAS_WRITE_ARGS+=(--argjson __casnew "$CAS_VALUE")
  else
    CAS_WRITE_ARGS+=(--arg __casnew "$CAS_VALUE")
  fi

  CAS_JQ_FILTER="$MIGRATE_JQ migrate(\$__pathmap; \$__unknown) | $SCOPED_CAS_PATH = \$__casnew | .last_updated = \$__last_updated"
  if ! jq "${CAS_WRITE_ARGS[@]}" "$CAS_JQ_FILTER" "$input_file" > "$CAS_OUT_TMP" 2>"$CAS_ERR"; then
    echo "session-state.sh: jq failed writing $STATE_FILE: $(cat "$CAS_ERR")" >&2
    exit 5
  fi

  # Enforce the field-type contract against the candidate document, before the
  # stolen-lock guard and the mv below, so a rejected write leaves $STATE_FILE
  # untouched — same position in the pipeline as --set (issue #1283). Called
  # as a plain statement so it exits 4 directly.
  enforce_field_type_contract "$CAS_OUT_TMP"

  # Lock integrity — same stolen-lock guard as --set (issue #930).
  if ! state_lock_assert_held; then
    _n="${CLAUDE_STATE_RMW_RETRY:-0}"; _max="${CLAUDE_STATE_RMW_MAX_RETRY:-8}"
    if (( _n < _max )); then
      export CLAUDE_STATE_RMW_RETRY=$(( _n + 1 ))
      state_lock_release
      rm -f "$CAS_OUT_TMP" "$CAS_ERR" ${SEEDED_TMP:+"$SEEDED_TMP"} 2>/dev/null || true
      trap - EXIT
      sleep "0.0$(( (RANDOM % 8) + 1 ))"
      exec bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
    echo "session-state.sh: lock was broken by another writer $_max times running; giving up with $STATE_FILE unchanged (retry)" >&2
    exit "$STATE_LOCK_EXIT_TIMEOUT"
  fi

  if ! mv "$CAS_OUT_TMP" "$STATE_FILE" 2>/dev/null; then
    echo "session-state.sh: could not write $STATE_FILE" >&2
    exit 5
  fi

  exit 0
fi

# ============================================================================
# --set
# ============================================================================
if [[ "${#SET_PATHS[@]}" -eq 0 ]]; then
  die_usage "--set requires at least one <jq-path>=<value>"
fi

if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  echo "session-state.sh: could not create state dir: $STATE_DIR" >&2
  exit 5
fi

# Serialize the WHOLE read-modify-write cycle (issue #639) — acquired BEFORE
# the file is read below and held until this process exits, so a concurrent
# writer cannot slip a write in between our read and our mv. Exits 6 (a code
# distinct from every other failure) rather than writing unserialized.
state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"

# Build the input file: existing state if present + valid; seeded `{}` otherwise.
# Require a single top-level JSON object — see is_single_object_state_file().
# Every assignment in the pipeline indexes the root with a string key, so
# arrays/scalars/null would parse fine but fail downstream with confusing
# "Cannot index <type> with string" errors; multi-document files would write
# back N modified objects, corrupting the state file.
SEEDED_TMP=""
input_file="$STATE_FILE"
if [[ ! -f "$STATE_FILE" ]]; then
  SEEDED_TMP="$(mktemp)"
  printf '%s\n' '{}' > "$SEEDED_TMP"
  input_file="$SEEDED_TMP"
elif ! is_single_object_state_file "$STATE_FILE"; then
  echo "session-state.sh: $STATE_FILE must contain exactly one top-level JSON object; refusing to overwrite" >&2
  exit 4
fi

OUT_TMP="$STATE_FILE.tmp.$$"
JQ_ERR="$(mktemp)"
# shellcheck disable=SC2064
# Re-installing an EXIT trap replaces the one state_lock_acquire set, so the
# lock release is chained in explicitly here — otherwise an early exit below
# would leak the lock until it aged out as stale.
trap "state_lock_release; rm -f '$OUT_TMP' '$JQ_ERR' ${SEEDED_TMP:+'$SEEDED_TMP'} 2>/dev/null" EXIT

# Build the jq pipeline. Each --set becomes one assignment in the pipeline,
# bound to a unique --argjson or --arg variable. The final stage refreshes
# `.last_updated`. All assignments + the timestamp run in a single jq
# invocation → single atomic write.
JQ_FILTER=""
JQ_ARGS=()
TOUCHED_KNOWN_FIELDS=""
TOUCHED_NESTED_CHECKS=""
WHOLE_ENTRY_PRS=""
for i in "${!SET_PATHS[@]}"; do
  # Two views of the same write (issues #638 + #640):
  #   orig_path — what the caller asked for, e.g. `.prs["287"].babysit`
  #   path      — where it actually lands, e.g. `.repos["org/x"].prs["287"].babysit`
  # The assignment and the TOP-LEVEL type check use `path`, because that is
  # the shape of the final document. The per-PR classification helpers below
  # use `orig_path`: they match on a leading `.prs`, and handing them the
  # scoped path would make every lookup return empty — silently disabling
  # #640's nested guard the moment #638 moved the data. Their concrete jq
  # check paths are scoped back at the point of use.
  orig_path="${SET_PATHS[$i]}"
  path="$(scope_path "$orig_path")"
  value="${SET_VALUES[$i]}"
  varname="v$i"
  # Try to parse as JSON; fall back to string. Probe with `--argjson` itself —
  # the exact operation the JSON branch performs — so the probe can never accept
  # a value the write then rejects.
  #
  # NOT `jq -e .`: `-e` exits non-zero on null/false even when parse succeeds, so
  # legitimate JSON values null and false would be silently coerced to the strings
  # "null" and "false" ("false" being truthy in jq — issue #853).
  #
  # NOT `jq empty`: it accepts zero-value stdin — empty AND whitespace-only
  # ("", " ", "\t") — while `--argjson` rejects all three, so those values would
  # pass the probe and then hard-fail the write instead of storing as strings.
  if jq -n --argjson "$varname" "$value" 'empty' >/dev/null 2>&1; then
    JQ_ARGS+=(--argjson "$varname" "$value")
  else
    JQ_ARGS+=(--arg "$varname" "$value")
  fi
  if [[ -z "$JQ_FILTER" ]]; then
    JQ_FILTER="$path = \$$varname"
  else
    JQ_FILTER="$JQ_FILTER | $path = \$$varname"
  fi
  # Track known-typed fields touched by this batch (deduped) for the
  # post-write field-type contract check below — see FIELD-TYPE CONTRACT.
  set_top_level_key="$(top_level_key_of "$path")"
  if [[ -n "$(known_field_type "$set_top_level_key")" ]]; then
    case " $TOUCHED_KNOWN_FIELDS " in
      *" $set_top_level_key "*) ;;
      *) TOUCHED_KNOWN_FIELDS="$TOUCHED_KNOWN_FIELDS $set_top_level_key" ;;
    esac
  fi
  # Same tracking for per-PR nested fields (issue #640): a touched path whose
  # top-level key is "prs" and whose immediate post-PR-number segment is a
  # known nested field (e.g. `.prs["287"].last_cron_action` or a deeper
  # subpath like `.prs["287"].babysit.active`) is recorded as a "<PR>:<key>"
  # pair so the post-write loop below can check that specific PR entry's
  # field, not every PR in the file.
  set_nested_key="$(pr_nested_key_of "$orig_path")"
  if [[ -n "$set_nested_key" ]] && [[ -n "$(known_nested_field_type "$set_nested_key")" ]]; then
    set_pr_number="$(pr_number_of "$orig_path")"
    # PR numbers are always plain digits (GitHub PR numbers). Requiring that
    # shape here — before $set_pr_number gets interpolated into the jq
    # filter string built for nested_check_path below — keeps that
    # interpolation injection-safe without needing full jq-string escaping.
    if [[ "$set_pr_number" =~ ^[0-9]+$ ]]; then
      nested_pair="${set_pr_number}:${set_nested_key}"
      case " $TOUCHED_NESTED_CHECKS " in
        *" $nested_pair "*) ;;
        *) TOUCHED_NESTED_CHECKS="$TOUCHED_NESTED_CHECKS $nested_pair" ;;
      esac
    fi
  fi
  # Track whole-PR-entry writes (issue #640, CodeAnt finding on PR #654):
  # `--set '.prs["999"]={...}'` replaces the entire entry in one shot, so no
  # single nested-field path is touched above — but the embedded object can
  # still carry a malformed known field. Record the PR number so the
  # post-write loop below can scan every known nested key in that entry.
  set_whole_entry_pr="$(pr_whole_entry_write_number_of "$orig_path")"
  if [[ "$set_whole_entry_pr" =~ ^[0-9]+$ ]]; then
    case " $WHOLE_ENTRY_PRS " in
      *" $set_whole_entry_pr "*) ;;
      *) WHOLE_ENTRY_PRS="$WHOLE_ENTRY_PRS $set_whole_entry_pr" ;;
    esac
  fi
done

# Append the .last_updated refresh — done in jq (not bash) so it shares the
# atomic write. Use UTC ISO 8601 to match `(now | todate)` semantics in
# greptile-budget.sh / reviewer-of.sh; jq's `now | todate` would also work
# but emitting from bash keeps the path injection-free.
LAST_UPDATED="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
JQ_ARGS+=(--arg __last_updated "$LAST_UPDATED")
JQ_FILTER="$JQ_FILTER | .last_updated = \$__last_updated"

# Migrate first, in the same atomic write (issue #638). A write through this
# helper is therefore what permanently heals a legacy flat file — the scoped
# assignments above then land alongside the migrated entries rather than
# racing them.
warn_if_unmigratable "$input_file"
SET_PATHMAP="$(migrate_jq_args "$input_file")"
JQ_ARGS+=(--argjson __pathmap "$SET_PATHMAP" --arg __unknown "$UNKNOWN_REPO_KEY")
JQ_FILTER="$MIGRATE_JQ migrate(\$__pathmap; \$__unknown) | $JQ_FILTER"

if ! jq "${JQ_ARGS[@]}" "$JQ_FILTER" "$input_file" > "$OUT_TMP" 2>"$JQ_ERR"; then
  # Write-stage pipeline failure → exit 5 per the contract documented in the
  # EXIT STATUS block above. (Exit 4 is reserved for read-stage parse errors.)
  echo "session-state.sh: jq failed updating $STATE_FILE: $(cat "$JQ_ERR")" >&2
  exit 5
fi

# Enforce the field-type contract against the candidate document before the
# atomic mv below, so a rejected batch leaves $STATE_FILE untouched. Shared
# with --cas (issue #1283) — see enforce_field_type_contract() above for the
# individual checks. Called as a plain statement so it exits 4 directly.
enforce_field_type_contract "$OUT_TMP"

# Fail closed if the lock was broken and re-taken while we were reading and
# transforming: $OUT_TMP was computed from a snapshot another writer has since
# replaced, so committing it would silently discard their update (issue #930).
# Placed immediately before the commit — everything after this check is
# unprotected. Rather than fail outright, redo the whole read-modify-write
# against the current file; re-exec is the cheapest correct reset, and the
# retry budget keeps a persistently-stolen lock from spinning forever.
if ! state_lock_assert_held; then
  _n="${CLAUDE_STATE_RMW_RETRY:-0}"; _max="${CLAUDE_STATE_RMW_MAX_RETRY:-8}"
  if (( _n < _max )); then
    export CLAUDE_STATE_RMW_RETRY=$(( _n + 1 ))
    state_lock_release
    rm -f "$OUT_TMP" "$JQ_ERR" ${SEEDED_TMP:+"$SEEDED_TMP"} 2>/dev/null || true
    trap - EXIT
    # Stagger the retries so contending writers do not re-collide in lockstep.
    sleep "0.0$(( (RANDOM % 8) + 1 ))"
    exec bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  echo "session-state.sh: lock was broken by another writer $_max times running; giving up with $STATE_FILE unchanged (retry)" >&2
  exit "$STATE_LOCK_EXIT_TIMEOUT"
fi

if ! mv "$OUT_TMP" "$STATE_FILE" 2>/dev/null; then
  echo "session-state.sh: could not write $STATE_FILE" >&2
  exit 5
fi

exit 0
