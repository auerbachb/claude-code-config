#!/usr/bin/env bash
# quota-budget.sh — Monthly API spend tracker + daily warn signal (issue #495).
#
# PURPOSE
#   Single source of truth for the monthly+daily-spend contract behind the /quota
#   skill. Reads the append-only token ledger written by quota-usage-hook.sh
#   (~/.claude/quota-usage.log), groups it by America/New_York day and month,
#   converts token counts to USD with the per-model pricing in quota-config.json,
#   projects end-of-month spend from the fraction of the ET month elapsed, and
#   classifies the result against:
#     - Monthly cap (primary signal): critical at ≥95%, warn ≥80%, info ≥60%
#     - Daily warn (secondary signal): warn at ≥$100, info at ≥$80, NEVER critical
#   Spend tracking is OBSERVATIONAL — it surfaces warnings but never blocks work
#   (exit 0 on success regardless of spend). State is cached in the `quota_daily`
#   subtree of ~/.claude/session-state.json using the same atomic jq + temp-file
#   + mv pattern as greptile-budget.sh / cr-review-hourly.sh.
#
# USAGE
#   quota-budget.sh [--check] [--date YYYY-MM-DD] [--no-state]
#   quota-budget.sh --week  [--no-state]
#   quota-budget.sh --month [--no-state]
#   quota-budget.sh --config
#   quota-budget.sh --reset [--no-state]
#   quota-budget.sh --config-cap monthly=N [daily-warn=M]
#   quota-budget.sh --config-cap daily-warn=M
#   quota-budget.sh --ack [--session SESSION_ID]
#   quota-budget.sh --tail [N]
#   quota-budget.sh --help | -h
#
# MODES
#   --check    (default) Aggregate today's ET spend + this month's ET spend,
#              project end-of-day and end-of-month, classify against thresholds,
#              cache the snapshot, and print it as JSON.
#   --week     Aggregate the last 7 ET days (zero-filled) from the ledger and
#              print per-day + total JSON. Still refreshes today's cached snapshot.
#   --month    Aggregate the current ET month (day-by-day, zero-filled) from the
#              ledger and print a summary JSON.
#   --config   Print the resolved config (caps, thresholds, stop-hook thresholds,
#              plan metadata, pricing) as JSON. No state write.
#   --reset    Zero today's cached counter in session-state.json (cross-day reset
#              is automatic — counting is ET-day-scoped off the durable ledger,
#              which is never modified). Prints the zeroed snapshot.
#   --config-cap monthly=N       Set monthly_cap_usd to N in quota-config.json.
#   --config-cap daily-warn=M   Set daily_warn_threshold_usd to M.
#   --config-cap monthly=N daily-warn=M  Set both.
#   --ack      Acknowledge the current spend warning for the rest of today's session.
#              Silences the Stop-hook line until severity escalates or the ET day
#              rolls over. Writes ~/.claude/quota-ack.json. Use --session to specify
#              the session id (defaults to $CLAUDE_SESSION_ID or session-state.json).
#   --tail [N] Show the last N entries from the ledger (default 20). Human-readable
#              table: timestamp, model, cost, session. Useful for debugging.
#
# FLAGS
#   --date D   Aggregate a specific ET day (YYYY-MM-DD) instead of today
#              (--check only). Past days report fraction = 1.0 (no projection).
#   --no-state Do not write the snapshot into session-state.json.
#   --session S  Session ID for --ack (overrides $CLAUDE_SESSION_ID).
#
# ENV OVERRIDES (tests): QUOTA_CONFIG, QUOTA_USAGE_LOG, QUOTA_STATE_FILE,
#   QUOTA_ACK_FILE, CLAUDE_SESSION_ID.
#
# OUTPUT
#   stdout: single-line JSON. --check snapshot fields:
#     {date, month, input_tokens, output_tokens, cache_read_tokens,
#      cache_creation_tokens, estimated_usd, daily_warn_threshold_usd,
#      monthly_cap_usd, daily_spend_pct_of_warn, monthly_spend_pct,
#      responses, fraction_of_day_elapsed, fraction_of_month_elapsed,
#      projected_eod_usd, projected_eom_usd, projected_eom_pct,
#      daily_status, monthly_status, status, surface,
#      by_model, is_today, checked_at}
#   stderr: one-line error messages on failure.
#
# THRESHOLDS
#   monthly_status (from projected_eom_pct = projected_eom_usd / monthly_cap_usd):
#     ok (<0.60) | info (0.60–0.80) | warn (0.80–0.95) | critical (≥0.95)
#   daily_status (from today's actual spend vs daily_warn_threshold_usd):
#     ok (<$80) | info ($80–$100) | warn (≥$100) — NEVER critical
#   status: max severity of monthly_status and daily_status (daily capped at warn)
#   surface: true when monthly ≥60% OR daily spend ≥$80
#
# CONFIG MIGRATION
#   If quota-config.json has the legacy daily_cap_usd field (any value), this
#   script rewrites it to the new schema on first run:
#     - legacy daily_cap_usd: 3.33 (or similar small value) → monthly 1000, daily-warn 100
#     - legacy daily_cap_usd: user-set N → monthly 1000, daily-warn N (preserves intent)
#   Migration is logged to stderr and a migration_note field is added to the snapshot.
#
# EXIT STATUS
#   0  Success (observational — never non-zero on high spend).
#   2  Usage error.
#   5  Read/compute/write failure.
#
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

