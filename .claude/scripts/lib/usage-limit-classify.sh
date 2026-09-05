#!/usr/bin/env bash
# lib/usage-limit-classify.sh — the ONE place usage-limit prose is parsed
# (issue #1633).
#
# Source this file (do NOT execute it directly) from
# `.claude/hooks/usage-limit-record.sh`, which records the classification at
# write time, and from `.claude/scripts/credit-budget.sh`, which reads that
# recorded field and falls back to these same functions for legacy records
# written before the field existed. Two callers, one parser: a phrase set that
# drifts between them is the defect this file exists to prevent.
#
# PROBLEM SOLVED
#   `credit-budget.sh` treated EVERY `StopFailure error == "rate_limit"` event
#   as evidence of paid credit overage and parked autonomous dispatch for the
#   rest of the ET day. The overwhelmingly common case is the opposite: a
#   plan-window wall (rolling 5-hour or weekly), which means the account is ON
#   plan and paying nothing per token. Observed 2026-09-04 — four sessions died
#   on `You've hit your weekly limit · resets 1pm (America/New_York)` before
#   07:15Z, the window reopened at 13:00 ET, and the gate still refused to
#   dispatch that evening claiming a $25 credit budget had been spent. Nothing
#   had been spent.
#
#   A plan-window limit and a credit overage are opposite facts about the same
#   account. Telling them apart is all this library does.
#
# SAFETY (.claude/rules/safety.md §"Anthropic Quota & Spend Authority")
#   Nothing here counts tokens, converts tokens to dollars, or derives any
#   local spend figure. The sole inputs are the vendor's own message text and
#   the record's own timestamp — an upstream signal, read, never estimated.
#   The ban on local estimation is satisfied architecturally: there is no code
#   path an estimate could enter.
#
# CONTRACT
#   usage_limit_kind <message>
#     Prints exactly one of:
#       plan_window   — the account hit a plan window (rolling or weekly). NOT
#                       an overage: no credits were spent.
#       overage       — wording that names credits or spend as exhausted.
#       unclassified  — anything else. NOT an overage either; see PRECEDENCE.
#
#   usage_limit_reset_at <message> [recorded_at_iso]
#     Prints the ISO-8601 UTC instant the message says the window reopens, or
#     nothing when the message names none / it cannot be parsed. `recorded_at`
#     (UTC `…Z`) anchors the wall-clock time to the right day; it defaults to
#     now when absent or unparseable.
#
#   usage_limit_classify_json <message> [recorded_at_iso]
#     Prints one compact JSON object: {"limit_kind":"…","reset_at":"…"|null}.
#     Convenience for the recorder, which writes both fields at once.
#
#   All three are pure: no files read, no state written, no network.
#
# PRECEDENCE (deliberate, and the whole point)
#   1. A message naming WHEN the window reopens is `plan_window`, whatever else
#      it says. Credit balances do not reset on a clock; windows do. This is
#      the one wording-independent, structural tell in the whole signal, so it
#      outranks every phrase list below.
#   2. Otherwise, an explicit statement that CREDITS are exhausted is `overage`.
#   3. Otherwise, a known plan-wall phrase is `plan_window`.
#   4. Otherwise `unclassified`.
#
#   Upsell wording — "purchase credits", "upgrade your plan" — is deliberately
#   NOT an overage signal at any tier. It appears ON plan walls, inviting the
#   user to start spending; reading an invitation to spend as proof of spend is
#   precisely the inversion that produced #1633.
#
#   `unclassified` does not gate either. Probe 1 exists to detect overage, and
#   an event that is not classified as one is not evidence of credit spend. The
#   conservative fail-closed posture still applies where it belongs — to
#   UNREADABLE signal state, which `credit-budget.sh` reports as `unknown`.
#
# PORTABILITY
#   Written for bash 3.2 (the /bin/bash macOS ships, which the recorder runs
#   under): no `${var,,}`, no associative arrays, no `mapfile`. BSD and GNU
#   `date` are both handled explicitly, as `credit-budget.sh` already does for
#   its ET day boundaries.

# Guard against direct execution. Running a definition-only library would
# otherwise report success while doing nothing.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  echo "usage-limit-classify.sh: source this file, do not execute it directly" >&2
  exit 2
fi

# --- internal: portable date helpers -----------------------------------------
# Each tries BSD (macOS) first, then GNU, and prints nothing when both fail.
# `date` never gets to decide anything on its own: a failed conversion returns
# empty, and every caller treats empty as "not known" rather than as a value.

