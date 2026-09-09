#!/usr/bin/env bash
# split-thresholds.sh — resolve the time-based split threshold and increment bound.
# catalog: backlog-pm — Resolve `SPLIT_OVER_MIN` / `INCREMENT_BOUND_MIN` (env → pm-config.md `## Budget` → shipped defaults) so every capture- and pick-time sizing surface reads one figure
#
# PURPOSE
#   The sizing check asks two questions: how many deliverables an ask holds,
#   and — since issue #1680 — how long it will take. The time axis needs two
#   numbers: the planning bound above which an issue is split, and the bound
#   each resulting increment must fit inside.
#
#   This script is the SOLE OWNER of both defaults and of the resolution
#   cascade. Skill files name the knobs and describe the behaviour; they never
#   restate the numbers, so retuning happens in one place.
#
#   Sole owner does not mean sole mention: a skill file may restate these two
#   values as a LABELLED degraded fallback, for the case where this script does
#   not resolve at all (it is not symlinked into every repo). Those copies are
#   inert defaults printed alongside a `DEGRADED:` line, never a second
#   resolution path — when this script is reachable, its answer wins.
#
#   Defaults — SPLIT_OVER_MIN=180, INCREMENT_BOUND_MIN=120. Rationale lives in
#   .claude/reference/too-big-recalibration-2026-07.md (the 2026-09-08
#   amendment) and .claude/pm-config.md `## Budget`.
#
# USAGE
#   split-thresholds.sh [--split-over | --increment-bound | --json]
#                       [--path <dir>]
#   split-thresholds.sh --help | -h
#
# MODES
#   (default)          One plain line: `SPLIT_OVER_MIN=<n> INCREMENT_BOUND_MIN=<n>`.
#   --split-over       Print only the split threshold, in whole minutes.
#   --increment-bound  Print only the per-increment bound, in whole minutes.
#   --json             One-line JSON object carrying both figures and the
#                      source each was resolved from (`env`, `config`,
#                      `default`).
#
# FLAGS
#   --path <dir>  Resolve the repo root — and therefore pm-config.md — from
#                 this directory instead of the cwd, so an orchestrator in one
#                 checkout can read another repo's knobs.
#
# RESOLUTION CASCADE (per knob, highest first)
#   1. env — CLAUDE_SPLIT_OVER_MIN / CLAUDE_INCREMENT_BOUND_MIN
#   2. config — `## Budget` in <repo>/.claude/pm-config.md, via pm-config-get.sh
#   3. the shipped default
#   A value that is not a positive integer, or that falls outside its range, is
#   REPORTED on stderr and falls back to the default — never clamped, the same
#   contract LEAVE_LEAD_TIME_MIN follows. Ranges: SPLIT_OVER_MIN in [30, 960],
#   INCREMENT_BOUND_MIN in [15, 480].
#   The two knobs are PAIRED, so the ranges alone do not tell you what is
#   accepted: setting SPLIT_OVER_MIN at or below the 120-minute default for
#   INCREMENT_BOUND_MIN requires lowering that knob in the same edit, or the
#   coherence rule below rejects the pair and both revert to the defaults.
#   An INCOHERENT PAIR — an increment bound at or above the split threshold,
#   which would make every slice its own split trigger — is reported and BOTH
#   knobs fall back to the shipped defaults, mirroring the usage-horizon
#   inverted-pair rule in pm-config.md.
#
# EXIT CODES
#   0  resolved (defaults are a resolution, not a failure)
#   2  usage error (unknown flag, conflicting modes, missing flag value)
#
# DEPENDENCIES
#   - pm-config-get.sh and repo-root.sh alongside this script (both optional:
#     without them the config tier is skipped and env/defaults still resolve)
#
# EXAMPLES
#   split-thresholds.sh
#   split-thresholds.sh --split-over
#   SPLIT=$(split-thresholds.sh --split-over); (( BOUND_MIN > SPLIT )) && echo split
#   split-thresholds.sh --json --path /path/to/other/repo | jq -r .split_over_min

