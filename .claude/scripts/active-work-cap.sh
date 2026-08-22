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
#     2. Live offered issue-maker chips — entries in
#        ~/.claude/handoffs/issue-maker-*-log.json with `status: "open"` and a
#        non-null `chip_task_id` (chip-launching.md "Cross-skill chip
#        visibility"), TWICE narrowed (see CHIP LIVENESS below).
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
#   Sources 1 and 2 need an explicit subtraction, because a chip's log entry is
#   NOT cleared when the chip is clicked. A clicked chip becomes a thread, then
#   a PR, while its issue stays open until that PR merges — so the same unit of
#   work would be counted twice and the effective cap halved. Chips whose issue
#   appears in an open PR's `closingIssuesReferences` are therefore excluded.
#
# KNOWN GAP — chips from /pm and /prompt are not counted
#   Only /issue-maker writes a durable, cross-thread chip record. /pm and
#   /prompt record a chip's task_id in their in-transcript Active Work table,
#   which no other thread can read, so their offers are invisible here. That is
#   a pre-existing hole in the chip contract (chip-launching.md "Cross-skill
#   chip visibility" says as much) rather than one introduced here, and closing
#   it needs a shared offer registry with a real lifecycle — tracked separately.
#   The practical effect is an UNDER-count on those two surfaces, which is the
#   unsafe direction, so it is stated here rather than left to be discovered.
#
# CHIP LIVENESS — why the raw log query is not the count
#   chip-launching.md's discovery query answers "has this issue already been
#   offered a chip", which is a per-issue dedup question. It is NOT a count of
#   live work, for two reasons measured on real logs (2026-08-21: 59 raw hits
#   across 6 logs):
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
#   So a chip counts only when its issue is STILL OPEN on GitHub — one
#   `gh issue list --state open` call for the target repo, intersected with the
#   log-derived numbers. A closed issue's chip is finished work, not pending
#   work. An entry whose `url` cannot be attributed to any repo is counted
#   anyway and warned about: over-counting narrows offers (safe), while
#   under-counting widens them (the failure this script exists to prevent).
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
#   CLAUDE_ACTIVE_WORK_HANDOFF_DIR  Override the issue-maker chip-log
#                           directory so tests never read live state.
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
resolve_repo_slug() {
  if [[ -n "$REPO" ]]; then
    printf '%s' "$REPO"
    return
  fi
  local out rc=0
  out="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1)" || rc=$?
  if [[ $rc -ne 0 || -z "$out" ]]; then
    die_read "could not resolve the current repo (pass --repo owner/name): $out"
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
    # Emit "<number> <repo-or-empty>" per live entry; attribution happens in
    # bash so an unparseable url is warned about rather than silently dropped.
    out="$(jq -r '
      if type != "object" or (.issues | type) != "array" then
        error("not an issue-maker log: root must be an object with an issues array")
      else . end
      | .issues[]
      | select(.status == "open" and .chip_task_id != null)
      | "\(.number) \((.url // "") | capture("^https?://[^/]+/(?<r>[^/]+/[^/]+)/issues/") // {r:""} | .r)"
    ' "$f")" || rc=$?
    if [[ $rc -ne 0 ]]; then
      die_read "unreadable or malformed issue-maker chip log: $f (treat its contents as UNKNOWN, not as zero chips)"
    fi
    [[ -n "$out" ]] || continue

    local num repo
    while read -r num repo; do
      [[ -n "$num" ]] || continue
      if [[ -z "$repo" ]]; then
        warn "chip log $f: entry #$num has no attributable repo url — counting it against $slug (over-counting is the safe direction)"
        printf '%s\n' "$num"
      elif [[ "$repo" == "$slug" ]]; then
        printf '%s\n' "$num"
      fi
    done <<<"$out"
  done
}

