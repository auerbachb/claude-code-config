#!/usr/bin/env bash
# session-state-audit.sh — audit + guarded repair for ~/.claude/session-state.json
# (issue #651).
#
# PURPOSE
#   The orchestration state file accumulates damage that no single writer owns:
#   entries the #638 migration could not attribute to a repo, values whose type
#   drifted before the #625/#640 contract existed, and PR entries for work that
#   merged months ago. Three separate `/wrap` sweeps flagged the file before
#   anyone looked at it as a whole. This script is that pass, made repeatable —
#   it DETECTS drift (default, read-only) and, only when asked, performs a
#   backup-guarded atomic REPAIR (--apply).
#
#   It is the session-state sibling of memory-audit.py (`/memory-clean`) and
#   follows the same shape: dry-run by default, confidence-tiered findings,
#   explicit opt-in per repair category, integrity re-check after every write.
#
# WHY `_unknown` IS THE HEADLINE FINDING
#   Issue #638 scoped PR state per repo (`.repos["<owner>/<name>"].prs["<N>"]`)
#   so two repos that both reach PR #84 stop overwriting each other. Its
#   migration attributes each legacy entry by its own `owner_repo`, falling back
#   to the repo identity of its recorded `root_repo` checkout. Legacy entries
#   mostly carry NEITHER — `owner_repo` predates none of them and `root_repo`
#   typically names a worktree that has since been removed — so they land in the
#   reserved `_unknown` bucket. That is the migration behaving as designed (state
#   is preserved, never dropped), but the consequence is easy to miss: `_unknown`
#   is deliberately merged into EVERY repo's candidate list by infer-pr.sh and
#   pr-state.sh --infer-candidates, so for those entries the cross-repo collision
#   #638 exists to prevent is still present. Scoping is not retroactive; this
#   script is how it gets applied to state that predates it.
#
# HOW AN `_unknown` ENTRY IS ATTRIBUTED (--reattribute)
#   By commit SHA, which is globally unique and verifiable — never by PR number,
#   which is exactly the ambiguous key that caused the original collision. For
#   each `_unknown` entry the script collects its recorded SHAs (`head_sha`,
#   `preflight_trigger_head_sha`) and asks each candidate repo whether that
#   commit exists (`gh api repos/<owner>/<name>/commits/<sha>`). Candidate repos
#   are the real (`owner/name`) scopes already present in the state file.
#
#     • exactly one repo has the commit  -> attributed, entry MOVED to that scope
#     • zero repos, or two or more       -> left in `_unknown` and reported
#     • no SHA recorded at all           -> left in `_unknown` and reported
#
#   A move MERGES into any entry already at the destination, with the
#   destination's fields winning — same conflict rule as #638's own migration,
#   for the same reason: attributed state is newer than the unattributed state
#   it supersedes.
#
# HOW A STALE ENTRY IS CHOSEN (--prune)
#   An entry is a prune candidate when its PR is merged or closed and has been
#   for at least the retention window (default 30 days, --retention-days). PR
#   status is read once per repo via `gh pr list --state all`.
#
#   Retention alone is NOT sufficient. Old entries carry `wrap_sweep` notes, and
#   `needs_decision` items in them are unactioned follow-ups — questions a
#   session asked that nobody has answered yet. Deleting those silently loses
#   work, so an otherwise-prunable entry holding a non-empty `needs_decision`
#   list is WITHHELD, reported under its own heading with the notes printed, and
#   pruned only if the caller passes --prune-with-notes having read them. This is
#   the "check before deleting rather than pruning blind" rule from issue #651.
#
# MODES
#   --check        Read-only detection (DEFAULT). Never writes. Exit 0 when the
#                  file is clean, 2 when there are findings.
#   --apply        Perform repairs. Does nothing on its own — combine with at
#                  least one of --reattribute / --prune / --heal-types.
#
# REPAIR FLAGS (each is opt-in; --apply with none of them is a usage error)
#   --reattribute       Move confidently attributed `_unknown` entries into
#                       their real repo scope.
#   --prune             Delete stale entries that carry no unactioned sweep
#                       notes.
#   --prune-with-notes  Widen --prune to include withheld entries whose sweep
#                       notes you have read. Requires --prune.
#   --heal-types        Reset fields violating the field-type contract to the
#                       contract's empty value (`[]` / `{}`). Number-typed
#                       fields are never guessed — they are reported only.
#
# OTHER FLAGS
#   --json                Machine-readable output instead of human text.
#   --retention-days <N>  Staleness window for --prune (default 30).
#   --offline             Skip every `gh` call. Attribution and staleness both
#                         need the network, so this narrows the run to the
#                         type-contract checks and the scope census.
#   --state-file <path>   Audit a file other than ~/.claude/session-state.json
#                         (tests; also lets you dry-run against a copy).
#   --help | -h
#
# BACKUPS
#   Every --apply run snapshots the state file to
#   `<state-file>.bak.<UTC timestamp>` before touching it, adding `.N` rather
#   than overwriting an existing snapshot (the never-clobber scheme from
#   skill-usage-merge.sh). The backup path is printed on stdout and, on --json,
#   returned as `.backup`. Restore is a plain `cp` back.
#
# SAFETY
#   - The whole read-modify-write runs under the shared state lock
#     (state-lock.sh), so a concurrent `/wrap` or polling tick cannot lose its
#     write to this one, or vice versa (issue #639).
#   - The new document is written to a temp file and moved into place atomically;
#     a failure at any stage leaves the original untouched.
#   - Before the move, the result is re-validated: it must be a single JSON
#     object, must still hold every PR entry that was not explicitly targeted,
#     and must introduce no NEW type-contract violation. Any failure aborts the
#     write and leaves the state file (and the backup) intact.
#   - Detection never writes, so `--check` is safe to run at any time, including
#     from a session that is actively polling.
#
# EXIT STATUS
#   0  Clean (--check found nothing) or repairs applied successfully.
#   2  Findings present (--check) — advisory, not an error.
#   3  Usage error.
#   4  Environment/IO error: missing jq, unreadable or malformed state file,
#      failed write, or a post-write integrity check that did not hold.
#   6  Could not acquire the state lock (propagated from state-lock.sh).
#
# DEPENDENCIES
#   jq; .claude/scripts/state-lock.sh; .claude/reference/session-state-schema.json
#   (the field-type contract — same single source of truth session-state.sh
#   reads, so the two can never disagree); `gh` unless --offline.
#
# EXAMPLES
#   # What is wrong with the live file?
#   session-state-audit.sh
#
#   # Same, as JSON:
#   session-state-audit.sh --json | jq '.summary'
#
#   # Fix the scoping the #638 migration could not, and heal type drift:
#   session-state-audit.sh --apply --reattribute --heal-types
#
#   # Prune entries merged 60+ days ago, keeping any with unread sweep notes:
#   session-state-audit.sh --apply --prune --retention-days 60

