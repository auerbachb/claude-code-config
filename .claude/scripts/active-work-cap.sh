#!/usr/bin/env bash
# active-work-cap.sh — repo-wide budget for simultaneously active coding work.
#
# PURPOSE
#   The 3-4 concurrent-pipeline ceiling in subagent-orchestration.md is a
#   PER-THREAD limit. Once work fans out across separate coding threads nothing
#   counted the total, and a chip emitter with no PM context had no in-flight
#   figure to gate on — so it offered one chip per issue with nothing to count
#   against. The 2026-08-18 session ended with ~20 threads on one repo.
#
#   This script is the SOLE OWNER of the cap's default and of the counting
#   rules. Rule and skill files describe the behavior ("offer at most FREE")
#   and never restate the number, so the default can be retuned in one place.
#
#   Derivation of the default — why 6 and not the originally proposed 8:
#   .claude/reference/active-work-cap.md. Short form: CodeRabbit Pro allows 5
#   reviews/hour/developer (the ~8 this repo modelled was retracted in #1204),
#   so past 5 concurrent PRs a PR cannot get one review round per hour AND
#   rebase re-review (k(k-1)/2, each force-push costing a review) overtakes
#   productive review. 6 is that limit plus one slot of operating headroom.
#
# USAGE
#   active-work-cap.sh [--json | --free | --cap] [--repo <owner/name>]
#                      [--path <dir>]
#   active-work-cap.sh --help | -h
#
# MODES
#   (default)  Print one plain line: `CAP=<n> ACTIVE=<n> FREE=<n>`.
#   --json     Print a single-line JSON object with the same figures plus the
#              per-source breakdown and how the cap was resolved.
#   --free     Print only FREE — the shell-consumable form for emitters that
#              just need "how many may I offer".
#   --cap      Print only CAP. Resolves the knob without counting anything, so
#              it makes no network call.
#
# FLAGS
#   --repo <owner/name>  Count open PRs in this repo instead of the one
#                        inferred from the working directory. Also used as the
#                        session-state repo scope.
#   --path <dir>         Resolve the repo root (and therefore pm-config.md)
#                        from this directory instead of the cwd. Portability
#                        per #1189: an orchestrator in one checkout can read a
#                        different repo's cap.
#
# THE COUNT
#   ACTIVE is the sum of three author-scoped, durable sources:
#     1. Open PRs you authored — `gh pr list --state open --author @me`.
#        Author-scoped per #732/#733; a collaborator's PR is never counted.
#     2. Live offered chips — the UNION of:
#          a. The chip offer registry (chip-offer-registry.sh --count), which
#             covers all emitters (/pm, /prompt, /wave, /issue-maker,
#             /start-issue). Entries in `offered` or `running` state are counted;
#             `pr-backed`, `done`, `retracted`, and `expired` are not.
#             chip-offer-registry.sh "Offer Registry" (chip-launching.md) is the
#             contract emitters follow to write here.
#          b. Legacy issue-maker chip logs — DISTINCT `chip_task_id`s among
#             the entries in ~/.claude/handoffs/issue-maker-*-log.json with
#             `status: "open"` and a non-null `chip_task_id` (chip-launching.md
#             "Cross-skill chip visibility"), TWICE narrowed (see CHIP LIVENESS
#             below). One chip is one offer however many issues it covers.
#             This legacy source is kept for backward compatibility while emitters
#             migrate to the registry. It is deduplicated against (a) by issue
#             number so the same offer is never counted twice.
#        Offered-but-unclicked chips COUNT: twenty offered chips invite twenty
#        clicks, which was the observed failure mode.
#     3. Running inline pipelines not yet at PR — `active_agents` entries with
#        no `.pr`, read through `session-state.sh --session-view` (which
#        already drops other repos' entries and keeps unattributable ones).
#
#   Sources 1 and 3 are disjoint by construction: an active_agents entry gains
#   a `.pr` the moment its pipeline opens a PR, at which point source 1 counts
#   it and source 3 stops.
#
#   Sources 1 and 2a: registry entries in `pr-backed` state are not counted here
#   because the same work is counted by source 1. The pr-backed lifecycle
#   transition replaces the explicit PR-subtraction used for legacy logs (2b).
#
#   Sources 1 and 2b need an explicit subtraction, because a chip's log entry is
#   NOT cleared when the chip is clicked. A clicked chip becomes a thread, then
#   a PR, while its issue stays open until that PR merges — so the same unit of
#   work would be counted twice and the effective cap halved. Entries whose
#   issue appears in an open PR's `closingIssuesReferences` are therefore
#   excluded. A multi-issue chip loses only the absorbed entries; it stops
#   counting once it loses all of them (CHIP LIVENESS, PARTIAL ABSORPTION).
#
#   Sources 2a and 2b need deduplication by issue number: an emitter that writes
#   to the registry AND the legacy log for the same offer must not count twice.
#
# CHIP LIVENESS — why the raw log query is not the count
#   chip-launching.md's discovery query answers "has this issue already been
#   offered a chip", which is a per-issue dedup question. It is NOT a count of
#   live work, for three reasons measured on real logs — the first two on
#   2026-08-21 (59 raw hits across 6 logs), the third on auerbachb/inventory
#   2026-08-22 (24 entries, one chip, ACTIVE reported as 24):
#
#     1. The logs are CROSS-REPO. One `issue-maker-*-log.json` per capture
#        thread, and those threads span every repo worked in — 34 entries for
#        claude-code-config, 19 for consulting-websites, 6 across three others.
#        A repo-wide cap that counted all of them would gate one repo on
#        another's backlog. Entries are attributed by their `url` field.
#
#     2. `chip_task_id` is cleared only on an explicit RETRACT. Clicking a
#        chip, finishing the work, and merging the PR all leave it set, and
#        chip-launching.md's own hygiene rules route cross-session chips to
#        manual UI dismissal rather than clearing them programmatically. The
#        raw count is therefore a monotonic high-water mark: it only grows, so
#        within days it would pin FREE at 0 and the gate would refuse
#        everything forever.
#
#     3. ENTRIES ARE NOT CHIPS. One chip can cover MANY issues: /issue-maker
#        offers one click-to-launch hand-off per capture session covering every
#        issue it filed (issue-maker/SKILL.md Step 9c), so an N-issue session
#        writes N entries all carrying ONE `chip_task_id`. Counting entries let
#        a single 24-issue offer fill a CAP=6 board four times over and pin FREE
#        at 0 on a repo with no open PRs and no running pipelines (#1247).
#
#   So an ENTRY counts only when its issue is STILL OPEN on GitHub — one
#   `gh issue list --state open` call for the target repo, intersected with the
#   log-derived numbers. A closed issue's entry is finished work, not pending
#   work. An entry whose `url` cannot be attributed to any repo is counted
#   anyway and warned about: over-counting narrows offers (safe), while
#   under-counting widens them (the failure this script exists to prevent).
#
#   And the ANSWER is a count of DISTINCT `chip_task_id`s among the entries that
#   survive that. The de-duplication happens AFTER both narrowings, never
#   before: an entry that is another repo's, whose issue has closed, or whose
#   issue an open PR already covers is dropped first, and only the survivors
#   name their chips. Applying it earlier would let one absorbed issue speak for
#   its whole chip and weaken both filters.
#
#   PARTIAL ABSORPTION — a chip whose issues are SOME absorbed and some not is
#   still one live offer, and counts 1. It drops to 0 only when EVERY issue it
#   covers has been absorbed (closed, or covered by an open PR). Clicking it
#   opens one thread, and while any of its issues is still open that thread has
#   real work to do; counting it 0 sooner would hand back a slot that is still
#   in use.
#
#   The older issue-level rule still binds alongside this one: an issue offered
#   by two capture sessions is one slot, not two, because the unit of work is
#   the issue. So each surviving issue names a single representative chip before
#   the distinct count, and the two rules compose to "one unit of work, one
#   slot" from either direction — N issues under one chip count 1, and one issue
#   under N chips also counts 1.
#
# TUNING
#   CLAUDE_ACTIVE_WORK_CAP  Override the cap. Must be an integer in
#                           [CAP_MIN, CAP_MAX]; anything else warns on stderr
#                           and falls back.
#   Resolution order: env override -> ACTIVE_WORK_CAP in the target repo's
#   .claude/pm-config.md (`## Active work`; the `active_work_cap: N` colon form
#   is also accepted) -> built-in default. An ABSENT value is normal and
#   silent; a PRESENT but unparseable or out-of-range value warns and falls
#   back, per the MAX_WAVE / CLAUDE_BGWORK_CEILING_S precedent.
#
#   CLAUDE_ACTIVE_WORK_AGENT_TTL_S  How long an `active_agents` entry may go
#                           unseen before it stops consuming a slot, in
#                           seconds (default 7200). These records say what was
#                           LAUNCHED, not what is alive, so a crashed session
#                           leaves one behind and an orphan would otherwise pin
#                           capacity forever. A non-integer warns and falls
#                           back. An entry carrying no timestamp at all is
#                           always kept — unknown age must not read as expired.
#
#   CLAUDE_ACTIVE_WORK_HANDOFF_DIR  Override the issue-maker chip-log
#                           directory so tests never read live state.
#
#   CLAUDE_CHIP_OFFER_REGISTRY_SH  Override the path to chip-offer-registry.sh.
#                           When set, that script is used to count registry chips.
#                           When absent the sibling chip-offer-registry.sh is used
#                           when it exists; if neither is found the registry source
#                           contributes 0 and a DEGRADED warning is printed.
#                           Set to empty string in tests that want no registry read.
#
# EMPTY IS NOT THE SAME AS FAILED
#   A source that legitimately has nothing contributes 0. A source that could
#   not be READ (gh failed, a chip log is malformed, session-state is corrupt)
#   exits 5 instead of contributing 0 — a fabricated zero reads as "nothing
#   active" and would silently uncap the gate
#   (feedback_fabricated_sentinel_stable_signature.md,
#   feedback_guard_must_fail_closed.md). jq stderr is left unredirected so a
#   malformed chip log is visible rather than looking like "no chips".
#
# OUTPUT
#   stdout: mode-dependent (plain line, JSON object, or a single integer).
#   stderr: one-line diagnostics — fallback warnings and read failures.
#
# EXIT STATUS
#   0  Success.
#   2  Usage error (unknown flag, missing flag value, conflicting modes).
#   5  A count source could not be read. Nothing is printed on stdout.

