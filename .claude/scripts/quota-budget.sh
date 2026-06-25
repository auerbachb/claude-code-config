#!/usr/bin/env bash
# quota-budget.sh — Daily API spend tracker + end-of-day projection (issue #458).
#
# PURPOSE
#   Single source of truth for the daily-spend contract behind the /quota skill.
#   Reads the append-only ledger written by quota-usage-hook.sh
#   (~/.claude/quota-usage.log), sums today's cost (America/New_York day),
#   projects end-of-day spend from the fraction of the ET day elapsed, and
#   compares both against the daily cap in quota-config.json. Caches the result
#   in the `quota_daily` subtree of ~/.claude/session-state.json using the same
#   atomic jq + temp-file + mv pattern as greptile-budget.sh / cr-review-hourly.sh.
#
# USAGE
#   quota-budget.sh [--today] [--cap N] [--date YYYY-MM-DD] [--no-state]
#   quota-budget.sh --project [--cap N] [--date YYYY-MM-DD] [--no-state]
#   quota-budget.sh --check   [--cap N] [--date YYYY-MM-DD] [--no-state]
#   quota-budget.sh --help | -h
#
# MODES
#   --today    (default) Print today's spend snapshot JSON; exit 0.
#   --project  Same JSON, emphasising the end-of-day projection; exit 0.
#   --check    Same JSON; exit 1 when today's spend is at or above the cap
#              (budget exhausted). Use to gate spend-sensitive work.
#
# FLAGS
#   --cap N    Override the daily cap (USD). Default comes from
#              quota-config.json -> daily_cap_usd (fallback 100).
#   --date D   Aggregate a specific ET day (YYYY-MM-DD) instead of today.
#              Past days report no projection (fraction = 1.0).
#   --no-state Do not write the snapshot into session-state.json.
#
# OUTPUT
#   stdout: single-line JSON:
#     {date, spend_usd, cap_usd, remaining_usd, over_cap, exhausted, responses,
#      input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens,
#      fraction_of_day_elapsed, projected_eod_usd, projected_exhausted,
#      is_today, checked_at}
#   stderr: one-line error messages on failure.
#
# EXIT STATUS
#   0  Success (snapshot printed).
#   1  Budget exhausted (--check only; JSON still printed).
#   2  Usage error.
#   5  Read/compute/write failure.
#
# ENV OVERRIDES (tests)
#   QUOTA_CONFIG, QUOTA_USAGE_LOG, QUOTA_STATE_FILE.
#
# DEPENDENCIES
#   python3 (aggregation + ET date/projection via zoneinfo), jq (atomic
#   session-state write).

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG_PATH="${QUOTA_CONFIG:-$REPO_ROOT/quota-config.json}"
USAGE_LOG="${QUOTA_USAGE_LOG:-$HOME/.claude/quota-usage.log}"
STATE_FILE="${QUOTA_STATE_FILE:-$HOME/.claude/session-state.json}"
DEFAULT_CAP=100