print_help() {
  sed -n '/^# PURPOSE$/,/^# DEPENDENCIES$/p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "quota-budget.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

MODE="check"
DATE_OVERRIDE=""
WRITE_STATE=1
CONFIG_CAP_ARGS=()
TAIL_N=20
SESSION_ID_OVERRIDE=""
ACK_FILE="${QUOTA_ACK_FILE:-$HOME/.claude/quota-ack.json}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --check) MODE="check"; shift ;;
    --week) MODE="week"; shift ;;
    --month) MODE="month"; shift ;;
    --config) MODE="config"; shift ;;
    --reset) MODE="reset"; shift ;;
    --config-cap)
      MODE="config-cap"
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        CONFIG_CAP_ARGS+=("$1")
        shift
      done
      ;;
    --ack) MODE="ack"; shift ;;
    --tail)
      MODE="tail"
      shift
      if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
        TAIL_N="$1"
        shift
      fi
      ;;
    --session)
      [[ $# -ge 2 ]] || die_usage "--session requires a value"
      SESSION_ID_OVERRIDE="$2"
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

# --- Config migration + read ---
# Migrate legacy daily_cap_usd to new schema if present. Returns the config
# path (possibly updated) and sets MIGRATION_NOTE.
MIGRATION_NOTE=""
if [[ -f "$CONFIG_PATH" ]]; then
  HAS_LEGACY="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        cfg = json.load(f)
    print('yes' if 'daily_cap_usd' in cfg else 'no')
except Exception:
    print('no')
" "$CONFIG_PATH" 2>/dev/null || echo "no")"

  if [[ "$HAS_LEGACY" == "yes" ]]; then
    MIGRATION_NOTE="$(python3 - "$CONFIG_PATH" <<'PY' 2>/dev/null || true
import json, sys, os
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)

legacy_cap = cfg.pop("daily_cap_usd", None)
if legacy_cap is None:
    sys.exit(0)

legacy_cap = float(legacy_cap)
# Determine mapping: tiny auto-default (<=5) -> standard defaults; user-set -> preserve as daily-warn
IS_STANDARD_DEFAULT = (abs(legacy_cap - 3.33) < 0.01 or legacy_cap <= 5.0)

if not cfg.get("monthly_cap_usd"):
    cfg["monthly_cap_usd"] = 1000
if not cfg.get("daily_warn_threshold_usd"):
    cfg["daily_warn_threshold_usd"] = 100 if IS_STANDARD_DEFAULT else float(legacy_cap)

# Normalize thresholds to new schema
old_th = cfg.get("thresholds", {})
if "monthly" not in old_th or "daily" not in old_th:
    monthly_th = {
        "info": old_th.get("info", 0.60),
        "warn": old_th.get("warn", 0.80),
        "critical": old_th.get("critical", 0.95),
    }
    cfg["thresholds"] = {
        "monthly": monthly_th,
        "daily": {"info": 80, "warn": 100}
    }

# Normalize stop_hook_threshold
old_sht = cfg.get("stop_hook_threshold")
if not isinstance(old_sht, dict):
    cfg["stop_hook_threshold"] = {
        "monthly_pct": float(old_sht) if old_sht is not None else 0.60,
        "daily_usd": 80
    }

tmp = path + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    note = "Migrated quota config to monthly+daily-warn shape"
    if IS_STANDARD_DEFAULT:
        note += f" (legacy daily_cap_usd {legacy_cap} was the auto-default; set monthly=1000, daily-warn=100)"
    else:
        note += f" (legacy daily_cap_usd {legacy_cap} preserved as daily_warn_threshold_usd)"
    print(note)
except Exception as e:
    try:
        os.unlink(tmp)
    except Exception:
        pass
    print(f"Migration warning: could not write updated config: {e}", file=__import__("sys").stderr)
PY
)"
    if [[ -n "$MIGRATION_NOTE" ]]; then
      echo "quota-budget.sh: $MIGRATION_NOTE" >&2
    fi
  fi