set -uo pipefail
{ printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"; } 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="${SCRIPT_DIR}/../reference/session-state-schema.json"
STATE_FILE="${HOME}/.claude/session-state.json"
UNKNOWN_REPO_KEY="_unknown"

EXIT_FINDINGS=2
EXIT_USAGE=3
EXIT_ERROR=4

MODE="check"
WANT_REATTRIBUTE=0
WANT_PRUNE=0
WANT_PRUNE_WITH_NOTES=0
WANT_HEAL_TYPES=0
AS_JSON=0
OFFLINE=0
RETENTION_DAYS=30

print_help() { sed -n '/^# PURPOSE$/,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }
die_usage() { echo "session-state-audit.sh: $1" >&2; echo "Run with --help for usage." >&2; exit "$EXIT_USAGE"; }
die_error() { echo "session-state-audit.sh: $1" >&2; exit "$EXIT_ERROR"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --check) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --reattribute) WANT_REATTRIBUTE=1; shift ;;
    --prune) WANT_PRUNE=1; shift ;;
    --prune-with-notes) WANT_PRUNE_WITH_NOTES=1; shift ;;
    --heal-types) WANT_HEAL_TYPES=1; shift ;;
    --json) AS_JSON=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --retention-days)
      [[ $# -ge 2 ]] || die_usage "--retention-days requires a value"
      [[ "$2" =~ ^[0-9]+$ ]] || die_usage "--retention-days must be a non-negative integer, got: $2"
      RETENTION_DAYS="$2"; shift 2 ;;
    --state-file)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--state-file requires a path"
      STATE_FILE="$2"; shift 2 ;;
    -*) die_usage "unknown flag: $1" ;;
    *) die_usage "unexpected positional argument: $1" ;;
  esac
