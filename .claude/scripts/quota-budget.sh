#!/usr/bin/env bash
# quota-budget.sh — Daily API spend tracker + end-of-day projection (issue #458).
#
# PURPOSE
#   Single source of truth for the daily-spend contract behind the /quota skill.
#   Reads the append-only token ledger written by quota-usage-hook.sh
#   (~/.claude/quota-usage.log), groups it by America/New_York day, converts
#   token counts to USD with the per-model pricing in quota-config.json, projects
#   end-of-day spend from the fraction of the ET day elapsed, and classifies the
#   result against the daily cap + alert thresholds. Spend tracking is
#   OBSERVATIONAL — it surfaces warnings but never blocks work (exit 0 on
#   success regardless of spend). State is cached in the `quota_daily` subtree of
#   ~/.claude/session-state.json using the same atomic jq + temp-file + mv pattern
#   as greptile-budget.sh / cr-review-hourly.sh.
#
# USAGE
#   quota-budget.sh [--check] [--cap N] [--date YYYY-MM-DD] [--no-state]
#   quota-budget.sh --week  [--cap N] [--no-state]
#   quota-budget.sh --config
#   quota-budget.sh --reset [--cap N] [--no-state]
#   quota-budget.sh --help | -h
#
# MODES
#   --check    (default) Aggregate today's ET spend, project end-of-day, classify
#              against thresholds, cache the snapshot, and print it as JSON.
#   --week     Aggregate the last 7 ET days (zero-filled) from the ledger and
#              print per-day + total JSON. Still refreshes today's cached snapshot.
#   --config   Print the resolved config (daily cap, thresholds, stop-hook
#              threshold, plan metadata, pricing) as JSON. No state write.
#   --reset    Zero today's cached counter in session-state.json (cross-day reset
#              is automatic — counting is ET-day-scoped off the durable ledger,
#              which is never modified). Prints the zeroed snapshot.
#
# FLAGS
#   --cap N    Override the daily cap (USD). Default: quota-config.json
#              daily_cap_usd (fallback 3.33).
#   --date D   Aggregate a specific ET day (YYYY-MM-DD) instead of today
#              (--check only). Past days report fraction = 1.0 (no projection).
#   --no-state Do not write the snapshot into session-state.json.
#
# OUTPUT
#   stdout: single-line JSON. --check snapshot fields:
#     {date, input_tokens, output_tokens, cache_read_tokens,
#      cache_creation_tokens, estimated_usd, budget_usd, spend_pct, responses,
#      fraction_of_day_elapsed, projected_eod_usd, projected_pct, status,
#      surface, over_cap, by_model, is_today, checked_at}
#   stderr: one-line error messages on failure.
#
# THRESHOLDS (classified on projected_pct = projected_eod_usd / cap)
#   status: ok (<info) | info (info..warn) | warn (warn..critical) | critical (>=critical)
#   surface: true once projected_pct >= info threshold (default 0.60).
#
# EXIT STATUS
#   0  Success (observational — never non-zero on high spend).
#   2  Usage error.
#   5  Read/compute/write failure.
#
# ENV OVERRIDES (tests): QUOTA_CONFIG, QUOTA_USAGE_LOG, QUOTA_STATE_FILE.
#
# DEPENDENCIES
#   python3 (aggregation + ET grouping/projection via zoneinfo), jq (atomic
#   session-state write).

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG_PATH="${QUOTA_CONFIG:-$REPO_ROOT/quota-config.json}"
USAGE_LOG="${QUOTA_USAGE_LOG:-$HOME/.claude/quota-usage.log}"
STATE_FILE="${QUOTA_STATE_FILE:-$HOME/.claude/session-state.json}"
DEFAULT_CAP="3.33"