fi

# --- Read resolved config values ---
read_config() {
  # Prints: monthly_cap daily_warn monthly_info monthly_warn monthly_critical daily_info_usd daily_warn_usd stop_hook_monthly_pct stop_hook_daily_usd
  python3 - "$CONFIG_PATH" <<'PY' 2>/dev/null || echo "1000 100 0.60 0.80 0.95 80 100 0.60 80"
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
mc = float(cfg.get("monthly_cap_usd", 1000))
dw = float(cfg.get("daily_warn_threshold_usd", 100))
th = cfg.get("thresholds") or {}
mth = th.get("monthly") if isinstance(th.get("monthly"), dict) else {}
dth = th.get("daily") if isinstance(th.get("daily"), dict) else {}
sht = cfg.get("stop_hook_threshold") or {}
if not isinstance(sht, dict):
    sht = {"monthly_pct": float(sht), "daily_usd": 80}
print(
    mc,
    dw,
    float(mth.get("info", 0.60)),
    float(mth.get("warn", 0.80)),
    float(mth.get("critical", 0.95)),
    float(dth.get("info", 80)),
    float(dth.get("warn", 100)),
    float(sht.get("monthly_pct", 0.60)),
    float(sht.get("daily_usd", 80))
)
PY
}

# shellcheck disable=SC2034
read -r MONTHLY_CAP DAILY_WARN MONTHLY_INFO MONTHLY_WARN MONTHLY_CRIT DAILY_INFO_USD DAILY_WARN_USD STOP_HOOK_MONTHLY_PCT STOP_HOOK_DAILY_USD <<< "$(read_config)"