done

if [[ "$MODE" == "apply" && "$WANT_REATTRIBUTE$WANT_PRUNE$WANT_HEAL_TYPES" == "000" ]]; then
  die_usage "--apply needs at least one of --reattribute, --prune, --heal-types"
fi
if [[ "$WANT_PRUNE_WITH_NOTES" == "1" && "$WANT_PRUNE" == "0" ]]; then
  die_usage "--prune-with-notes requires --prune"
fi

command -v jq >/dev/null 2>&1 || die_error "'jq' not found on PATH"
[[ -f "$STATE_FILE" ]] || die_error "state file not found: $STATE_FILE"
jq -s -e 'length == 1 and (.[0] | type == "object")' "$STATE_FILE" >/dev/null 2>&1 \
  || die_error "$STATE_FILE must contain exactly one top-level JSON object"

if [[ "$OFFLINE" == "0" ]] && ! command -v gh >/dev/null 2>&1; then
  echo "session-state-audit.sh: 'gh' not found on PATH — continuing as if --offline (attribution and staleness are skipped)" >&2
  OFFLINE=1
fi

# --- field-type contract (same source of truth as session-state.sh) ---------
FIELD_TYPES_TOP="{}"
FIELD_TYPES_NESTED="{}"
if [[ -f "$SCHEMA_FILE" ]]; then
  FIELD_TYPES_TOP="$(jq -c '._field_types.top_level // {}' "$SCHEMA_FILE" 2>/dev/null || echo '{}')"
  FIELD_TYPES_NESTED="$(jq -c '._field_types.pr_nested // {}' "$SCHEMA_FILE" 2>/dev/null || echo '{}')"
else
  echo "session-state-audit.sh: warning: field-type contract not found at $SCHEMA_FILE — type checks disabled for this run" >&2
fi

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