print_help() {
  sed -n '/^# PURPOSE$/,/^# DEPENDENCIES$/p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "quota-budget.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

MODE="check"
CAP_OVERRIDE=""
DATE_OVERRIDE=""
WRITE_STATE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --check) MODE="check"; shift ;;
    --week) MODE="week"; shift ;;
    --config) MODE="config"; shift ;;
    --reset) MODE="reset"; shift ;;
    --cap)
      [[ $# -ge 2 ]] || die_usage "--cap requires a value"
      CAP_OVERRIDE="$2"
      [[ "$CAP_OVERRIDE" =~ ^[0-9]+([.][0-9]+)?$ ]] || die_usage "--cap must be a non-negative number, got: $CAP_OVERRIDE"
      shift 2 ;;
    --date)
      [[ $# -ge 2 ]] || die_usage "--date requires a value"
      DATE_OVERRIDE="$2"
      [[ "$DATE_OVERRIDE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die_usage "--date must be YYYY-MM-DD, got: $DATE_OVERRIDE"
      shift 2 ;;
    --no-state) WRITE_STATE=0; shift ;;
    --) shift; break ;;
    -*) die_usage "unknown flag: $1" ;;
    *) die_usage "unexpected positional argument: $1" ;;
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

# --- atomic session-state write helper (jq + temp-file + mv, like greptile-budget.sh) ---
write_quota_daily() {
  # $1 = quota_daily JSON object to store
  local obj="$1"
  command -v jq >/dev/null 2>&1 || return 0
  local state_dir; state_dir="$(dirname "$STATE_FILE")"
  mkdir -p "$state_dir" 2>/dev/null || return 0
  local tmp="$STATE_FILE.tmp.$$" input_file="$STATE_FILE" seeded=""
  if [[ ! -f "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    seeded="$(mktemp)"; printf '%s\n' '{}' > "$seeded"; input_file="$seeded"
  fi
  _wqd_cleanup() { rm -f "$tmp" ${seeded:+"$seeded"} 2>/dev/null; }
  trap _wqd_cleanup RETURN
  if jq --argjson qd "$obj" '.quota_daily = $qd | .last_updated = (now | todate)' \
      "$input_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE" 2>/dev/null || echo "quota-budget.sh: could not write $STATE_FILE" >&2
  else
    echo "quota-budget.sh: jq failed updating $STATE_FILE (snapshot still printed)" >&2
  fi
}

# --- --config: print resolved config ---
if [[ "$MODE" == "config" ]]; then
  python3 - "$CONFIG_PATH" "$CAP" <<'PY' || { echo "quota-budget.sh: failed to read config" >&2; exit 5; }
import json, sys
path, cap = sys.argv[1], float(sys.argv[2])
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
th = cfg.get("thresholds") or {}
out = {
    "config_path": path,
    "daily_cap_usd": cap,
    "currency": cfg.get("currency", "USD"),
    "thresholds": {
        "info": th.get("info", 0.60),
        "warn": th.get("warn", 0.80),
        "critical": th.get("critical", 0.95),
    },
    "stop_hook_threshold": cfg.get("stop_hook_threshold", 0.60),
    "plan": cfg.get("plan", {}),
    "pricing": {k: v for k, v in (cfg.get("pricing") or {}).items() if k != "_comment"},
}
print(json.dumps(out))
PY
  exit 0
fi

# --- --reset: zero today's cached counter ---
if [[ "$MODE" == "reset" ]]; then
  SNAPSHOT="$(python3 - "$CAP" <<'PY'
import json, sys
from datetime import datetime, timezone
cap = float(sys.argv[1])
try:
    import zoneinfo
    today = datetime.now(zoneinfo.ZoneInfo("America/New_York")).date().isoformat()
except Exception:
    today = datetime.now(timezone.utc).date().isoformat()
print(json.dumps({
    "date": today, "input_tokens": 0, "output_tokens": 0,
    "cache_read_tokens": 0, "cache_creation_tokens": 0,
    "estimated_usd": 0.0, "budget_usd": round(cap, 4),
    "projected_eod_usd": 0.0, "status": "ok",
}))
PY
)"
  [[ "$WRITE_STATE" -eq 1 ]] && write_quota_daily "$SNAPSHOT"
  echo "$SNAPSHOT"
  exit 0
fi

# --- --check / --week: aggregate the ledger ---
SNAPSHOT="$(python3 - "$CONFIG_PATH" "$USAGE_LOG" "$CAP" "$MODE" "$DATE_OVERRIDE" <<'PY'
import json, os, sys
from datetime import datetime, timezone, timedelta

config_path, log_path, cap_s, mode, date_override = sys.argv[1:6]
try:
    cap = float(cap_s)
except Exception:
    cap = 0.0

try:
    with open(config_path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
pricing = cfg.get("pricing") if isinstance(cfg.get("pricing"), dict) else {}
default_price = pricing.get("default") if isinstance(pricing.get("default"), dict) else \
    {"input": 15.0, "output": 75.0, "cache_write": 18.75, "cache_read": 1.5}
th = cfg.get("thresholds") or {}
INFO = float(th.get("info", 0.60)); WARN = float(th.get("warn", 0.80)); CRIT = float(th.get("critical", 0.95))

def num(v, fb):
    try:
        return float(v)
    except (TypeError, ValueError):
        return fb

def price_for(model):
    model = model or ""
    best, best_len = None, -1
    for k, v in pricing.items():
        if k in ("default", "_comment") or not isinstance(v, dict):
            continue
        if k in model and len(k) > best_len:
            best, best_len = k, len(k)
    chosen = pricing.get(best, default_price) if best else default_price
    return {
        "input": num(chosen.get("input"), num(default_price.get("input"), 0.0)),
        "output": num(chosen.get("output"), num(default_price.get("output"), 0.0)),
        "cache_write": num(chosen.get("cache_write"), num(default_price.get("cache_write"), 0.0)),
        "cache_read": num(chosen.get("cache_read"), num(default_price.get("cache_read"), 0.0)),
    }

try:
    import zoneinfo
    ET = zoneinfo.ZoneInfo("America/New_York")
except Exception:
    ET = None

# QUOTA_FAKE_NOW (ISO8601, test-only) pins "now" so the projection floor and
# ET-day boundary behavior are deterministically testable.
_fake_now = os.environ.get("QUOTA_FAKE_NOW")
now_utc = None
if _fake_now:
    try:
        s = _fake_now.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        now_utc = dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except Exception:
        now_utc = None
if now_utc is None:
    now_utc = datetime.now(timezone.utc)
now_et = now_utc.astimezone(ET) if ET else now_utc
today_et = now_et.date().isoformat()

def parse_utc(ts):
    ts = ts.strip()
    try:
        if ts.endswith("Z"):
            ts = ts[:-1] + "+00:00"
        dt = datetime.fromisoformat(ts)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None

def et_date_of(ts):
    dt = parse_utc(ts)
    if dt is None:
        return None
    return (dt.astimezone(ET) if ET else dt).date().isoformat()

def blank_day(d):
    return {"date": d, "input_tokens": 0, "output_tokens": 0,
            "cache_read_tokens": 0, "cache_creation_tokens": 0,
            "estimated_usd": 0.0, "responses": 0, "by_model": {}}

# Accumulate per ET day.
days = {}
def acc(d, model, inp, out, cr, cw):
    e = days.setdefault(d, blank_day(d))
    e["input_tokens"] += inp; e["output_tokens"] += out
    e["cache_read_tokens"] += cr; e["cache_creation_tokens"] += cw
    e["responses"] += 1
    p = price_for(model)
    cost = (inp * p["input"] + out * p["output"] + cr * p["cache_read"] + cw * p["cache_write"]) / 1_000_000.0
    e["estimated_usd"] += cost
    m = e["by_model"].setdefault(model, {"model": model, "input_tokens": 0, "output_tokens": 0,
                                         "cache_read_tokens": 0, "cache_creation_tokens": 0, "estimated_usd": 0.0})
    m["input_tokens"] += inp; m["output_tokens"] += out
    m["cache_read_tokens"] += cr; m["cache_creation_tokens"] += cw
    m["estimated_usd"] += cost

try:
    with open(log_path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 7:
                continue
            d = et_date_of(parts[0])
            if d is None:
                continue
            model = parts[1]
            try:
                inp, out, cr, cw = (int(parts[2]), int(parts[3]), int(parts[4]), int(parts[5]))
            except ValueError:
                continue
            acc(d, model, inp, out, cr, cw)
except FileNotFoundError:
    pass
except Exception as e:
    print(json.dumps({"error": str(e)})); sys.exit(0)

def finalize_models(by_model):
    lst = sorted(by_model.values(), key=lambda m: m["estimated_usd"], reverse=True)
    for m in lst:
        m["estimated_usd"] = round(m["estimated_usd"], 4)
    return lst

def classify(projected_pct):
    if projected_pct >= CRIT:
        return "critical"
    if projected_pct >= WARN:
        return "warn"
    if projected_pct >= INFO:
        return "info"
    return "ok"

if mode == "week":
    out_days = []
    total = 0.0; total_resp = 0
    week_models = {}
    for i in range(6, -1, -1):
        d = (now_et - timedelta(days=i)).date().isoformat() if ET else (now_utc - timedelta(days=i)).date().isoformat()
        e = days.get(d, blank_day(d))
        row = {
            "date": d,
            "estimated_usd": round(e["estimated_usd"], 4),
            "input_tokens": e["input_tokens"], "output_tokens": e["output_tokens"],
            "cache_read_tokens": e["cache_read_tokens"], "cache_creation_tokens": e["cache_creation_tokens"],
            "responses": e["responses"],
        }
        out_days.append(row)
        total += e["estimated_usd"]; total_resp += e["responses"]
        for mk, mv in e["by_model"].items():
            wm = week_models.setdefault(mk, {"model": mk, "estimated_usd": 0.0})
            wm["estimated_usd"] += mv["estimated_usd"]
    wm_list = sorted(week_models.values(), key=lambda m: m["estimated_usd"], reverse=True)
    for m in wm_list:
        m["estimated_usd"] = round(m["estimated_usd"], 4)
    print(json.dumps({
        "mode": "week", "days": out_days,
        "total_usd": round(total, 4), "total_responses": total_resp,
        "by_model": wm_list, "budget_usd": round(cap, 4),
        "checked_at": now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "today": today_et,
    }))
    sys.exit(0)

# --- check ---
target = date_override or today_et
is_today = (target == today_et)
e = days.get(target, blank_day(target))
spend = e["estimated_usd"]

if is_today:
    midnight = now_et.replace(hour=0, minute=0, second=0, microsecond=0)
    fraction = max(min((now_et - midnight).total_seconds() / 86400.0, 1.0), 0.0)
else:
    fraction = 1.0
# Linear run-rate projection, but floor the denominator so a tiny elapsed
# fraction just after ET midnight cannot explode the projection. Without this,
# e.g. $0.10 spent one minute into the day extrapolates to ~$144, producing a
# false critical/over-cap status. The floor caps the extrapolation multiplier at
# 24x (>= 1 hour of data) before the run-rate is trusted; the true elapsed
# fraction is still reported as fraction_of_day_elapsed for transparency.
MIN_PROJECTION_FRACTION = 1.0 / 24.0  # 1 hour
proj_fraction = max(fraction, MIN_PROJECTION_FRACTION)
projected = spend / proj_fraction if proj_fraction > 0 else spend

spend_pct = (spend / cap) if cap > 0 else 0.0
projected_pct = (projected / cap) if cap > 0 else 0.0
status = classify(projected_pct)

out = {
    "date": target,
    "input_tokens": e["input_tokens"], "output_tokens": e["output_tokens"],
    "cache_read_tokens": e["cache_read_tokens"], "cache_creation_tokens": e["cache_creation_tokens"],
    "estimated_usd": round(spend, 4),
    "budget_usd": round(cap, 4),
    "spend_pct": round(spend_pct, 4),
    "responses": e["responses"],
    "fraction_of_day_elapsed": round(fraction, 4),
    "projected_eod_usd": round(projected, 4),
    "projected_pct": round(projected_pct, 4),
    "status": status,
    "surface": projected_pct >= INFO,
    "over_cap": spend > cap,
    "by_model": finalize_models(e["by_model"]),
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

# Cache today's snapshot into session-state.json under quota_daily (spec schema).
if [[ "$WRITE_STATE" -eq 1 ]]; then
  if [[ "$MODE" == "week" ]]; then
    # Refresh today's snapshot too so /status etc. stay current.
    TODAY_SNAP="$("$0" --check --cap "$CAP" --no-state 2>/dev/null || true)"
  else
    TODAY_SNAP="$SNAPSHOT"
  fi
  if [[ -n "${TODAY_SNAP:-}" ]] && printf '%s' "$TODAY_SNAP" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    QD="$(printf '%s' "$TODAY_SNAP" | python3 -c 'import json,sys
s=json.load(sys.stdin)
print(json.dumps({
 "date": s["date"],
 "input_tokens": s["input_tokens"],
 "output_tokens": s["output_tokens"],
 "cache_read_tokens": s["cache_read_tokens"],
 "cache_creation_tokens": s["cache_creation_tokens"],
 "estimated_usd": s["estimated_usd"],
 "budget_usd": s["budget_usd"],
 "projected_eod_usd": s.get("projected_eod_usd", s["estimated_usd"]),
 "status": s.get("status", "ok"),
}))' 2>/dev/null || true)"
    [[ -n "$QD" ]] && write_quota_daily "$QD"
  fi
fi

echo "$SNAPSHOT"
exit 0