set -uo pipefail
# Best-effort telemetry — must never change this script's exit contract. Skipped
# when HOME is unset (issue #1434's shared contract: a bare ${HOME} expansion
# under `set -u` aborts a HOME-less run before --help can answer), stderr muted
# BEFORE the append per issue #1406's ordering. No ${HOME:-…} default: a
# fabricated path would write a stray root-anchored /.claude/ file.
if [[ -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
    2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

SPLIT_OVER_DEFAULT=180
SPLIT_OVER_MIN_ALLOWED=30
SPLIT_OVER_MAX_ALLOWED=960

INCREMENT_BOUND_DEFAULT=120
INCREMENT_BOUND_MIN_ALLOWED=15
INCREMENT_BOUND_MAX_ALLOWED=480

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

usage() {
  sed -n '2,/^$/p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

warn() { printf 'split-thresholds.sh: %s\n' "$1" >&2; }

die_usage() {
  warn "$1"
  printf 'Run with --help for usage.\n' >&2
  exit 2
}

MODE="plain"
FROM_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --split-over|--increment-bound|--json)
      requested="${1#--}"
      if [[ "$MODE" != "plain" ]]; then
        die_usage "conflicting output modes (--$requested after --$MODE)"
      fi
      MODE="$requested"
      shift ;;
    --path)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--path requires a value"
      FROM_PATH="$2"; shift 2 ;;
    --path=*)
      FROM_PATH="${1#--path=}"
      [[ -n "$FROM_PATH" ]] || die_usage "--path requires a value"
      shift ;;
    *)
      die_usage "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Read the `## Budget` section ONCE. Two knobs from one file read: a second
# call would re-resolve the repo root and could, mid-run, read a different
# file than the first — two knobs that must be coherent with each other are
# exactly the pair that must not come from two reads.
# ---------------------------------------------------------------------------
BUDGET_SECTION=""
read_budget_section() {
  local getter="$SCRIPT_DIR/pm-config-get.sh"
  [[ -x "$getter" ]] || return 0

  local root=""
  if [[ -x "$SCRIPT_DIR/repo-root.sh" ]]; then
    # Build the optional argument as an ARRAY. `${FROM_PATH:+"$FROM_PATH"}` is
    # unquoted as a whole, so a path containing spaces would word-split into
    # several arguments and repo-root.sh would resolve the wrong directory (or
    # reject the call). Expanded with the `+` guard so an EMPTY array under
    # `set -u` does not abort on bash 3.2, which is what macOS ships.
    local root_args=()
    [[ -n "$FROM_PATH" ]] && root_args=("$FROM_PATH")
    root="$("$SCRIPT_DIR/repo-root.sh" ${root_args[@]+"${root_args[@]}"} 2>/dev/null)" || root=""
  fi
  [[ -n "$root" && -r "$root/.claude/pm-config.md" ]] || return 0

  local body rc=0
  body="$("$getter" --section Budget --file "$root/.claude/pm-config.md" 2>/dev/null)" || rc=$?
  # rc 1 (section absent or empty) and rc 2 (file unreadable) are the ordinary
  # "this repo has not set the knobs" case and stay silent. rc 3 is a usage
  # error — our bug, not the repo's — and is worth a line.
  if (( rc == 3 )); then
    warn "pm-config-get.sh usage error while reading the Budget section; using defaults"
    return 0
  fi
  (( rc == 0 )) || return 0
  # Strip comment-only lines so a commented-out placeholder never reads as an
  # active setting.
  BUDGET_SECTION=$(printf '%s\n' "$body" | grep -v '^[[:space:]]*#' || true)
}
read_budget_section