# Issue numbers currently OPEN in the target repo.
open_issue_numbers() {
  local slug="$1"
  local out rc=0
  out="$(gh issue list --repo "$slug" --state open --limit 500 --json number \
         --jq '.[].number' 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die_read "gh issue list (open, repo=$slug) failed: $out"
  fi
  printf '%s' "$out"
}

# A chip counts only while its issue is still open — see CHIP LIVENESS.
count_live_chips() {
  local slug="$1"

  # Both helpers can die_read, and a die_read inside `$(...)` ends only that
  # subshell — so each status is captured and re-raised here rather than
  # collapsing into an empty string that reads as "no chips". `pipefail` is on,
  # so the `| sort` below still surfaces chip_issue_numbers' own failure.
  local chips rc=0
  chips="$(chip_issue_numbers "$slug" | sort -u)" || rc=$?
  (( rc == 0 )) || return "$rc"
  if [[ -z "$chips" ]]; then
    printf '0'
    return
  fi

  local open_issues rc2=0
  open_issues="$(open_issue_numbers "$slug")" || rc2=$?
  (( rc2 == 0 )) || return "$rc2"
  if [[ -z "$open_issues" ]]; then
    printf '0'
    return
  fi

  # Drop chips whose issue is already represented by an open PR — that work is
  # counted once, by the PR source.
  local covered rc3=0
  covered="$(chips_covered_by_prs)" || rc3=$?
  (( rc3 == 0 )) || return "$rc3"
  # Every `comm` below captures its own status. An uncaptured one is the same
  # fabricated zero as everywhere else in this file: `set -e` is off, so a
  # failed command substitution just yields an empty string, the emptiness
  # guard fires, and the function returns a clean 0 that means "no chips"
  # rather than "the subtraction failed".
  if [[ -n "$covered" ]]; then
    local remaining rc4=0
    remaining="$(comm -23 \
                  <(printf '%s\n' "$chips" | sort -u) \
                  <(printf '%s\n' "$covered" | sort -u))" || rc4=$?
    (( rc4 == 0 )) || die_read "comm -23 failed subtracting PR-covered chips (exit $rc4)"
    chips="$remaining"
    if [[ -z "$chips" ]]; then
      printf '0'
      return
    fi
  fi

  # Intersect with the open issues. Both sides go through an identical
  # `sort -u`, which is all `comm` requires — it needs consistent ordering, not
  # numeric ordering, so lexical "10" before "9" on both sides is fine.
  local matched rc5=0
  matched="$(comm -12 \
              <(printf '%s\n' "$chips" | sort -u) \
              <(printf '%s\n' "$open_issues" | sort -u))" || rc5=$?
  (( rc5 == 0 )) || die_read "comm -12 failed intersecting chips with open issues (exit $rc5)"

  # Counted separately from the `comm` so the two failure modes stay distinct:
  # folding them into one pipeline lets `|| true` (needed for grep's exit 1 on
  # no match) swallow a comm failure as well, and grep's printed "0" then reads
  # as a legitimate empty intersection.
  local n
  n="$(printf '%s\n' "$matched" | grep -c '^[0-9]')" || true
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

  local n rc2=0
  n="$(printf '%s' "$view" | jq '[.active_agents[]? | select((.pr // "") == "")] | length' 2>&1)" || rc2=$?
  if [[ $rc2 -ne 0 || ! "$n" =~ ^[0-9]+$ ]]; then
    die_read "could not parse active_agents from session-state: $n"
  fi
  printf '%s' "$n"
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
REPO="$SLUG"

# Not via count_into: this one populates a global, and a command substitution
# would set it in a subshell that then exits, leaving the parent's copy empty.
FETCH_RC=0
fetch_open_prs || FETCH_RC=$?
(( FETCH_RC == 0 )) || exit "$FETCH_RC"

count_into OPEN_PRS   count_open_prs
count_into CHIPS      count_live_chips "$SLUG"
count_into PIPELINES  count_inline_pipelines

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