_ulc_lower() { # <text>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_ulc_epoch_from_utc_iso() { # <YYYY-MM-DDTHH:MM:SSZ>
  local iso="${1:-}"
  [ -n "$iso" ] || return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null \
    || date -u -d "$iso" '+%s' 2>/dev/null \
    || true
}

# EPOCH -> TEXT: the GNU `-d "@epoch"` arm goes FIRST, per issue #1587.
# `-r` exists on both platforms with DIFFERENT meanings — BSD reads epoch
# seconds, GNU reads a FILENAME and prints that file's mtime. A BSD-first chain
# works on GNU only by accident (no such file, so it falls through); the moment
# a file happens to be named for the epoch, GNU's `-r` succeeds and prints an
# unrelated time at exit 0, with no marker that anything went wrong. The GNU
# form is unambiguous: BSD rejects `-d` outright with zero bytes on stdout and
# falls through unchanged. Both arms are required — GNU alone strands macOS.
_ulc_utc_iso_from_epoch() { # <epoch>
  local ep="${1:-}"
  [ -n "$ep" ] || return 0
  date -u -d "@$ep" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$ep" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || true
}

_ulc_day_in_zone() { # <zone-or-empty> <epoch>
  local zone="${1:-}" ep="${2:-}"
  [ -n "$ep" ] || return 0
  if [ -n "$zone" ]; then
    TZ="$zone" date -d "@$ep" '+%Y-%m-%d' 2>/dev/null \
      || TZ="$zone" date -r "$ep" '+%Y-%m-%d' 2>/dev/null \
      || true
  else
    date -d "@$ep" '+%Y-%m-%d' 2>/dev/null \
      || date -r "$ep" '+%Y-%m-%d' 2>/dev/null \
      || true
  fi
}

_ulc_next_day() { # <zone-or-empty> <YYYY-MM-DD>
  local zone="${1:-}" day="${2:-}"
  [ -n "$day" ] || return 0
  if [ -n "$zone" ]; then
    TZ="$zone" date -j -v+1d -f '%Y-%m-%d' "$day" '+%Y-%m-%d' 2>/dev/null \
      || TZ="$zone" date -d "${day} + 1 day" '+%Y-%m-%d' 2>/dev/null \
      || true
  else
    date -j -v+1d -f '%Y-%m-%d' "$day" '+%Y-%m-%d' 2>/dev/null \
      || date -d "${day} + 1 day" '+%Y-%m-%d' 2>/dev/null \
      || true
  fi
}

_ulc_epoch_from_wallclock() { # <zone-or-empty> <YYYY-MM-DD> <HH:MM:SS>
  local zone="${1:-}" day="${2:-}" clock="${3:-}"
  [ -n "$day" ] && [ -n "$clock" ] || return 0
  if [ -n "$zone" ]; then
    TZ="$zone" date -j -f '%Y-%m-%d %H:%M:%S' "$day $clock" '+%s' 2>/dev/null \
      || TZ="$zone" date -d "$day $clock" '+%s' 2>/dev/null \
      || true
  else
    date -j -f '%Y-%m-%d %H:%M:%S' "$day $clock" '+%s' 2>/dev/null \
      || date -d "$day $clock" '+%s' 2>/dev/null \
      || true
  fi
}

# Extract an IANA zone the message states in parentheses, e.g. "(America/New_York)".
# Read from the ORIGINAL text, never the lowercased copy: zone names are file
# paths under /usr/share/zoneinfo and are case-sensitive, so `america/new_york`
# resolves to nothing and `date` would silently fall back to UTC — shifting the
# parsed reset by hours without a word.
_ulc_zone_from_text() { # <message>
  local text="${1:-}" zone="" zone_re='\(([A-Za-z]+/[A-Za-z_+-]+)\)'
  [[ "$text" =~ $zone_re ]] || return 0
  zone="${BASH_REMATCH[1]}"
  # Only accept a zone the system actually has. An unknown TZ value is not an
  # error to `date` — it quietly means UTC — so validating here is what keeps a
  # typo from becoming a wrong answer instead of no answer.
  [ -r "/usr/share/zoneinfo/$zone" ] || return 0
  printf '%s' "$zone"
}

# --- reset clause -------------------------------------------------------------