# --- atomic session-state write helper (jq + temp-file + mv, like greptile-budget.sh) ---
write_quota_daily() {
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

# --- --ack: acknowledge current severity for the rest of today's session ---
if [[ "$MODE" == "ack" ]]; then
  # Resolve session id: override > env > session-state.json
  SESSION_ID="${SESSION_ID_OVERRIDE:-${CLAUDE_SESSION_ID:-}}"
  if [[ -z "$SESSION_ID" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$STATE_FILE" ]]; then
    SESSION_ID="$(jq -r '.session_id // empty' "$STATE_FILE" 2>/dev/null || true)"
  fi
  if [[ -z "$SESSION_ID" ]]; then
    echo "quota-budget.sh: --ack requires a session id; set CLAUDE_SESSION_ID or use --session" >&2
    exit 2
  fi

  # Get current status by reusing --check --no-state (avoids duplicating aggregation logic)
  SNAP_ACK="$("$0" --check --no-state 2>/dev/null)" || true
  TODAY_ET="$(printf '%s' "${SNAP_ACK:-}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("date",""))' 2>/dev/null || TZ='America/New_York' date +%F 2>/dev/null || date +%F)"
  CURRENT_STATUS="$(printf '%s' "${SNAP_ACK:-}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status","warn"))' 2>/dev/null || echo "warn")"

  # Write ack file atomically
  python3 - "$ACK_FILE" "$SESSION_ID" "$TODAY_ET" "$CURRENT_STATUS" <<'PY' || { echo "quota-budget.sh: failed to write ack file" >&2; exit 5; }
import json, os, sys
path, session_id, today_et, current_status = sys.argv[1:5]
ack = {
    "session_id": session_id,
    "acked_date": today_et,
    "acked_at_severity": current_status,
    "acked_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
tmp = path + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(ack, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print(json.dumps({"acked": True, "session_id": session_id, "date": today_et,
                      "severity": current_status,
                      "message": f"Stop-hook quota line quieted for today ({today_et}) — will re-surface if severity escalates beyond '{current_status}'."}))
except Exception as e:
    try: os.unlink(tmp)
    except: pass
    print(f"quota-budget.sh: could not write ack file: {e}", file=sys.stderr)
    sys.exit(5)
PY
  exit 0
fi

# --- --tail: show last N ledger entries ---
if [[ "$MODE" == "tail" ]]; then
  python3 - "$USAGE_LOG" "$TAIL_N" "$CONFIG_PATH" <<'PY' || { echo "quota-budget.sh: failed to read ledger" >&2; exit 5; }
import json, os, sys
from datetime import datetime, timezone

log_path, tail_n_s, config_path = sys.argv[1], sys.argv[2], sys.argv[3]
tail_n = int(tail_n_s)

try:
    with open(config_path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
pricing = cfg.get("pricing") if isinstance(cfg.get("pricing"), dict) else {}
default_price = pricing.get("default") if isinstance(pricing.get("default"), dict) else     {"input": 15.0, "output": 75.0, "cache_write": 18.75, "cache_read": 1.5}

def num(v, fb):
    try: return float(v)
    except: return fb

def price_for(model):
    model = model or ""
    best, best_len = None, -1
    for k, v in pricing.items():
        if k in ("default", "_comment") or not isinstance(v, dict): continue
        if k in model and len(k) > best_len: best, best_len = k, len(k)
    chosen = pricing.get(best, default_price) if best else default_price
    return {k: num(chosen.get(k), num(default_price.get(k), 0.0)) for k in ("input","output","cache_write","cache_read")}

try:
    with open(log_path, encoding="utf-8") as f:
        lines = [l.rstrip("\n") for l in f if l.strip()]
except FileNotFoundError:
    print(f"Ledger is empty (no file at {log_path})")
    sys.exit(0)
except Exception as e:
    print(f"Error reading ledger: {e}", file=sys.stderr)
    sys.exit(5)

tail_lines = lines[-tail_n:] if len(lines) > tail_n else lines
if not tail_lines:
    print("Ledger is empty — no entries yet.")
    sys.exit(0)

rows = []
for line in tail_lines:
    parts = line.split("	")
    if len(parts) < 7:
        continue
    ts_raw, model = parts[0], parts[1]
    try:
        inp, out, cr, cw = int(parts[2]), int(parts[3]), int(parts[4]), int(parts[5])
    except ValueError:
        continue
    session_id = parts[6] if len(parts) > 6 else "?"
    p = price_for(model)
    cost = (inp * p["input"] + out * p["output"] + cr * p["cache_read"] + cw * p["cache_write"]) / 1_000_000.0

    # Parse timestamp for display
    try:
        s = ts_raw.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        ts_display = dt.strftime("%Y-%m-%d %H:%M:%SZ")
    except Exception:
        ts_display = ts_raw[:19]

    # Shorten model name for display
    model_short = model.replace("claude-", "").replace("-latest", "")[:24]
    # Shorten session id
    sess_short = session_id[:12] + "…" if len(session_id) > 12 else session_id

    rows.append((ts_display, model_short, cost, inp + out, sess_short))

if not rows:
    print("No valid entries in ledger tail.")
    sys.exit(0)

total_lines = len(lines)
shown = len(rows)
print(f"Last {shown} of {total_lines} ledger entries:")
print(f"{'Timestamp (UTC)':<22}  {'Model':<26}  {'Cost':>8}  {'Tokens':>8}  Session")
print("-" * 82)
total_cost = 0.0
for ts_display, model_short, cost, tokens, sess_short in rows:
    print(f"{ts_display:<22}  {model_short:<26}  ${cost:>7.4f}  {tokens:>8,}  {sess_short}")
    total_cost += cost
print("-" * 82)
print(f"{'Total':>51}  ${total_cost:>7.4f}")
PY
  exit 0
fi

# --- --config-cap: update config file ---
if [[ "$MODE" == "config-cap" ]]; then
  [[ ${#CONFIG_CAP_ARGS[@]} -gt 0 ]] || die_usage "--config-cap requires at least one argument (monthly=N or daily-warn=M)"
  python3 - "$CONFIG_PATH" "${CONFIG_CAP_ARGS[@]}" <<'PY' || { echo "quota-budget.sh: failed to update config" >&2; exit 5; }
import json, os, sys
path = sys.argv[1]
args = sys.argv[2:]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
for arg in args:
    if arg.startswith("monthly="):
        val = float(arg[len("monthly="):])
        cfg["monthly_cap_usd"] = val
    elif arg.startswith("daily-warn="):
        val = float(arg[len("daily-warn="):])
        cfg["daily_warn_threshold_usd"] = val
    else:
        print(f"quota-budget.sh: unknown --config-cap key: {arg} (use monthly=N or daily-warn=M)", file=sys.stderr)
        sys.exit(2)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print(json.dumps({"config_path": path,
                  "monthly_cap_usd": cfg.get("monthly_cap_usd"),
                  "daily_warn_threshold_usd": cfg.get("daily_warn_threshold_usd")}))
PY
  exit 0
fi

# --- --config: print resolved config ---
if [[ "$MODE" == "config" ]]; then
  python3 - "$CONFIG_PATH" <<'PY' || { echo "quota-budget.sh: failed to read config" >&2; exit 5; }
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
th = cfg.get("thresholds") or {}
mth = th.get("monthly") if isinstance(th.get("monthly"), dict) else {}
dth = th.get("daily") if isinstance(th.get("daily"), dict) else {}
sht = cfg.get("stop_hook_threshold") or {}
if not isinstance(sht, dict):
    sht = {"monthly_pct": float(sht), "daily_usd": 80}
out = {
    "config_path": path,
    "monthly_cap_usd": float(cfg.get("monthly_cap_usd", 1000)),
    "daily_warn_threshold_usd": float(cfg.get("daily_warn_threshold_usd", 100)),
    "currency": cfg.get("currency", "USD"),
    "thresholds": {
        "monthly": {
            "info": float(mth.get("info", 0.60)),
            "warn": float(mth.get("warn", 0.80)),
            "critical": float(mth.get("critical", 0.95)),
        },
        "daily": {
            "info_usd": float(dth.get("info", 80)),
            "warn_usd": float(dth.get("warn", 100)),
        },
    },
    "stop_hook_threshold": {
        "monthly_pct": float(sht.get("monthly_pct", 0.60)),
        "daily_usd": float(sht.get("daily_usd", 80)),
    },
    "pricing": {k: v for k, v in (cfg.get("pricing") or {}).items() if k != "_comment"},
}
print(json.dumps(out))
PY
  exit 0
fi

# --- --reset: zero today's cached counter ---
if [[ "$MODE" == "reset" ]]; then
  SNAPSHOT="$(python3 - "$MONTHLY_CAP" "$DAILY_WARN" <<'PY'
import json, sys
from datetime import datetime, timezone
monthly_cap = float(sys.argv[1])
daily_warn = float(sys.argv[2])
try:
    import zoneinfo
    now_et = datetime.now(zoneinfo.ZoneInfo("America/New_York"))
    today = now_et.date().isoformat()
    month = now_et.strftime("%Y-%m")
except Exception:
    now_et = datetime.now(timezone.utc)
    today = now_et.date().isoformat()
    month = now_et.strftime("%Y-%m")
print(json.dumps({
    "date": today, "month": month,
    "input_tokens": 0, "output_tokens": 0,
    "cache_read_tokens": 0, "cache_creation_tokens": 0,
    "estimated_usd": 0.0,
    "monthly_spend_usd": 0.0,
    "daily_warn_threshold_usd": daily_warn,
    "monthly_cap_usd": monthly_cap,
    "projected_eod_usd": 0.0,
    "projected_eom_usd": 0.0,
    "daily_status": "ok", "monthly_status": "ok", "status": "ok",
}))
PY
)"
  [[ "$WRITE_STATE" -eq 1 ]] && write_quota_daily "$SNAPSHOT"
  echo "$SNAPSHOT"
  exit 0
fi

# --- --check / --week / --month: aggregate the ledger ---
SNAPSHOT="$(python3 - "$CONFIG_PATH" "$USAGE_LOG" "$MONTHLY_CAP" "$DAILY_WARN" \
    "$MONTHLY_INFO" "$MONTHLY_WARN" "$MONTHLY_CRIT" \
    "$DAILY_INFO_USD" "$DAILY_WARN_USD" \
    "$MODE" "$DATE_OVERRIDE" "${MIGRATION_NOTE:-}" <<'PY'
import json, os, sys
from datetime import datetime, timezone, timedelta
import calendar

(config_path, log_path, monthly_cap_s, daily_warn_s,
 monthly_info_s, monthly_warn_s, monthly_crit_s,
 daily_info_usd_s, daily_warn_usd_s,
 mode, date_override, migration_note) = sys.argv[1:13]

try:
    monthly_cap = float(monthly_cap_s)
    daily_warn_threshold = float(daily_warn_s)
    MONTHLY_INFO = float(monthly_info_s)
    MONTHLY_WARN = float(monthly_warn_s)
    MONTHLY_CRIT = float(monthly_crit_s)
    DAILY_INFO_USD = float(daily_info_usd_s)
    DAILY_WARN_USD = float(daily_warn_usd_s)
except Exception:
    monthly_cap = 1000.0; daily_warn_threshold = 100.0
    MONTHLY_INFO = 0.60; MONTHLY_WARN = 0.80; MONTHLY_CRIT = 0.95
    DAILY_INFO_USD = 80.0; DAILY_WARN_USD = 100.0

try:
    with open(config_path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
pricing = cfg.get("pricing") if isinstance(cfg.get("pricing"), dict) else {}
default_price = pricing.get("default") if isinstance(pricing.get("default"), dict) else \
    {"input": 15.0, "output": 75.0, "cache_write": 18.75, "cache_read": 1.5}

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
current_month_et = now_et.strftime("%Y-%m")

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
        return None, None
    et = (dt.astimezone(ET) if ET else dt)
    return et.date().isoformat(), et.strftime("%Y-%m")

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
            d, _m = et_date_of(parts[0])
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

def classify_monthly(projected_pct):
    if projected_pct >= MONTHLY_CRIT:
        return "critical"
    if projected_pct >= MONTHLY_WARN:
        return "warn"
    if projected_pct >= MONTHLY_INFO:
        return "info"
    return "ok"

def classify_daily(spend_usd, warn_usd=None, info_usd=None):
    """Daily signal: capped at warn — never critical.
    Thresholds derived from daily_warn_threshold so --config-cap daily-warn=N
    stays consistent with daily_status, daily_spend_pct_of_warn, and the stop hook."""
    w = warn_usd if warn_usd is not None else DAILY_WARN_USD
    i = info_usd if info_usd is not None else DAILY_INFO_USD
    if spend_usd >= w:
        return "warn"
    if spend_usd >= i:
        return "info"
    return "ok"

def severity_max(a, b):
    order = {"ok": 0, "info": 1, "warn": 2, "critical": 3}
    return a if order.get(a, 0) >= order.get(b, 0) else b

def month_spend_usd(month_str, cutoff_date=None):
    """Sum all day entries for the given YYYY-MM month prefix.
    cutoff_date (YYYY-MM-DD): if provided, only sum days <= cutoff_date so that
    --check --date YYYY-MM-DD past-day queries don't include later days' spend."""
    total = 0.0
    for d, e in days.items():
        if d.startswith(month_str):
            if cutoff_date is None or d <= cutoff_date:
                total += e["estimated_usd"]
    return total

def days_in_month(year, month):
    return calendar.monthrange(year, month)[1]

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
    month_spend = month_spend_usd(current_month_et)
    print(json.dumps({
        "mode": "week", "days": out_days,
        "total_usd": round(total, 4), "total_responses": total_resp,
        "by_model": wm_list,
        "monthly_cap_usd": round(monthly_cap, 4),
        "daily_warn_threshold_usd": round(daily_warn_threshold, 4),
        "month": current_month_et,
        "month_spend_usd": round(month_spend, 4),
        "checked_at": now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "today": today_et,
    }))
    sys.exit(0)

if mode == "month":
    year_i = now_et.year; month_i = now_et.month
    dim = days_in_month(year_i, month_i)
    out_days = []
    month_total = 0.0; month_resp = 0
    month_models = {}
    for day_i in range(1, dim + 1):
        d = f"{year_i:04d}-{month_i:02d}-{day_i:02d}"
        e = days.get(d, blank_day(d))
        row = {
            "date": d,
            "estimated_usd": round(e["estimated_usd"], 4),
            "input_tokens": e["input_tokens"], "output_tokens": e["output_tokens"],
            "cache_read_tokens": e["cache_read_tokens"], "cache_creation_tokens": e["cache_creation_tokens"],
            "responses": e["responses"],
        }
        out_days.append(row)
        month_total += e["estimated_usd"]; month_resp += e["responses"]
        for mk, mv in e["by_model"].items():
            mm = month_models.setdefault(mk, {"model": mk, "estimated_usd": 0.0})
            mm["estimated_usd"] += mv["estimated_usd"]
    mm_list = sorted(month_models.values(), key=lambda m: m["estimated_usd"], reverse=True)
    for m in mm_list:
        m["estimated_usd"] = round(m["estimated_usd"], 4)
    print(json.dumps({
        "mode": "month", "month": current_month_et, "days": out_days,
        "total_usd": round(month_total, 4), "total_responses": month_resp,
        "by_model": mm_list,
        "monthly_cap_usd": round(monthly_cap, 4),
        "daily_warn_threshold_usd": round(daily_warn_threshold, 4),
        "checked_at": now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }))
    sys.exit(0)

# --- check ---
target = date_override or today_et
is_today = (target == today_et)
e = days.get(target, blank_day(target))
today_spend = e["estimated_usd"]

# Monthly spend: sum all days in the same ET month as 'target', capped at target date
# so --check --date YYYY-MM-DD past-day queries don't include later days' spend.
target_month = target[:7]  # YYYY-MM
cutoff = target if not is_today else None
monthly_spend = month_spend_usd(target_month, cutoff_date=cutoff)

if is_today:
    midnight = now_et.replace(hour=0, minute=0, second=0, microsecond=0)
    day_fraction = max(min((now_et - midnight).total_seconds() / 86400.0, 1.0), 0.0)

    # Month fraction: day_of_month / days_in_month
    year_i = now_et.year; month_i = now_et.month
    dim = days_in_month(year_i, month_i)
    # Use current day number (1-based) as numerator, treating 'now' as partly through day N
    day_of_month_frac = (now_et.day - 1 + day_fraction) / dim
    month_fraction = max(min(day_of_month_frac, 1.0), 0.0)
else:
    day_fraction = 1.0
    # For past-day check, month fraction = 1
    month_fraction = 1.0

# Daily projection: floor denominator at 1 hour to prevent explosion near midnight
MIN_DAY_FRAC = 1.0 / 24.0
proj_day_frac = max(day_fraction, MIN_DAY_FRAC)
projected_eod = today_spend / proj_day_frac if proj_day_frac > 0 else today_spend

# Monthly projection: floor at 1 day / days_in_month to prevent explosion at month start
if is_today:
    year_i2 = now_et.year; month_i2 = now_et.month
    dim2 = days_in_month(year_i2, month_i2)
    MIN_MONTH_FRAC = 1.0 / dim2
else:
    MIN_MONTH_FRAC = 1.0 / 30.0
proj_month_frac = max(month_fraction, MIN_MONTH_FRAC)
projected_eom = monthly_spend / proj_month_frac if proj_month_frac > 0 else monthly_spend

# Classify
monthly_spend_pct = (monthly_spend / monthly_cap) if monthly_cap > 0 else 0.0
projected_eom_pct = (projected_eom / monthly_cap) if monthly_cap > 0 else 0.0
daily_spend_pct_of_warn = (today_spend / daily_warn_threshold) if daily_warn_threshold > 0 else 0.0

monthly_status = classify_monthly(projected_eom_pct)
# Derive daily thresholds from daily_warn_threshold so --config-cap daily-warn=N
# stays consistent: info = 80% of warn level, warn = daily_warn_threshold itself.
daily_info_threshold = min(DAILY_INFO_USD, daily_warn_threshold * 0.80)
daily_status = classify_daily(today_spend, warn_usd=daily_warn_threshold, info_usd=daily_info_threshold)
# Combined status: max severity (daily capped at warn — never escalates to critical)
status = severity_max(monthly_status, daily_status)

# Surface: emit when monthly >=60% OR daily >= daily_info_threshold
# (daily_info_threshold is 80% of daily_warn_threshold, consistent with classify_daily)
surface = (projected_eom_pct >= MONTHLY_INFO) or (today_spend >= daily_info_threshold)

out = {
    "date": target,
    "month": target_month,
    "input_tokens": e["input_tokens"], "output_tokens": e["output_tokens"],
    "cache_read_tokens": e["cache_read_tokens"], "cache_creation_tokens": e["cache_creation_tokens"],
    "estimated_usd": round(today_spend, 4),
    "monthly_spend_usd": round(monthly_spend, 4),
    "daily_warn_threshold_usd": round(daily_warn_threshold, 4),
    "monthly_cap_usd": round(monthly_cap, 4),
    "daily_spend_pct_of_warn": round(daily_spend_pct_of_warn, 4),
    "monthly_spend_pct": round(monthly_spend_pct, 4),
    "responses": e["responses"],
    "fraction_of_day_elapsed": round(day_fraction, 4),
    "fraction_of_month_elapsed": round(month_fraction, 4),
    "projected_eod_usd": round(projected_eod, 4),
    "projected_eom_usd": round(projected_eom, 4),
    "projected_eom_pct": round(projected_eom_pct, 4),
    "daily_status": daily_status,
    "monthly_status": monthly_status,
    "status": status,
    "surface": surface,
    "by_model": finalize_models(e["by_model"]),
    "is_today": is_today,
    "checked_at": now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if migration_note:
    out["migration_note"] = migration_note
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
  if [[ "$MODE" == "week" || "$MODE" == "month" ]]; then
    TODAY_SNAP="$("$0" --check --no-state 2>/dev/null || true)"
  else
    TODAY_SNAP="$SNAPSHOT"
  fi
  if [[ -n "${TODAY_SNAP:-}" ]] && printf '%s' "$TODAY_SNAP" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    QD="$(printf '%s' "$TODAY_SNAP" | python3 -c 'import json,sys
s=json.load(sys.stdin)
print(json.dumps({
 "date": s["date"],
 "month": s.get("month", s["date"][:7]),
 "input_tokens": s["input_tokens"],
 "output_tokens": s["output_tokens"],
 "cache_read_tokens": s["cache_read_tokens"],
 "cache_creation_tokens": s["cache_creation_tokens"],
 "estimated_usd": s["estimated_usd"],
 "monthly_spend_usd": s.get("monthly_spend_usd", s["estimated_usd"]),
 "monthly_cap_usd": s.get("monthly_cap_usd", 1000),
 "daily_warn_threshold_usd": s.get("daily_warn_threshold_usd", 100),
 "projected_eod_usd": s.get("projected_eod_usd", s["estimated_usd"]),
 "projected_eom_usd": s.get("projected_eom_usd", s.get("monthly_spend_usd", s["estimated_usd"])),
 "daily_status": s.get("daily_status", "ok"),
 "monthly_status": s.get("monthly_status", "ok"),
 "status": s.get("status", "ok"),
}))' 2>/dev/null || true)"
    [[ -n "$QD" ]] && write_quota_daily "$QD"
  fi
fi

echo "$SNAPSHOT"
exit 0