set -uo pipefail

CAP_DEFAULT=6
CAP_MIN=1
CAP_MAX=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
HANDOFF_DIR="${CLAUDE_ACTIVE_WORK_HANDOFF_DIR:-$HOME/.claude/handoffs}"

usage() {
  sed -n '2,/^$/p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

warn() { printf 'active-work-cap.sh: %s\n' "$1" >&2; }

die_usage() {
  warn "$1"
  printf 'Run with --help for usage.\n' >&2
  exit 2
}

die_read() {
  warn "$1"
  exit 5
}

MODE="plain"
REPO=""
FROM_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --json|--free|--cap)
      local_mode="${1#--}"
      if [[ "$MODE" != "plain" ]]; then
        die_usage "conflicting output modes (--$local_mode after --$MODE)"
      fi
      MODE="$local_mode"
      shift
      ;;
    --repo)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--repo requires a value"
      REPO="$2"; shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      [[ -n "$REPO" ]] || die_usage "--repo requires a value"
      shift
      ;;
    --path)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--path requires a value"
      FROM_PATH="$2"; shift 2
      ;;
    --path=*)
      FROM_PATH="${1#--path=}"
      [[ -n "$FROM_PATH" ]] || die_usage "--path requires a value"
      shift
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

if [[ -n "$REPO" && ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die_usage "--repo must look like owner/name (got: $REPO)"
fi

# ---------------------------------------------------------------- cap ------

# Extract ACTIVE_WORK_CAP from a pm-config `## Active work` body. Accepts both
# `ACTIVE_WORK_CAP=6` (the KEY=value convention) and `active_work_cap: 6` (the
# colon form the ticket used), case-insensitively, anchored at line start so
# the prose bullets that NAME the key are never mistaken for a value.
extract_cap_value() {
  awk '
    tolower($0) ~ /^[[:space:]]*active_work_cap[[:space:]]*[=:]/ {
      line = $0
      sub(/^[^=:]*[=:][[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      print line
      exit
    }
  '
}

resolve_cap() {
  local raw="${CLAUDE_ACTIVE_WORK_CAP:-}"
  local source="default"

  if [[ -n "$raw" ]]; then
    source="env"
  else
    local getter="$SCRIPT_DIR/pm-config-get.sh"
    local config=""
    if [[ -x "$getter" ]]; then
      local root=""
      if [[ -x "$SCRIPT_DIR/repo-root.sh" ]]; then
        root="$("$SCRIPT_DIR/repo-root.sh" ${FROM_PATH:+"$FROM_PATH"} 2>/dev/null)" || root=""
      fi
      [[ -n "$root" ]] && config="$root/.claude/pm-config.md"

      if [[ -n "$config" && -r "$config" ]]; then
        local body rc=0
        body="$("$getter" --section "Active work" --file "$config" 2>/dev/null)" || rc=$?
        # rc 1 = section absent / empty, rc 2 = file unreadable. Both are the
        # normal "this repo has not set a cap" case and stay silent. rc 3 is a
        # usage error, which is our bug, not the repo's.
        if [[ $rc -eq 3 ]]; then
          warn "pm-config-get.sh usage error while reading the cap; using default"
        elif [[ $rc -eq 0 ]]; then
          raw="$(printf '%s\n' "$body" | extract_cap_value)"
          [[ -n "$raw" ]] && source="config"
        fi
      fi
    fi
  fi

  if [[ -z "$raw" ]]; then
    printf '%s %s' "$CAP_DEFAULT" "default"
    return
  fi

  if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
    warn "ACTIVE_WORK_CAP ($source) is not a positive integer: '$raw' — using default $CAP_DEFAULT"
    printf '%s %s' "$CAP_DEFAULT" "default"
    return
  fi

  # Strip leading zeros so 10#$raw arithmetic never reads as octal.
  local n=$((10#$raw))
  if (( n < CAP_MIN || n > CAP_MAX )); then
    warn "ACTIVE_WORK_CAP ($source) = $n is outside [$CAP_MIN, $CAP_MAX] — using default $CAP_DEFAULT"
    printf '%s %s' "$CAP_DEFAULT" "default"
    return
  fi

  printf '%s %s' "$n" "$source"
}

read -r CAP CAP_SOURCE <<<"$(resolve_cap)"

if [[ "$MODE" == "cap" ]]; then
  printf '%s\n' "$CAP"
  exit 0
fi

# -------------------------------------------------------------- counts -----

# Fetched once and reused: the count of open PRs AND the issues they close.
# The second is what keeps a clicked chip from being counted twice — see
# fetch_open_prs / chips_covered_by_prs below.
OPEN_PR_JSON=""

# `--limit 100` cannot affect the answer, despite looking like the same
# truncation bug fixed in open_among. FREE is max(0, CAP - ACTIVE) and CAP_MAX
# is 10, so any repo with enough open PRs to hit the limit is already an order
# of magnitude past the cap and FREE is 0 whether the count reads 100 or 400.
# The closing-issue references share the fetch, and a truncated one there only
# subtracts fewer chips — the over-counting, safe direction.
fetch_open_prs() {
  local out rc=0
  out="$(gh pr list --state open --author "@me" --limit 100 \
         --json number,closingIssuesReferences ${REPO:+--repo "$REPO"} 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die_read "gh pr list (open, author=@me${REPO:+, repo=$REPO}) failed: $out"
  fi
  local probe rc2=0
  probe="$(printf '%s' "$out" | jq -e 'type == "array"' 2>&1)" || rc2=$?
  if [[ $rc2 -ne 0 ]]; then
    die_read "could not parse gh pr list output as a JSON array: $probe"
  fi
  OPEN_PR_JSON="$out"
}

count_open_prs() {
  local n rc=0
  n="$(printf '%s' "$OPEN_PR_JSON" | jq 'length' 2>&1)" || rc=$?
  if [[ $rc -ne 0 || ! "$n" =~ ^[0-9]+$ ]]; then
    die_read "could not count open PRs: $n"
  fi
  printf '%s' "$n"
}

# Issue numbers already represented by one of the open PRs counted above. A
# chip whose issue is here has been CLICKED and has become a PR, so counting
# the chip as well would count one unit of work twice and halve the effective
# cap. This is also `chip-launching.md`'s own stale-chip trigger 1 ("gained an
# open PR — someone is already doing the work"), so the chip is stale by that
# contract too; the count simply stops waiting for the hygiene sweep to run.
chips_covered_by_prs() {
  local out rc=0
  out="$(printf '%s' "$OPEN_PR_JSON" \
        | jq -r '.[] | (.closingIssuesReferences // [])[] | .number' 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die_read "could not read closing-issue references from open PRs: $out"
  fi
  printf '%s' "$out"
}

# Resolve the target repo slug once — the chip filter and the open-issue
# intersection both need it.
# --path must steer the COUNT as well as the cap. Resolving the cap from one
# checkout while `gh` counted PRs in whatever directory the caller happened to
# be in would report one repo's budget against another's activity.
resolve_repo_slug() {
  if [[ -n "$REPO" ]]; then
    printf '%s' "$REPO"
    return
  fi
  local out rc=0
  if [[ -n "$FROM_PATH" ]]; then
    out="$(cd "$FROM_PATH" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1)" || rc=$?
  else
    out="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1)" || rc=$?
  fi
  if [[ $rc -ne 0 || -z "$out" ]]; then
    die_read "could not resolve the target repo${FROM_PATH:+ from --path $FROM_PATH} (pass --repo owner/name): $out"
  fi
  # Same shape check the --repo flag gets. The capture above merges stderr, so
  # a gh notice printed alongside the slug would otherwise ride along into
  # `gh pr list --repo` and into the GraphQL query, where owner/name are
  # interpolated into the query string. That currently fails late and
  # confusingly rather than unsafely; validating here makes it fail at the
  # point the value goes wrong, and removes the asymmetry with --repo.
  if [[ ! "$out" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    die_read "resolved repo is not a plausible owner/name slug: '$out' (pass --repo owner/name)"
  fi
  printf '%s' "$out"
}

# Issue numbers with a live issue-maker chip, per chip-launching.md
# "Cross-skill chip visibility", narrowed to THIS repo. See CHIP LIVENESS in
# the header for why the raw query is not the count. A missing directory or no
# glob match is simply "no chips offered yet". A PRESENT but unparseable log is
# a hard failure — jq's stderr stays visible so it never looks like "no chips".
chip_issue_numbers() {
  local slug="$1" f
  local slug_lc
  slug_lc="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')"

  shopt -s nullglob
  local logs=("$HANDOFF_DIR"/issue-maker-*-log.json)
  shopt -u nullglob

  # `${logs[@]}` on an empty array is an unbound-variable error under `set -u`
  # in bash 3.2 (macOS). The +expansion guard yields nothing instead, so "no
  # chip logs yet" stays the silent, legitimate zero it should be.
  for f in ${logs[@]+"${logs[@]}"}; do
    [[ -f "$f" ]] || continue
    local out rc=0
    # The schema is checked BEFORE filtering, because `.issues[]?` swallows a
    # wrong shape rather than erroring: `{}`, `{"issues":null}`, and
    # `{"issues":"garbage"}` all yield zero rows at exit 0, which is
    # indistinguishable from a log that genuinely holds no chips. That is the
    # fabricated zero this script exists to avoid, so a log that is valid JSON
    # but not the expected shape is a hard failure, exactly like unparseable
    # JSON. `{"issues":[]}` — a real, empty log — still passes.
    #
    # Emit "<number> <repo-or-dash> <chip-token>" per live entry; attribution
    # happens in bash so an unparseable url is warned about rather than silently
    # dropped.
    #
    # The repo field is "-" rather than empty when there is no usable url: with
    # a third field on the line, `read -r num repo chip` under the default IFS
    # collapses the resulting double space, so an empty middle field would slide
    # the chip token into `repo` and leave `chip` unset. "-" cannot collide with
    # a real slug, which always contains a slash.
    #
    # The chip token is base64 so it is guaranteed one line and free of spaces
    # — it is only ever compared for equality, and base64 is injective, so
    # encoding cannot merge two distinct chips. A `chip_task_id` that
    # stringifies to empty gets a per-entry synthetic id instead of an empty
    # bucket that would silently merge every such entry into one chip
    # (feedback_fabricated_sentinel_stable_signature.md) — `to_entries` supplies
    # the index that makes it unique.
    out="$(jq -r --arg log "$f" '
      if type != "object" or (.issues | type) != "array" then
        error("not an issue-maker log: root must be an object with an issues array")
      else . end
      | .issues
      | to_entries[]
      | (.key | tostring) as $i
      | .value
      | select(.status == "open" and .chip_task_id != null)
      | (.chip_task_id | tostring) as $cid
      | (if ($cid | length) == 0 then "synthetic:\($log)#\($i)" else $cid end
         | @base64) as $tok
      # `capture` on a non-matching string yields `empty`, and `empty // {r:""}`
      # yields the fallback — so the alternative alone is sufficient here. The
      # `try` is belt-and-braces against jq versions that raise instead: without
      # it, one malformed url in a log would abort the whole count with exit 5
      # rather than taking the documented warn-and-over-count path.
      | ((.url // "") | (try capture("^https?://[^/]+/(?<r>[^/]+/[^/]+)/issues/") catch {r:""}) // {r:""} | .r) as $r
      | "\(.number) \(if ($r | length) == 0 then "-" else $r end) \($tok)"
    ' "$f")" || rc=$?
    if [[ $rc -ne 0 ]]; then
      die_read "unreadable or malformed issue-maker chip log: $f (treat its contents as UNKNOWN, not as zero chips)"
    fi
    [[ -n "$out" ]] || continue

    local num repo chip
    while read -r num repo chip; do
      [[ -n "$num" ]] || continue
      # A missing chip token means the line did not survive the emitter intact.
      # Counting it with an empty id would merge every such entry into one chip
      # — an under-count — so treat it as an unreadable log rather than guess.
      [[ -n "$chip" ]] || die_read "chip log $f: entry #$num produced no chip token (treat its contents as UNKNOWN, not as zero chips)"
      # GitHub repo identities are case-insensitive, so `Owner/Repo` and
      # `owner/repo` are the same repo. A literal compare would call the first
      # unattributable, which sends it down the guessed path and exempts it
      # from BOTH filters — a stale chip would then keep consuming capacity
      # after its issue closed. Fold both sides before comparing.
      repo="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
      if [[ "$repo" == "-" ]]; then
        warn "chip log $f: entry #$num has no attributable repo url — counting it against $slug (over-counting is the safe direction)"
        # Marked so the PR subtraction can leave it alone: the number is a
        # guess, and matching it against THIS repo's closed issues would turn a
        # deliberate over-count into an under-count on a number collision.
        printf '%s ? %s\n' "$num" "$chip"
      elif [[ "$repo" == "$slug_lc" ]]; then
        printf '%s . %s\n' "$num" "$chip"
      fi
    done <<<"$out"
  done
}

# Of the given issue numbers, which are currently OPEN.
#
# Deliberately NOT `gh issue list --limit N`: that returns the N newest open
# issues and is then treated as the complete set, so on a repo with more than N
# open issues a chip on an older one silently drops out of the count. Dropping a
# chip RAISES free slots, which is the unsafe direction — the cap would quietly
# permit more work on exactly the busiest repos. Asking about the specific
# numbers has no such horizon, and it is cheaper: chips are few, open issues are
# not. Chunked so a large chip set cannot build an unbounded query.
open_among() {
  local slug="$1"; shift
  local owner="${slug%%/*}" name="${slug##*/}"
  local nums=("$@")
  (( ${#nums[@]} )) || return 0

  local i=0 total=${#nums[@]}
  while (( i < total )); do
    local q="query { repository(owner: \"$owner\", name: \"$name\") {"
    local j=0 n
    while (( j < 100 && i < total )); do
      n="${nums[$i]}"
      # Numeric-only guard: these reach a query string, and a non-numeric value
      # here would be injected rather than rejected.
      [[ "$n" =~ ^[0-9]+$ ]] || die_read "non-numeric chip issue number in log: '$n'"
      q+=" n${n}: issue(number: ${n}) { number state }"
      i=$(( i + 1 )); j=$(( j + 1 ))
    done
    q+=" } }"

    local out rc=0
    out="$(gh api graphql -f query="$q" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      die_read "gh api graphql (issue states, repo=$slug) failed: $out"
    fi

    # A GraphQL 200 can carry `errors` alongside PARTIAL data, and gh does not
    # always exit non-zero for it. Resolved aliases would then be read as the
    # whole answer while the failed ones silently vanish — each missing alias
    # drops a chip, which RAISES free slots. Reject any errors outright rather
    # than counting a partial answer as a complete one.
    local gqerr rc1=0
    gqerr="$(printf '%s' "$out" | jq -r 'if (.errors // empty) then
              ([.errors[].message] | join("; ")) else empty end' 2>&1)" || rc1=$?
    if [[ $rc1 -ne 0 ]]; then
      die_read "could not parse the GraphQL response (repo=$slug): $gqerr"
    fi
    if [[ -n "$gqerr" ]]; then
      die_read "GraphQL returned errors for issue states (repo=$slug): $gqerr"
    fi

    # A number that does not exist comes back as null and is simply not open —
    # but the CONTAINER must be there. A missing .data.repository means the
    # query answered nothing, which is a failure, not an empty set.
    local parsed rc2=0
    parsed="$(printf '%s' "$out" \
      | jq -r 'if (.data.repository | type) != "object" then
                 error("no data.repository in response")
               else .data.repository end
               | to_entries[] | .value | select(. != null)
               | select(.state == "OPEN") | .number' 2>&1)" || rc2=$?
    if [[ $rc2 -ne 0 ]]; then
      die_read "could not parse issue states from GraphQL: $parsed"
    fi
    [[ -n "$parsed" ]] && printf '%s\n' "$parsed"
  done
  # Explicit: without it the function's status is the trailing `[[ -n … ]] &&`,
  # so "no chip issue is open" — a legitimate, common result — would return 1
  # and the caller would treat an ordinary empty answer as a read failure.
  return 0
}

# How many distinct CHIPS are live — not how many log entries are. One
# /issue-maker capture session offers ONE hand-off covering every issue it
# filed, so an N-issue session writes N entries carrying one `chip_task_id`.
# The narrowings below run per ENTRY, and the distinct-chip count is taken over
# what survives them. See CHIP LIVENESS.
#
# $1  repo slug
# $2  (optional) newline-separated list of issue numbers already counted by
#     the registry (source 2a). Any legacy chip whose surviving issues are ALL
#     in this excluded set is not counted here — the registry already holds a
#     slot for that work.  An absent or empty $2 applies no exclusion.
count_live_chips() {
  local slug="$1"
  local excluded_reg="${2:-}"

  # Both helpers can die_read, and a die_read inside `$(...)` ends only that
  # subshell — so each status is captured and re-raised here rather than
  # collapsing into an empty string that reads as "no chips". `pipefail` is on,
  # so the `| sort` below still surfaces chip_issue_numbers' own failure.
  #
  # Lines are "<number> <marker> <chip-token>"; `sort -u` dedupes whole entries,
  # which is exactly right — the same entry recorded twice is one entry.
  local chips rc=0
  chips="$(chip_issue_numbers "$slug" | sort -u)" || rc=$?
  (( rc == 0 )) || return "$rc"
  if [[ -z "$chips" ]]; then
    printf '0'
    return
  fi

  # Split on the attribution marker written by chip_issue_numbers.
  #
  # `sure` chips are known to belong to this repo, so both narrowings apply to
  # them: subtract the ones an open PR already covers, then keep only the ones
  # whose issue is still open.
  #
  # `guessed` chips had no usable url. Their NUMBER is all we have, and it is
  # meaningless outside a repo — so neither narrowing can be applied to them
  # without inverting the intent. The PR subtraction would drop one on a bare
  # number collision, and the open-issue intersection would drop EVERY guessed
  # chip whose number is not coincidentally an open issue here. Both turn a
  # deliberate over-count into an under-count, which is the direction this
  # script exists to prevent. So guessed chips bypass both filters and are
  # added to the total at the end, unconditionally.
  local sure guessed rc2=0
  sure="$(printf '%s\n' "$chips" | awk '$2=="." {print $1}' | sort -u)"
  guessed="$(printf '%s\n' "$chips" | awk '$2=="?" {print $1}' | sort -u)"

  # One issue can appear attributed in one capture log and unattributed in
  # another — the same offer, recorded twice. Deduping each class on its own
  # keeps it in both, so it would consume two slots. Attribution wins: an entry
  # that names this repo is better evidence than one that names nothing.
  if [[ -n "$sure" && -n "$guessed" ]]; then
    local only_guessed rcd=0
    only_guessed="$(comm -23 \
                     <(printf '%s\n' "$guessed" | sort -u) \
                     <(printf '%s\n' "$sure" | sort -u))" || rcd=$?
    (( rcd == 0 )) || die_read "comm -23 failed deduping guessed against attributed chips (exit $rcd)"
    guessed="$only_guessed"
  fi

  # `matched` collects the attributed numbers that survive BOTH narrowings.
  # Every branch that used to return early now leaves it empty and falls
  # through to the single distinct-chip count below, so the terminal accounting
  # exists in exactly one place and the branches cannot drift apart.
  local matched=""
  if [[ -n "$sure" ]]; then
    # Only `sure` numbers are worth asking about: a guessed number would be
    # answered against the wrong repo.
    local chip_nums=()
    while read -r _num; do [[ -n "$_num" ]] && chip_nums+=("$_num"); done <<<"$sure"

    local open_issues
    open_issues="$(open_among "$slug" ${chip_nums[@]+"${chip_nums[@]}"})" || rc2=$?
    (( rc2 == 0 )) || return "$rc2"

    # Drop chips whose issue is already represented by an open PR — that work is
    # counted once, by the PR source. Attributed chips only.
    local covered rc3=0
    covered="$(chips_covered_by_prs)" || rc3=$?
    (( rc3 == 0 )) || return "$rc3"
    # Every `comm` below captures its own status. An uncaptured one is the same
    # fabricated zero as everywhere else in this file: `set -e` is off, so a
    # failed command substitution just yields an empty string, the emptiness
    # guard fires, and the function returns a clean 0 that means "no chips"
    # rather than "the subtraction failed".
    if [[ -n "$covered" && -n "$sure" ]]; then
      local remaining rc4=0
      remaining="$(comm -23 \
                    <(printf '%s\n' "$sure" | sort -u) \
                    <(printf '%s\n' "$covered" | sort -u))" || rc4=$?
      (( rc4 == 0 )) || die_read "comm -23 failed subtracting PR-covered chips (exit $rc4)"
      sure="$remaining"
    fi

    # Intersect with the open issues. Both sides go through an identical
    # `sort -u`, which is all `comm` requires — it needs consistent ordering, not
    # numeric ordering, so lexical "10" before "9" on both sides is fine.
    if [[ -n "$sure" && -n "$open_issues" ]]; then
      local rc5=0
      matched="$(comm -12 \
                  <(printf '%s\n' "$sure" | sort -u) \
                  <(printf '%s\n' "$open_issues" | sort -u))" || rc5=$?
      (( rc5 == 0 )) || die_read "comm -12 failed intersecting chips with open issues (exit $rc5)"
    fi
  fi

  # The surviving ISSUES: attributed ones that cleared both narrowings, plus the
  # guessed ones that deliberately bypass both. `guessed` already had anything
  # also present in `sure` removed above, so the two lists are disjoint.
  local surviving
  surviving="$(printf '%s\n%s\n' "$matched" "$guessed" | awk 'NF' | sort -u)"
  if [[ -z "$surviving" ]]; then
    printf '0'
    return
  fi

  # Source 2a/2b dedup: remove issues the registry already holds.  A chip whose
  # EVERY surviving issue is in the excluded set has zero remaining issues and
  # is not counted here — the registry slot covers it.  A chip with even one
  # non-registry issue is still a distinct live legacy chip and IS counted.
  if [[ -n "$excluded_reg" ]]; then
    local rc_excl=0
    surviving="$(comm -23 \
                  <(printf '%s\n' "$surviving" | sort -u) \
                  <(printf '%s\n' "$excluded_reg" | awk 'NF' | sort -u))" || rc_excl=$?
    (( rc_excl == 0 )) || die_read "comm -23 failed excluding registry issues from legacy chip count (exit $rc_excl)"
  fi
  if [[ -z "$surviving" ]]; then
    printf '0'
    return
  fi

  # Now collapse issues to CHIPS. Two rules have to hold at once, and they pull
  # in opposite directions:
  #
  #   * One chip covering N issues is one offer (this function's whole point) —
  #     so the count is over distinct chip tokens, not surviving issues.
  #   * One issue offered by two capture sessions is one slot, not two — the
  #     older invariant, since the unit of work is the issue.
  #
  # Taking distinct chips alone would break the second rule; taking distinct
  # issues alone is the bug this replaces. So each surviving issue first names a
  # single representative chip — the lowest-sorting token it carries, chosen
  # deterministically so the count never depends on log order — and the answer
  # is how many distinct representatives remain. Both rules then hold from
  # either direction, and a chip's representatives collapse to one entry per
  # chip regardless of how many of its issues survived.
  local reps rc6=0
  reps="$(awk 'NR==FNR { live[$1]=1; next } ($1 in live) { print $1, $3 }' \
            <(printf '%s\n' "$surviving") <(printf '%s\n' "$chips") \
          | sort -k1,1 -k2,2 \
          | awk '!seen[$1]++ { print $2 }' \
          | sort -u)" || rc6=$?
  (( rc6 == 0 )) || die_read "failed mapping surviving chip issues back to chip ids (exit $rc6)"

  # Every surviving number came from an entry line, and every entry line carries
  # a chip token — so an empty mapping here is a broken pipeline, not an empty
  # set. Returning 0 for it would read as "nothing active" and uncap the gate
  # (feedback_guard_must_fail_closed.md).
  if [[ -z "$reps" ]]; then
    die_read "surviving chip issues mapped to no chip ids at all — the chip log read is inconsistent"
  fi

  # Counted separately from the mapping so the two failure modes stay distinct:
  # folding them into one pipeline lets `|| true` (needed for grep's exit 1 on
  # no match) swallow a real failure as well, and grep's printed "0" then reads
  # as a legitimate empty result.
  local n
  n="$(printf '%s\n' "$reps" | grep -c '^[A-Za-z0-9+/=]')" || true
  # grep -c prints 0 and exits 1 on no match, so read the printed value and
  # never substitute a fallback (feedback_grep_c_empty_file_exit1.md).
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# Inline pipelines not yet at PR: active_agents entries with no `.pr`.
count_inline_pipelines() {
  local getter="$SCRIPT_DIR/session-state.sh"
  if [[ ! -x "$getter" ]]; then
    printf '0'
    return
  fi

  local view rc=0 errfile
  errfile="$(mktemp)" || die_read "could not create a temp file to capture session-state stderr"
  view="$("$getter" ${REPO:+--repo "$REPO"} --session-view 2>"$errfile")" || rc=$?

  local errtext=""
  [[ -s "$errfile" ]] && errtext="$(tr '\n' ' ' < "$errfile")"
  rm -f "$errfile"

  # rc 3 = no state file yet; that is a legitimately empty source, not a
  # failure. Any other non-zero is a real read problem.
  if [[ $rc -eq 3 ]]; then
    printf '0'
    return
  fi
  if [[ $rc -ne 0 ]]; then
    die_read "session-state.sh --session-view failed (exit $rc) — cannot count inline pipelines${errtext:+: $errtext}"
  fi

  # `active_agents` records what was LAUNCHED, not what is still alive
  # (monitor-mode.md) — the parent removes an entry on completion, so a session
  # that crashed mid-phase leaves one behind. There is no lifecycle/status
  # field on these entries to filter on (the schema is id/task/issue/pr/phase/
  # launched/last_seen_at), so staleness is judged by the newest timestamp the
  # entry carries. An orphan pins capacity forever and blocks ALL new work,
  # which is worse than briefly over-offering.
  local stale_s="${CLAUDE_ACTIVE_WORK_AGENT_TTL_S:-7200}"
  [[ "$stale_s" =~ ^[0-9]+$ ]] || {
    warn "CLAUDE_ACTIVE_WORK_AGENT_TTL_S is not an integer: '$stale_s' — using 7200"
    stale_s=7200
  }
  local n rc2=0
  n="$(printf '%s' "$view" | jq --argjson ttl "$stale_s" --argjson now "$(date -u +%s)" '
        [ .active_agents[]?
          | select((.pr // "") == "")
          # No writer sets a lifecycle field on these entries today — the
          # schema is id/task/issue/pr/phase/launched/last_seen_at, and the
          # parent REMOVES an entry on completion rather than marking it. This
          # honours one anyway so that if a drain signal is ever added, a
          # finished agent frees its slot immediately instead of waiting out
          # the TTL below.
          | select(((.status // "") | ascii_downcase)
                   | . != "complete" and . != "completed" and . != "failed")
          # An entry with no usable timestamp is KEPT: unknown age must not
          # read as "expired", which would silently free a real slot.
          | select(
              ((.last_seen_at // .launched // "") as $t
               | if $t == "" then true
                 else (($t | fromdateiso8601? // null) as $e
                       | if $e == null then true else ($now - $e) < $ttl end)
                 end)
            )
        ] | length' 2>&1)" || rc2=$?
  if [[ $rc2 -ne 0 || ! "$n" =~ ^[0-9]+$ ]]; then
    die_read "could not parse active_agents from session-state: $n"
  fi
  printf '%s' "$n"
}

# Issue numbers from the chip offer registry (source 2a) — entries in
# offered or running state that have not expired.
# Returns a newline-separated list of issue numbers, one per entry.
# A missing or inaccessible registry contributes 0 with a DEGRADED warning
# rather than failing hard, because the legacy log (source 2b) is still read.
registry_chip_issue_numbers() {
  # Allow tests to skip the registry read entirely by setting the variable to
  # an empty string. Use the ${VAR+x} test to distinguish "explicitly set to
  # empty" from "unset": :-__unset__ would convert both to __unset__ and the
  # == "" check would never fire (feedback_codeant_empty_value_test.md).
  if [[ "${CLAUDE_CHIP_OFFER_REGISTRY_SH+x}" == "x" && -z "${CLAUDE_CHIP_OFFER_REGISTRY_SH}" ]]; then
    return 0
  fi

  local reg_script="${CLAUDE_CHIP_OFFER_REGISTRY_SH:-}"
  if [[ -z "$reg_script" ]]; then
    reg_script="$SCRIPT_DIR/chip-offer-registry.sh"
  fi
  if [[ ! -x "$reg_script" ]]; then
    warn "DEGRADED: chip-offer-registry.sh not found at $reg_script — registry source contributes 0"
    return 0
  fi

  local out rc=0
  out="$("$reg_script" ${REPO:+--repo "$REPO"} --list 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die_read "chip-offer-registry.sh --list failed (exit $rc): $out"
  fi

  # The registry handles repo scoping internally, so no further filtering needed.
  # Count entries in offered or running state (TTL handled by --count, but here
  # we need issue numbers for dedup — filter the same states).
  local ttl_s="${CLAUDE_CHIP_OFFER_TTL_S:-86400}"
  [[ "$ttl_s" =~ ^[0-9]+$ ]] || ttl_s=86400
  local now
  now="$(date -u +%s)"
  local nums rc2=0
  nums="$(printf '%s' "$out" | jq -r \
    --argjson now "$now" --argjson ttl "$ttl_s" '
    .[]
    | select(.state == "offered" or .state == "running")
    | select(
        (.offered_at // "") as $t
        | if $t == "" then true
          else ($t | fromdateiso8601? // null) as $e
               | if $e == null then true else ($now - $e) < $ttl end
          end
      )
    | .issue' 2>&1)" || rc2=$?
  if [[ $rc2 -ne 0 ]]; then
    die_read "could not extract issue numbers from registry: $nums"
  fi
  [[ -n "$nums" ]] && printf '%s\n' "$nums"
  return 0
}

command -v gh >/dev/null 2>&1 || die_read "gh not found on PATH — cannot count active work"
command -v jq >/dev/null 2>&1 || die_read "jq not found on PATH — cannot count active work"

# `die_read`'s exit inside a command substitution ends only the SUBSHELL — the
# parent would carry on with an empty string, which arithmetic silently reads
# as zero. A fabricated zero here means "nothing active", which uncaps the gate
# entirely (feedback_fabricated_sentinel_stable_signature.md). So every count
# is captured with its status and the failure is re-raised in the parent.
count_into() {  # $1 = variable name to set, $2... = the counting command
  local __var="$1"; shift
  local __out __rc=0
  __out="$("$@")" || __rc=$?
  if (( __rc != 0 )); then
    exit "$__rc"
  fi
  if [[ ! "$__out" =~ ^[0-9]+$ ]]; then
    die_read "internal: $1 produced a non-numeric count ('$__out')"
  fi
  printf -v "$__var" '%s' "$__out"
}

SLUG=""; SLUG_RC=0
SLUG="$(resolve_repo_slug)" || SLUG_RC=$?
(( SLUG_RC == 0 )) || exit "$SLUG_RC"

# --repo redirects the COUNT, but the cap can only come from a pm-config.md on
# disk — and a repo named by --repo alone is not checked out here, so there is
# nothing to read. Silently pairing repo B's activity with repo A's cap would
# produce a confident, wrong FREE. Say so once; --path is the way to point both
# at the same repo.
if [[ -n "$REPO" && "$CAP_SOURCE" == "config" ]]; then
  LOCAL_SLUG=""
  LOCAL_SLUG="$(cd "${FROM_PATH:-.}" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || LOCAL_SLUG=""
  if [[ -n "$LOCAL_SLUG" ]] &&
     [[ "$(printf '%s' "$LOCAL_SLUG" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]]; then
    warn "--repo $REPO counts that repo's work, but the cap ($CAP) was read from $LOCAL_SLUG's pm-config.md — pass --path <checkout of $REPO> to read its own cap, or unset the local one to use the built-in default"
  fi
fi

REPO="$SLUG"

# Not via count_into: this one populates a global, and a command substitution
# would set it in a subshell that then exits, leaving the parent's copy empty.
FETCH_RC=0
fetch_open_prs || FETCH_RC=$?
(( FETCH_RC == 0 )) || exit "$FETCH_RC"

count_into OPEN_PRS   count_open_prs
count_into PIPELINES  count_inline_pipelines

# Chip count: union of registry (2a) and legacy log (2b), deduped by issue number.
#
# Strategy: collect the live issue numbers from each source independently, then
# take the union. Each source applies its own liveness filter; the union ensures
# the same issue number from both sources counts as one chip, not two.
#
# Registry (2a): issue numbers of entries in offered/running state (TTL-filtered).
# Legacy log (2b): issue numbers from count_live_chips (open-issue + PR-filtered).
#   count_live_chips returns a count, not a list, so we re-derive the list from
#   the same filtering pipeline here for dedup purposes, then count the union.
#
# For the legacy side, we get the live numbers from count_live_chips_numbers()
# which mirrors count_live_chips but emits numbers instead of a count.
count_live_chips_numbers() {
  local slug="$1"
  local chips rc=0
  chips="$(chip_issue_numbers "$slug" | sort -u)" || rc=$?
  (( rc == 0 )) || return "$rc"
  [[ -n "$chips" ]] || return 0

  local sure guessed rc2=0
  sure="$(printf '%s\n' "$chips" | awk '$2=="." {print $1}' | sort -u)"
  guessed="$(printf '%s\n' "$chips" | awk '$2=="?" {print $1}' | sort -u)"

  # Dedup across attribution classes: a number attributed in one log and
  # unattributed in another is known-repo, so drop the guessed duplicate.
  if [[ -n "$sure" && -n "$guessed" ]]; then
    local only_guessed rcd=0
    only_guessed="$(comm -23 \
                     <(printf '%s\n' "$guessed" | sort -u) \
                     <(printf '%s\n' "$sure" | sort -u))" || rcd=$?
    (( rcd == 0 )) || die_read "comm -23 failed deduping guessed against attributed chips for numbers"
    guessed="$only_guessed"
  fi

  local chip_nums=()
  [[ -n "$sure" ]] && \
    while read -r _num; do [[ -n "$_num" ]] && chip_nums+=("$_num"); done <<<"$sure"

  local covered rc3=0
  covered="$(chips_covered_by_prs)" || rc3=$?
  (( rc3 == 0 )) || return "$rc3"
  if [[ -n "$covered" && -n "$sure" ]]; then
    local remaining rc4=0
    remaining="$(comm -23 \
                  <(printf '%s\n' "$sure" | sort -u) \
                  <(printf '%s\n' "$covered" | sort -u))" || rc4=$?
    (( rc4 == 0 )) || die_read "comm -23 failed subtracting PR-covered chips for numbers"
    sure="$remaining"
    chip_nums=()
    [[ -n "$sure" ]] && \
      while read -r _num; do [[ -n "$_num" ]] && chip_nums+=("$_num"); done <<<"$sure"
  fi

  local open_issues=""
  if (( ${#chip_nums[@]} )); then
    local rc5=0
    open_issues="$(open_among "$slug" "${chip_nums[@]}")" || rc5=$?
    (( rc5 == 0 )) || return "$rc5"
  fi

  local matched=""
  if [[ -n "$sure" && -n "$open_issues" ]]; then
    local rc6=0
    matched="$(comm -12 \
                <(printf '%s\n' "$sure" | sort -u) \
                <(printf '%s\n' "$open_issues" | sort -u))" || rc6=$?
    (( rc6 == 0 )) || die_read "comm -12 failed intersecting log chips with open issues"
  fi

  # Emit matched (attributed, live) and guessed numbers.
  [[ -n "$matched" ]] && printf '%s\n' "$matched"
  [[ -n "$guessed" ]] && printf '%s\n' "$guessed"
  return 0
}

# Count chips from source 2a (registry) and source 2b (legacy log) separately,
# then combine.  The registry (2a) uses 1 entry = 1 chip = 1 issue, so the
# issue count and chip count are the same there.  The legacy log (2b) can have
# N entries per chip, so count_live_chips counts DISTINCT chip_task_ids rather
# than issues.  Cross-source dedup: pass the registry issues to count_live_chips
# so any legacy chip whose surviving issues are ALL already in the registry is
# excluded from source 2b's count (the registry slot covers it).

# Source 2a: registry.
REG_NUMS=""; REG_RC=0
REG_NUMS="$(registry_chip_issue_numbers)" || REG_RC=$?
(( REG_RC == 0 )) || exit "$REG_RC"

REG_CHIP_COUNT=0
if [[ -n "$REG_NUMS" ]]; then
  REG_RAW="$(printf '%s\n' "$REG_NUMS" | grep -c '^[0-9]')" || true
  [[ "$REG_RAW" =~ ^[0-9]+$ ]] || REG_RAW=0
  REG_CHIP_COUNT="$REG_RAW"
fi

# Source 2b: legacy log (distinct chips, excluding issues the registry holds).
LOG_CHIP_COUNT=0; LOG_RC=0
LOG_CHIP_COUNT="$(count_live_chips "$SLUG" "$REG_NUMS")" || LOG_RC=$?
(( LOG_RC == 0 )) || exit "$LOG_RC"
[[ "$LOG_CHIP_COUNT" =~ ^[0-9]+$ ]] || LOG_CHIP_COUNT=0

CHIPS=$(( REG_CHIP_COUNT + LOG_CHIP_COUNT ))

ACTIVE=$(( OPEN_PRS + CHIPS + PIPELINES ))
FREE=$(( CAP - ACTIVE ))
(( FREE < 0 )) && FREE=0

case "$MODE" in
  free)
    printf '%s\n' "$FREE"
    ;;
  json)
    jq -cn \
      --argjson cap "$CAP" \
      --argjson active "$ACTIVE" \
      --argjson free "$FREE" \
      --argjson open_prs "$OPEN_PRS" \
      --argjson chips "$CHIPS" \
      --argjson pipelines "$PIPELINES" \
      --arg cap_source "$CAP_SOURCE" \
      '{cap: $cap, active: $active, free: $free,
        open_prs: $open_prs, live_chips: $chips, inline_pipelines: $pipelines,
        cap_source: $cap_source}'
    ;;
  *)
    printf 'CAP=%s ACTIVE=%s FREE=%s\n' "$CAP" "$ACTIVE" "$FREE"
    ;;
esac

exit 0