# Does the message name when the window reopens? Structural, not vocabulary:
# any "reset(s) [at] <time>" / "resets tomorrow" clause counts. This is the tell
# that survives the vendor rewording its notices.
usage_limit_has_reset_clause() { # <message>  -> exit 0 when present
  local lower rest
  lower="$(_ulc_lower "${1:-}")"
  case "$lower" in *reset*) ;; *) return 1 ;; esac
  rest="${lower#*reset}"
  # Bounded window after the word, and ANCHORED to it: only the filler that
  # actually occurs between "reset" and the time may intervene. A loose
  # "somewhere in the next 40 characters there is a digit" test would call
  # "reset your password, see step 2" a reset clause.
  rest="${rest:0:40}"
  local clause_re='^(s|ting)?[[:space:]]*(at[[:space:]]+|on[[:space:]]+)?(tomorrow[[:space:]]*(at[[:space:]]+)?|today[[:space:]]*(at[[:space:]]+)?|in[[:space:]]+)?[[:space:]]*[0-9]'
  if [[ "$rest" =~ $clause_re ]]; then return 0; fi
  # A clause naming a day rather than a clock time still says when the window
  # reopens, which is all this predicate claims. ANCHORED for the same reason
  # the clock-time test above is: a bare "is there a day word within 40
  # characters" search reads "reset your password tomorrow" as a reset clause,
  # and because a stated reset outranks the overage phrase list in
  # `usage_limit_kind`, that false positive would silently downgrade a real
  # overage to `plan_window` — the one direction this module must never fail in.
  local day_re='^(s|ting)?[[:space:]]*(at[[:space:]]+|on[[:space:]]+)?(tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)'
  if [[ "$rest" =~ $day_re ]]; then return 0; fi
  return 1
}

# Print the ISO-8601 UTC instant the message says the window reopens.
# Prints nothing when the message names none, when the clause cannot be parsed,
# or when `date` cannot do the conversion. Empty always means "not known" — it
# is never rendered as a value a caller could mistake for a real instant.
usage_limit_reset_at() { # <message> [recorded_at_iso]
  local message="${1:-}" recorded_at="${2:-}"
  local lower rest zone rec_epoch day clock candidate
  local hour min ampm tomorrow=0

  # Same anchored clause test the classifier uses, so the two can never
  # disagree about whether a message names a reset at all. Without it, "reset
  # your password, see step 2" yields an instant built from an unrelated digit
  # — a value where the honest answer is "none stated".
  usage_limit_has_reset_clause "$message" || return 0

  lower="$(_ulc_lower "$message")"
  rest="${lower#*reset}"
  rest="${rest:0:40}"

  case "$rest" in *tomorrow*) tomorrow=1 ;; esac

  # "resets in 3 hours" is a DURATION, not a wall-clock time. Reading its 3 as
  # 03:00 would invent an instant twelve hours off. Refuse to guess: an
  # unparsed clause degrades to "no reset known", which no rule treats as
  # permission.
  local relative_re='(^|[^a-z])in[[:space:]]+[0-9]'
  if [[ "$rest" =~ $relative_re ]]; then return 0; fi

  local time_re='([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*(am|pm)?'
  [[ "$rest" =~ $time_re ]] || return 0
  hour="${BASH_REMATCH[1]}"
  min="${BASH_REMATCH[3]}"
  ampm="${BASH_REMATCH[4]}"
  [ -n "$min" ] || min="00"

  # `10#` so a leading zero is decimal, not an invalid octal literal.
  hour=$((10#$hour))
  min=$((10#$min))
  if [ "$ampm" = "pm" ] && [ "$hour" -lt 12 ]; then hour=$((hour + 12)); fi
  if [ "$ampm" = "am" ] && [ "$hour" -eq 12 ]; then hour=0; fi
  [ "$hour" -ge 0 ] && [ "$hour" -le 23 ] || return 0
  [ "$min" -ge 0 ] && [ "$min" -le 59 ] || return 0
  clock="$(printf '%02d:%02d:00' "$hour" "$min")"

  zone="$(_ulc_zone_from_text "$message")"

  rec_epoch="$(_ulc_epoch_from_utc_iso "$recorded_at")"
  if [ -z "$rec_epoch" ]; then
    rec_epoch="$(date -u '+%s' 2>/dev/null)" || rec_epoch=""
  fi
  [ -n "$rec_epoch" ] || return 0

  day="$(_ulc_day_in_zone "$zone" "$rec_epoch")"
  [ -n "$day" ] || return 0

  if [ "$tomorrow" -eq 1 ]; then
    day="$(_ulc_next_day "$zone" "$day")"
    [ -n "$day" ] || return 0
  fi

  candidate="$(_ulc_epoch_from_wallclock "$zone" "$day" "$clock")"
  [ -n "$candidate" ] || return 0

  # A wall-clock time at or before the record's own instant names the NEXT
  # occurrence — "resets 1pm" written at 2pm means tomorrow's 1pm. Rolled via
  # a real calendar day rather than +86400 so a DST transition inside the
  # window does not shift the answer by an hour.
  if [ "$candidate" -le "$rec_epoch" ]; then
    day="$(_ulc_next_day "$zone" "$day")"
    [ -n "$day" ] || return 0
    candidate="$(_ulc_epoch_from_wallclock "$zone" "$day" "$clock")"
    [ -n "$candidate" ] || return 0
  fi

  _ulc_utc_iso_from_epoch "$candidate"
}

# --- kind ---------------------------------------------------------------------

# Explicit statements that CREDITS are exhausted. Each names credits or a spend
# limit as the thing that ran out — a fact about spending, not an invitation to
# spend. Upsell phrasing ("purchase credits", "upgrade your plan") is
# intentionally absent: it appears on plan walls.
_ulc_is_overage_text() { # <lowercased message>
  local lower="${1:-}"
  case "$lower" in
    *"credit balance is too low"*) return 0 ;;
    # Single-quoted on purpose: inside double quotes `$0` would expand to the
    # sourcing script's own name, and the pattern would never match anything.
    *'credit balance is $0'*)      return 0 ;;
    *"out of credits"*)            return 0 ;;
    *"no credits remaining"*)      return 0 ;;
    *"insufficient credits"*)      return 0 ;;
    *"spending limit"*)            return 0 ;;
    *"spend limit"*)               return 0 ;;
  esac
  return 1
}