# resolve_knob <KNOB_NAME> <env_set 0|1> <env_value> <default> <min> <max>
# Prints "<value> <source>". Capture the assignment first and validate second:
# a matcher that only accepts digits makes a typo indistinguishable from an
# absent knob, so a misconfiguration would fall back in silence.
#
# The env value is PASSED IN rather than read through an indirect expansion,
# and the config key is compared with `==` inside awk rather than interpolated
# into a regex: an identifier spliced into a pattern matches more than itself
# (`SPLIT_OVER_MIN` would also hit `MY_SPLIT_OVER_MIN`).
resolve_knob() {
  local name="$1" env_set="$2" env_value="$3" default="$4" lo="$5" hi="$6"
  local raw="" source="default"

  if [[ "$env_set" == "1" ]]; then
    raw="$env_value"
    source="env"
  elif [[ -n "$BUDGET_SECTION" ]]; then
    local found
    found=$(printf '%s\n' "$BUDGET_SECTION" | awk -F'[:=]' -v k="$name" '
      { key = $1; gsub(/[[:space:]]/, "", key)
        if (key == k && NF >= 2) { v = $2; gsub(/[[:space:]]/, "", v); print "FOUND:" v; exit } }')
    if [[ -n "$found" ]]; then
      # An assignment with an EMPTY value is a misconfiguration to report, not
      # an absent knob to skip — the FOUND: marker is what keeps the two apart.
      raw="${found#FOUND:}"
      source="config"
    fi
  fi

  if [[ "$source" == "default" ]]; then
    printf '%s %s' "$default" "default"
    return
  fi
  if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
    warn "$name ($source) is not a positive integer: '$raw' — using default $default"
    printf '%s %s' "$default" "default"
    return
  fi
  # Length-bound BEFORE the arithmetic, not after. An arbitrarily long digit
  # string overflows bash arithmetic, and an overflow is a fatal error — it would
  # abort the resolution instead of declining it, which is the one outcome this
  # cascade is built to never produce. 9 digits is far above the widest range any
  # knob here declares, so nothing legitimate is turned away.
  if (( ${#raw} > 9 )); then
    warn "$name ($source) has too many digits: '$raw' — using default $default"
    printf '%s %s' "$default" "default"
    return
  fi
  # 10# so a leading-zero value is never read as octal.
  local n=$((10#$raw))
  if (( n < lo || n > hi )); then
    warn "$name ($source) = $n is outside [$lo, $hi] — using default $default"
    printf '%s %s' "$default" "default"
    return
  fi
  printf '%s %s' "$n" "$source"
}

# `+x`, not `:-`: a variable SET to the empty string is a misconfiguration to
# report, not an absent knob to skip, and `:-` cannot tell the two apart.
SPLIT_ENV_SET=0; SPLIT_ENV_VALUE=""
if [[ -n "${CLAUDE_SPLIT_OVER_MIN+x}" ]]; then
  SPLIT_ENV_SET=1; SPLIT_ENV_VALUE="$CLAUDE_SPLIT_OVER_MIN"
fi
BOUND_ENV_SET=0; BOUND_ENV_VALUE=""
if [[ -n "${CLAUDE_INCREMENT_BOUND_MIN+x}" ]]; then
  BOUND_ENV_SET=1; BOUND_ENV_VALUE="$CLAUDE_INCREMENT_BOUND_MIN"
fi

read -r SPLIT_OVER_MIN SPLIT_OVER_SOURCE <<<"$(resolve_knob \
  SPLIT_OVER_MIN "$SPLIT_ENV_SET" "$SPLIT_ENV_VALUE" \
  "$SPLIT_OVER_DEFAULT" "$SPLIT_OVER_MIN_ALLOWED" "$SPLIT_OVER_MAX_ALLOWED")"
read -r INCREMENT_BOUND_MIN INCREMENT_BOUND_SOURCE <<<"$(resolve_knob \
  INCREMENT_BOUND_MIN "$BOUND_ENV_SET" "$BOUND_ENV_VALUE" \
  "$INCREMENT_BOUND_DEFAULT" "$INCREMENT_BOUND_MIN_ALLOWED" "$INCREMENT_BOUND_MAX_ALLOWED")"

# Coherence gate. An increment bound at or above the split threshold makes
# every slice a split trigger in its own right, so the decomposition can never
# terminate. Report and fall back to BOTH shipped defaults rather than clamping
# one of them — same contract as the usage-horizon inverted pair.
if (( INCREMENT_BOUND_MIN >= SPLIT_OVER_MIN )); then
  warn "INCREMENT_BOUND_MIN ($INCREMENT_BOUND_MIN) must be below SPLIT_OVER_MIN ($SPLIT_OVER_MIN) — using defaults $SPLIT_OVER_DEFAULT / $INCREMENT_BOUND_DEFAULT"
  SPLIT_OVER_MIN="$SPLIT_OVER_DEFAULT";       SPLIT_OVER_SOURCE="default"
  INCREMENT_BOUND_MIN="$INCREMENT_BOUND_DEFAULT"; INCREMENT_BOUND_SOURCE="default"
fi

case "$MODE" in
  split-over)      printf '%s\n' "$SPLIT_OVER_MIN" ;;
  increment-bound) printf '%s\n' "$INCREMENT_BOUND_MIN" ;;
  json)
    printf '{"split_over_min":%s,"split_over_source":"%s","increment_bound_min":%s,"increment_bound_source":"%s"}\n' \
      "$SPLIT_OVER_MIN" "$SPLIT_OVER_SOURCE" "$INCREMENT_BOUND_MIN" "$INCREMENT_BOUND_SOURCE" ;;
  *)
    printf 'SPLIT_OVER_MIN=%s INCREMENT_BOUND_MIN=%s\n' "$SPLIT_OVER_MIN" "$INCREMENT_BOUND_MIN" ;;
esac
exit 0