print_help() {
  sed -n '/^# PURPOSE$/,/^# DEPENDENCIES$/p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "quota-budget.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

MODE="today"
CAP_OVERRIDE=""
DATE_OVERRIDE=""
WRITE_STATE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --today|--project|--check)
      MODE="${1#--}"
      shift
      ;;
    --cap)
      [[ $# -ge 2 ]] || die_usage "--cap requires a value"
      CAP_OVERRIDE="$2"
      if ! [[ "$CAP_OVERRIDE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        die_usage "--cap must be a non-negative number, got: $CAP_OVERRIDE"
      fi
      shift 2
      ;;
    --date)
      [[ $# -ge 2 ]] || die_usage "--date requires a value"
      DATE_OVERRIDE="$2"
      if ! [[ "$DATE_OVERRIDE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        die_usage "--date must be YYYY-MM-DD, got: $DATE_OVERRIDE"
      fi
      shift 2
      ;;
    --no-state)
      WRITE_STATE=0
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
      die_usage "unexpected positional argument: $1"
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "quota-budget.sh: 'python3' not found on PATH" >&2; exit 5; }

# Resolve cap: --cap override else config daily_cap_usd else DEFAULT_CAP.
if [[ -n "$CAP_OVERRIDE" ]]; then
  CAP="$CAP_OVERRIDE"
else
  CAP="$(python3 - "$CONFIG_PATH" "$DEFAULT_CAP" <<'PY' 2>/dev/null || echo "$DEFAULT_CAP"
import json, sys
path, fallback = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    cap = cfg.get("daily_cap_usd")
    print(float(cap) if cap is not None else float(fallback))
except Exception:
    print(float(fallback))
PY
)"
fi

# --- Aggregate + project (python3) ---
SNAPSHOT="$(python3 - "$USAGE_LOG" "$CAP" "$DATE_OVERRIDE" <<'PY'
import json, sys
from datetime import datetime, timezone

log_path, cap_s, date_override = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    cap = float(cap_s)
except Exception:
    cap = 0.0

try:
    import zoneinfo
    ET = zoneinfo.ZoneInfo("America/New_York")
except Exception:
    ET = None

now_utc = datetime.now(timezone.utc)
if ET is not None:
    now_et = now_utc.astimezone(ET)
else:
    now_et = now_utc
today_et = now_et.date().isoformat()

target = date_override or today_et
is_today = (target == today_et)

spend = 0.0
responses = 0
sums = {"input_tokens": 0, "output_tokens": 0, "cache_creation_tokens": 0, "cache_read_tokens": 0}

try:
    with open(log_path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 10:
                continue
            if parts[1] != target:
                continue
            try:
                spend += float(parts[9])
            except (ValueError, IndexError):
                continue
            responses += 1
            for idx, key in ((5, "input_tokens"), (6, "output_tokens"),
                             (7, "cache_creation_tokens"), (8, "cache_read_tokens")):
                try:
                    sums[key] += int(parts[idx])
                except (ValueError, IndexError):
                    pass
except FileNotFoundError:
    pass
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(0)

if is_today:
    midnight = now_et.replace(hour=0, minute=0, second=0, microsecond=0)
    elapsed = (now_et - midnight).total_seconds()
    fraction = max(min(elapsed / 86400.0, 1.0), 0.0)
else:
    fraction = 1.0

if fraction > 0:
    projected = spend / fraction
else:
    projected = spend

remaining = cap - spend
out = {
    "date": target,
    "spend_usd": round(spend, 4),
    "cap_usd": round(cap, 4),
    "remaining_usd": round(remaining if remaining > 0 else 0.0, 4),
    "over_cap": spend > cap,
    "exhausted": spend >= cap,
    "responses": responses,
    "input_tokens": sums["input_tokens"],
    "output_tokens": sums["output_tokens"],
    "cache_creation_tokens": sums["cache_creation_tokens"],
    "cache_read_tokens": sums["cache_read_tokens"],
    "fraction_of_day_elapsed": round(fraction, 4),
    "projected_eod_usd": round(projected, 4),
    "projected_exhausted": projected > cap,
    "is_today": is_today,
    "checked_at": now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
}
print(json.dumps(out))
PY
)" || { echo "quota-budget.sh: aggregation failed" >&2; exit 5; }

if [[ -z "$SNAPSHOT" ]] || ! printf '%s' "$SNAPSHOT" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
  echo "quota-budget.sh: aggregation produced invalid output" >&2
  exit 5
fi
if printf '%s' "$SNAPSHOT" | grep -q '"error"'; then
  echo "quota-budget.sh: $(printf '%s' "$SNAPSHOT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",""))' 2>/dev/null)" >&2
  exit 5
fi

# --- Cache snapshot into session-state.json (atomic jq + temp-file + mv) ---
if [[ "$WRITE_STATE" -eq 1 ]] && command -v jq >/dev/null 2>&1; then
  STATE_DIR="$(dirname "$STATE_FILE")"
  if mkdir -p "$STATE_DIR" 2>/dev/null; then
    tmp="$STATE_FILE.tmp.$$"
    input_file="$STATE_FILE"
    seeded=""
    if [[ ! -f "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
      seeded="$(mktemp)"
      printf '%s\n' '{}' > "$seeded"
      input_file="$seeded"
    fi
    # shellcheck disable=SC2064
    trap "rm -f '$tmp' ${seeded:+\"$seeded\"} 2>/dev/null" EXIT
    if jq \
      --argjson snap "$SNAPSHOT" \
      '.quota_daily = {
         date: $snap.date,
         spend_usd: $snap.spend_usd,
         cap_usd: $snap.cap_usd,
         responses: $snap.responses,
         projected_eod_usd: $snap.projected_eod_usd,
         exhausted: $snap.exhausted,
         projected_exhausted: $snap.projected_exhausted
       }
       | .last_updated = (now | todate)' \
      "$input_file" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$STATE_FILE" 2>/dev/null || echo "quota-budget.sh: could not write $STATE_FILE" >&2
    else
      echo "quota-budget.sh: jq failed updating $STATE_FILE (snapshot still printed)" >&2
      rm -f "$tmp" 2>/dev/null || true
    fi
    rm -f ${seeded:+"$seeded"} 2>/dev/null || true
    trap - EXIT
  fi
fi

echo "$SNAPSHOT"

if [[ "$MODE" == "check" ]]; then
  EXH="$(printf '%s' "$SNAPSHOT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["exhausted"])' 2>/dev/null || echo False)"
  [[ "$EXH" == "True" ]] && exit 1
fi
exit 0