# Census of every scope and the type-contract violations, in one jq pass.
# `pr_nested` keys are checked wherever they appear directly under a PR entry.
detect_static() {
  jq -c --argjson top "$FIELD_TYPES_TOP" \
        --argjson nested "$FIELD_TYPES_NESTED" \
        --arg unknown "$UNKNOWN_REPO_KEY" '
    . as $doc
    | {
        scopes: (
          ($doc.repos // {}) | to_entries
          | map({ repo: .key,
                  pr_count: ((.value.prs // {}) | length),
                  attributed: (.key != $unknown) })
        ),
        type_violations: (
          [ ($top | to_entries[]
             | select($doc[.key] != null and ($doc[.key] | type) != .value)
             | { path: ".\(.key)", found: ($doc[.key] | type), want: .value, scope: null, pr: null }) ]
          + [ ($doc.repos // {}) | to_entries[] as $r
              | select(($r.value | type) == "object")
              | ($r.value.prs // {}) | to_entries[] as $p
              | ($nested | to_entries[])
              | select($p.value[.key] != null and ($p.value[.key] | type) != .value)
              | { path: ".repos[\"\($r.key)\"].prs[\"\($p.key)\"].\(.key)",
                  found: ($p.value[.key] | type), want: .value,
                  scope: $r.key, pr: $p.key } ]
          + [ ($doc.repos // {}) | to_entries[]
              | select((.value | type) != "object")
              | { path: ".repos[\"\(.key)\"]", found: (.value | type), want: "object",
                  scope: .key, pr: null } ]
        ),
        legacy_keys: (
          [ (if $doc.prs != null then "prs" else empty end),
            (if $doc.root_repo != null then "root_repo" else empty end) ]
        ),
        schema_version: ($doc.schema_version // null),
        total_prs: ( [ ($doc.repos // {})[] | (.prs // {}) | length ] | add // 0 )
      }' "$STATE_FILE"
}

STATIC="$(detect_static)" || die_error "could not analyze $STATE_FILE"

# Real (attributed) repo scopes are the candidate set for attribution and the
# repos whose PR status we look up.
# Read with a while-loop, not `mapfile`: macOS ships bash 3.2 as /bin/bash and
# `mapfile` is a bash 4 builtin, so it fails with "command not found" on the
# primary platform — the same reason session-state.sh avoids `declare -A`.
REAL_REPOS=()
while IFS= read -r _repo_key; do
  [[ -n "$_repo_key" ]] || continue
  REAL_REPOS+=("$_repo_key")
done < <(jq -r --arg u "$UNKNOWN_REPO_KEY" '(.repos // {}) | keys[] | select(. != $u)' "$STATE_FILE")

# Every `_unknown` entry with the SHAs that could identify it.
UNKNOWN_ENTRIES="$(jq -c --arg u "$UNKNOWN_REPO_KEY" '
  ((.repos[$u].prs // {}) | to_entries)
  | map({ pr: .key,
          shas: ( [ (.value.head_sha? // empty),
                    (.value.preflight_trigger_head_sha? // empty) ]
                  | map(select(type == "string" and (test("^[0-9a-f]{7,40}$")))) | unique ),
          has_notes: (((.value.wrap_sweep.needs_decision? // []) | length) > 0) })' "$STATE_FILE")"

# --- attribution (network) --------------------------------------------------
# One `gh api` call per (sha, repo) until a repo claims it. Memoized so repeated
# SHAs across entries cost nothing.
SHA_CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$SHA_CACHE_DIR" 2>/dev/null' EXIT

repo_has_commit() {
  local repo="$1" sha="$2"
  local cache="$SHA_CACHE_DIR/$(printf '%s' "${repo}_${sha}" | tr '/' '_')"
  if [[ -f "$cache" ]]; then
    [[ "$(cat "$cache")" == "yes" ]] && return 0 || return 1
  fi
  if gh api "repos/${repo}/commits/${sha}" --silent >/dev/null 2>&1; then
    printf 'yes' > "$cache"; return 0
  fi
  printf 'no' > "$cache"; return 1
}

ATTRIBUTIONS="[]"   # [{pr, repo, sha}]
UNATTRIBUTABLE="[]" # [{pr, reason, has_notes}]
if [[ "$OFFLINE" == "0" && "${#REAL_REPOS[@]:-0}" != "0" ]]; then
  while IFS=$'\x1f' read -r pr shas_json has_notes; do
    [[ -n "$pr" ]] || continue
    matched_repo=""
    matched_sha=""
    ambiguous=0
    while IFS= read -r sha; do
      [[ -n "$sha" ]] || continue
      for repo in ${REAL_REPOS[@]+"${REAL_REPOS[@]}"}; do
        if repo_has_commit "$repo" "$sha"; then
          if [[ -n "$matched_repo" && "$matched_repo" != "$repo" ]]; then
            ambiguous=1
          else
            matched_repo="$repo"; matched_sha="$sha"
          fi
        fi
      done
    done < <(jq -r '.[]' <<<"$shas_json")
    if [[ "$ambiguous" == "1" ]]; then
      UNATTRIBUTABLE="$(jq -c --arg p "$pr" --argjson n "$has_notes" \
        '. + [{pr: $p, reason: "ambiguous — recorded commits exist in more than one repo", has_notes: $n}]' <<<"$UNATTRIBUTABLE")"
    elif [[ -n "$matched_repo" ]]; then
      ATTRIBUTIONS="$(jq -c --arg p "$pr" --arg r "$matched_repo" --arg s "$matched_sha" \
        '. + [{pr: $p, repo: $r, sha: $s}]' <<<"$ATTRIBUTIONS")"
    else
      reason="no recorded commit SHA"
      [[ "$(jq -r 'length' <<<"$shas_json")" != "0" ]] && reason="recorded commits found in none of the known repos"
      UNATTRIBUTABLE="$(jq -c --arg p "$pr" --arg m "$reason" --argjson n "$has_notes" \
        '. + [{pr: $p, reason: $m, has_notes: $n}]' <<<"$UNATTRIBUTABLE")"
    fi
  # Joined on U+001F, not whitespace or a tab: `read` silently collapses an
  # empty field under a tab IFS and shifts every later field. All three fields
  # here are non-empty by construction (a PR key, a JSON array, a JSON boolean),
  # and the unit separator keeps it that way rather than relying on luck.
  done < <(jq -r '.[] | [.pr, (.shas | tojson), (.has_notes | tojson)] | join("\u001f")' <<<"$UNKNOWN_ENTRIES")
fi

# --- staleness (network) ----------------------------------------------------
# One `gh pr list --state all` per attributed repo, then join by PR number.
# Only attributed scopes are considered: an `_unknown` entry has no repo to ask,
# and pruning it on a PR-number guess is precisely the collision this all exists
# to avoid.
STALE="[]"   # [{scope, pr, state, closed_at, has_notes, notes}]
if [[ "$OFFLINE" == "0" ]]; then
  CUTOFF_EPOCH=$(( $(date -u +%s) - RETENTION_DAYS * 86400 ))
  for repo in ${REAL_REPOS[@]+"${REAL_REPOS[@]}"}; do
    prlist="$(gh pr list --repo "$repo" --state all --limit 300 \
                --json number,state,closedAt 2>/dev/null || echo '[]')"
    [[ -n "$prlist" ]] || prlist='[]'
    STALE="$(jq -c \
      --arg scope "$repo" \
      --argjson prlist "$prlist" \
      --argjson cutoff "$CUTOFF_EPOCH" \
      --slurpfile doc "$STATE_FILE" \
      '
      ( $prlist | map({ (.number | tostring): . }) | add // {} ) as $bynum
      | . + [ ($doc[0].repos[$scope].prs // {}) | to_entries[]
              | .key as $pr | .value as $entry
              | ($bynum[$pr] // null) as $gh
              | select($gh != null and ($gh.state == "MERGED" or $gh.state == "CLOSED"))
              | select(($gh.closedAt // null) != null)
              | select(($gh.closedAt | fromdateiso8601) < $cutoff)
              | { scope: $scope, pr: $pr, state: $gh.state, closed_at: $gh.closedAt,
                  has_notes: ((($entry.wrap_sweep.needs_decision? // []) | length) > 0),
                  notes: ($entry.wrap_sweep.needs_decision? // []) } ]' <<<"$STALE")"
  done
fi

# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------
FINDINGS="$(jq -c -n \
  --argjson static "$STATIC" \
  --argjson attributions "$ATTRIBUTIONS" \
  --argjson unattributable "$UNATTRIBUTABLE" \
  --argjson stale "$STALE" \
  --argjson offline "$OFFLINE" \
  --argjson retention "$RETENTION_DAYS" \
  --arg state_file "$STATE_FILE" '
  {
    state_file: $state_file,
    offline: ($offline == 1),
    retention_days: $retention,
    schema_version: $static.schema_version,
    scopes: $static.scopes,
    legacy_keys: $static.legacy_keys,
    type_violations: $static.type_violations,
    reattributable: $attributions,
    unattributable: $unattributable,
    stale_prunable: ($stale | map(select(.has_notes == false))),
    stale_withheld: ($stale | map(select(.has_notes == true))),
    summary: {
      total_prs: $static.total_prs,
      unattributed_prs: (($static.scopes | map(select(.attributed == false) | .pr_count) | add) // 0),
      type_violations: ($static.type_violations | length),
      reattributable: ($attributions | length),
      unattributable: ($unattributable | length),
      stale_prunable: ($stale | map(select(.has_notes == false)) | length),
      stale_withheld: ($stale | map(select(.has_notes == true)) | length)
    }
  }')"

render_text() {
  jq -r '
    "session-state audit — \(.state_file)",
    "  schema_version: \(.schema_version // "unset")   total PR entries: \(.summary.total_prs)" +
      (if .offline then "   [offline: attribution + staleness skipped]" else "" end),
    "",
    "Scopes:",
    ( .scopes[] | "  \(if .attributed then "  " else "! " end)\(.repo): \(.pr_count) PR entries" ),
    "",
    ( if (.legacy_keys | length) > 0
      then "Legacy top-level keys still present: \(.legacy_keys | join(", ")) — run session-state.sh --migrate\n"
      else empty end ),
    "Field-type contract: " +
      (if (.summary.type_violations == 0) then "clean"
       else "\(.summary.type_violations) violation(s)" end),
    ( .type_violations[] | "  ! \(.path): is \(.found), must be \(.want)" ),
    "",
    "Unattributed (`_unknown`) entries: \(.summary.unattributed_prs)",
    ( if .summary.reattributable > 0
      then "  attributable by commit SHA (--reattribute): \(.summary.reattributable)" else empty end ),
    ( .reattributable[] | "    PR #\(.pr) -> \(.repo)  (commit \(.sha[0:12]))" ),
    ( if .summary.unattributable > 0
      then "  not attributable: \(.summary.unattributable)" else empty end ),
    ( .unattributable[] | "    PR #\(.pr): \(.reason)\(if .has_notes then " [has unactioned sweep notes]" else "" end)" ),
    "",
    "Stale entries (merged/closed \(.retention_days)+ days ago):",
    "  prunable now (--prune): \(.summary.stale_prunable)",
    ( .stale_prunable[] | "    \(.scope) PR #\(.pr) — \(.state) \(.closed_at)" ),
    "  withheld, unactioned sweep notes (read these, then --prune-with-notes): \(.summary.stale_withheld)",
    ( .stale_withheld[] | "    \(.scope) PR #\(.pr) — \(.state) \(.closed_at)",
      ( .notes[] | "        · \(.)" ) )
  ' <<<"$FINDINGS"
}

has_findings() {
  jq -e '.summary
    | (.unattributed_prs > 0) or (.type_violations > 0)
      or (.stale_prunable > 0) or (.stale_withheld > 0)' <<<"$FINDINGS" >/dev/null 2>&1
}

if [[ "$MODE" == "check" ]]; then
  if [[ "$AS_JSON" == "1" ]]; then jq . <<<"$FINDINGS"; else render_text; fi
  has_findings && exit "$EXIT_FINDINGS"
  exit 0
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
[[ -f "$SCRIPT_DIR/state-lock.sh" && -r "$SCRIPT_DIR/state-lock.sh" ]] \
  || die_error "missing sibling library: $SCRIPT_DIR/state-lock.sh"
# shellcheck source=./state-lock.sh
source "$SCRIPT_DIR/state-lock.sh" || die_error "failed to load $SCRIPT_DIR/state-lock.sh"

state_lock_acquire "$STATE_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"

# Backup first, never overwriting an existing snapshot.
BACKUP="${STATE_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -e "$BACKUP" ]]; then
  n=1
  while [[ -e "${BACKUP}.${n}" ]]; do n=$((n + 1)); done
  BACKUP="${BACKUP}.${n}"
fi
cp "$STATE_FILE" "$BACKUP" || die_error "could not write backup: $BACKUP"

OUT_TMP="${STATE_FILE}.audit.tmp.$$"
JQ_ERR="$(mktemp)"
# shellcheck disable=SC2064
trap "state_lock_release; rm -rf '$SHA_CACHE_DIR' 2>/dev/null; rm -f '$OUT_TMP' '$JQ_ERR' 2>/dev/null" EXIT

# PR keys deliberately targeted by this run — the integrity check below allows
# these to disappear and nothing else.
PRUNE_SET="$(jq -c --argjson with_notes "$WANT_PRUNE_WITH_NOTES" --argjson want "$WANT_PRUNE" '
  if $want == 0 then []
  else (.stale_prunable + (if $with_notes == 1 then .stale_withheld else [] end))
       | map({scope: .scope, pr: .pr})
  end' <<<"$FINDINGS")"
MOVE_SET="$(jq -c --argjson want "$WANT_REATTRIBUTE" '
  if $want == 0 then [] else (.reattributable | map({pr: .pr, repo: .repo})) end' <<<"$FINDINGS")"
HEAL_SET="$(jq -c --argjson want "$WANT_HEAL_TYPES" '
  if $want == 0 then []
  else (.type_violations | map(select(.want == "array" or .want == "object"))) end' <<<"$FINDINGS")"

if ! jq \
    --argjson moves "$MOVE_SET" \
    --argjson prunes "$PRUNE_SET" \
    --argjson heals "$HEAL_SET" \
    --argjson top "$FIELD_TYPES_TOP" \
    --argjson nested "$FIELD_TYPES_NESTED" \
    --arg unknown "$UNKNOWN_REPO_KEY" '
    # 1. Re-attribute: move each entry out of `_unknown` into its real scope,
    #    merging with any entry already there (destination wins, matching the
    #    #638 migration'"'"'s own conflict rule).
    reduce $moves[] as $m (
      .;
      ( (.repos[$unknown].prs[$m.pr] // null) as $entry
        | if $entry == null then .
          else .repos[$m.repo] = ( (.repos[$m.repo] // {})
                | .prs = ( (.prs // {})
                    | .[$m.pr] = ($entry + (.[$m.pr] // {})) ) )
               | del(.repos[$unknown].prs[$m.pr])
          end )
    )
    # 2. Prune stale entries from their own scope.
    | reduce $prunes[] as $p ( .; del(.repos[$p.scope].prs[$p.pr]) )
    # 3. Heal type drift by resetting to the contract'"'"'s empty value. Only
    #    array/object fields are healed; a number field has no safe empty value
    #    to invent, so those stay reported-only.
    | reduce $heals[] as $h (
        .;
        ( (if $h.want == "array" then [] else {} end) as $empty
          | if $h.scope == null then .[($h.path | ltrimstr("."))] = $empty
            elif $h.pr == null then .repos[$h.scope] = $empty
            else .repos[$h.scope].prs[$h.pr][($h.path | split(".") | last)] = $empty
            end )
      )
    # 4. Drop an emptied `_unknown` scope entirely — an empty bucket is noise
    #    that every consumer would keep reading and merging for nothing.
    | ( if ((.repos[$unknown].prs // {}) | length) == 0
             and ((.repos[$unknown] // {}) | keys | map(select(. != "prs")) | length) == 0
        then del(.repos[$unknown]) else . end )
    | .last_updated = (now | todate)
    ' "$STATE_FILE" > "$OUT_TMP" 2>"$JQ_ERR"; then
  die_error "repair pipeline failed: $(cat "$JQ_ERR")"
fi

# --- integrity re-check (nothing is moved into place until all of this holds) -
jq -s -e 'length == 1 and (.[0] | type == "object")' "$OUT_TMP" >/dev/null 2>&1 \
  || die_error "repair produced a malformed document — $STATE_FILE left unmodified (backup: $BACKUP)"

# Every element is bound to $e before use: `index(f)` evaluates f against the
# ARRAY it is called on, not against the element being selected, so a bare
# `index(.pr)` here resolves `.pr` on $after_prs and dies with "Cannot index
# array with string". That error would print to stderr and leave $LOST empty —
# the check would pass by failing, which is why its exit status is trapped
# below rather than assumed.
LOST=""
if ! LOST="$(jq -r -n \
  --slurpfile before "$STATE_FILE" --slurpfile after "$OUT_TMP" \
  --argjson prunes "$PRUNE_SET" --arg unknown "$UNKNOWN_REPO_KEY" '
  def pairs($d): [ ($d.repos // {}) | to_entries[] as $r
                   | ($r.value.prs // {}) | keys[] | { scope: $r.key, pr: . } ];
  ( $prunes | map("\(.scope)#\(.pr)") ) as $expected_gone
  # A re-attributed entry legitimately changes scope, so identity for this
  # check is the PR key alone — it must still exist SOMEWHERE unless it was
  # explicitly pruned.
  | ( pairs($after[0]) | map(.pr) | unique ) as $after_prs
  | pairs($before[0])
  | map(. as $e
        | select( ($expected_gone | index("\($e.scope)#\($e.pr)")) == null
                  and ($after_prs | index($e.pr)) == null ))
  | map("\(.scope)#\(.pr)") | join(", ")' 2>"$JQ_ERR")"; then
  die_error "integrity check could not run: $(cat "$JQ_ERR") — $STATE_FILE left unmodified (backup: $BACKUP)"
fi
if [[ -n "$LOST" ]]; then
  die_error "repair would drop PR entries that were not targeted ($LOST) — $STATE_FILE left unmodified (backup: $BACKUP)"
fi

NEW_VIOLATIONS="$(jq -r --argjson top "$FIELD_TYPES_TOP" --argjson nested "$FIELD_TYPES_NESTED" '
  . as $doc
  | ( [ $top | to_entries[] | select($doc[.key] != null and ($doc[.key] | type) != .value) | ".\(.key)" ]
    + [ ($doc.repos // {}) | to_entries[] as $r
        | select(($r.value | type) == "object")
        | ($r.value.prs // {}) | to_entries[] as $p
        | ($nested | to_entries[])
        | select($p.value[.key] != null and ($p.value[.key] | type) != .value)
        | ".repos[\"\($r.key)\"].prs[\"\($p.key)\"].\(.key)" ] )
  | join(", ")' "$OUT_TMP")"
PRE_VIOLATION_COUNT="$(jq -r '.summary.type_violations' <<<"$FINDINGS")"
POST_VIOLATION_COUNT=0
[[ -n "$NEW_VIOLATIONS" ]] && POST_VIOLATION_COUNT="$(awk -F', ' '{print NF}' <<<"$NEW_VIOLATIONS")"
if (( POST_VIOLATION_COUNT > PRE_VIOLATION_COUNT )); then
  die_error "repair introduced new type-contract violations ($NEW_VIOLATIONS) — $STATE_FILE left unmodified (backup: $BACKUP)"
fi

mv "$OUT_TMP" "$STATE_FILE" || die_error "could not write $STATE_FILE (backup: $BACKUP)"

RESULT="$(jq -c -n \
  --argjson moves "$MOVE_SET" --argjson prunes "$PRUNE_SET" --argjson heals "$HEAL_SET" \
  --arg backup "$BACKUP" --arg state_file "$STATE_FILE" \
  --argjson remaining "$POST_VIOLATION_COUNT" '
  { state_file: $state_file, backup: $backup,
    reattributed: $moves, pruned: $prunes, healed: ($heals | map(.path)),
    remaining_type_violations: $remaining,
    counts: { reattributed: ($moves | length), pruned: ($prunes | length), healed: ($heals | length) } }')"

if [[ "$AS_JSON" == "1" ]]; then
  jq . <<<"$RESULT"
else
  jq -r '
    "session-state repair applied — \(.state_file)",
    "  backup: \(.backup)",
    "  re-attributed: \(.counts.reattributed)",
    ( .reattributed[] | "    PR #\(.pr) -> \(.repo)" ),
    "  pruned: \(.counts.pruned)",
    ( .pruned[] | "    \(.scope) PR #\(.pr)" ),
    "  type fields healed: \(.counts.healed)",
    ( .healed[] | "    \(.)" ),
    "  remaining type violations: \(.remaining_type_violations)"
  ' <<<"$RESULT"
fi
exit 0