# Known plan-wall shapes. The vendor's own wording for "this window is closed".
_ulc_is_plan_window_text() { # <lowercased message>
  local lower="${1:-}"
  case "$lower" in
    *"hit your weekly limit"*)     return 0 ;;
    *"hit your usage limit"*)      return 0 ;;
    *"hit your rate limit"*)       return 0 ;;
    *"hit the weekly limit"*)      return 0 ;;
    *"hit the usage limit"*)       return 0 ;;
    *"reached your weekly limit"*) return 0 ;;
    *"reached your usage limit"*)  return 0 ;;
    *"weekly limit reached"*)      return 0 ;;
    *"usage limit reached"*)       return 0 ;;
    *"rate limit reached"*)        return 0 ;;
    *"5-hour limit"*)              return 0 ;;
    *"5 hour limit"*)              return 0 ;;
    *"five-hour limit"*)           return 0 ;;
    *"weekly limit"*)              return 0 ;;
  esac
  return 1
}

# Classify one usage-limit message. See PRECEDENCE in the header.
usage_limit_kind() { # <message>
  local message="${1:-}" lower

  # An empty message carries no evidence of anything. It is NOT an overage.
  if [ -z "$message" ]; then
    printf 'unclassified'
    return 0
  fi

  lower="$(_ulc_lower "$message")"

  # 1. A stated reset time outranks every phrase list: windows reopen, credit
  #    balances do not.
  if usage_limit_has_reset_clause "$message"; then
    printf 'plan_window'
    return 0
  fi
  # 2. Credits named as exhausted.
  if _ulc_is_overage_text "$lower"; then
    printf 'overage'
    return 0
  fi
  # 3. A known plan wall with no reset time stated.
  if _ulc_is_plan_window_text "$lower"; then
    printf 'plan_window'
    return 0
  fi
  # 4. Unknown wording. Not evidence of spend.
  printf 'unclassified'
}

# Has a stated reset instant already come and gone?
#   Returns 0 (yes, the window has reopened) ONLY when the instant parses and
#   is at or before <now_epoch>. Every other case — no instant stated, an
#   unparseable one, an unusable clock — returns 1, i.e. "not known to have
#   passed". A reopening must be positively established before it can excuse an
#   event; absence of information never does.
usage_limit_reset_passed() { # <reset_at_iso> <now_epoch>
  local reset_at="${1:-}" now_epoch="${2:-}" reset_epoch
  [ -n "$reset_at" ] || return 1
  case "$now_epoch" in ''|*[!0-9]*) return 1 ;; esac
  reset_epoch="$(_ulc_epoch_from_utc_iso "$reset_at")"
  case "$reset_epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$reset_epoch" -le "$now_epoch" ]
}

# Both fields at once, as the compact JSON object the recorder embeds.
usage_limit_classify_json() { # <message> [recorded_at_iso]
  local message="${1:-}" recorded_at="${2:-}" kind reset_at
  kind="$(usage_limit_kind "$message")"
  reset_at="$(usage_limit_reset_at "$message" "$recorded_at")"
  jq -cn --arg kind "$kind" --arg reset_at "$reset_at" \
    '{limit_kind: $kind, reset_at: (if $reset_at == "" then null else $reset_at end)}'
}
