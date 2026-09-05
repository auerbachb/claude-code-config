#!/usr/bin/env bash
# skill-usage-merge.sh — Merge another copy of the skill-usage telemetry into
# catalog: skills-telemetry — Merge another machine's skill-usage telemetry into the live log files
# the live files (~/.claude/skill-usage.log + ~/.claude/skill-usage.csv).
#
# PURPOSE (issue #572):
#   The telemetry written by skill-usage-tracker.sh lives only on the machine
#   that wrote it. This script is the merge primitive for both recovery paths:
#     - Machine move: merge the OLD machine's raw files into the new machine's
#       live files (disjoint histories — default --csv-counts sum).
#     - Snapshot restore: merge the skill-telemetry branch snapshot back into
#       the live files (overlapping histories — --csv-counts recompute, used
#       by skill-usage-snapshot.sh --restore; idempotent).
#
# USAGE:
#   skill-usage-merge.sh [--log <other.log>] [--csv <other.csv>]
#                        [--csv-counts sum|recompute] [--dry-run]
#   skill-usage-merge.sh --help
#
#   At least one of --log / --csv is required.
#
# SEMANTICS:
#   Log  — line-level union of live + other, exact-line dedupe, chronological
#          order (lines start with an ISO8601Z timestamp, so a plain lexical
#          sort IS chronological; same-timestamp lines tie-break on the rest
#          of the line, deterministically). Malformed non-empty lines are
#          preserved — union means never dropping data. Known limit of the
#          AC-specified dedupe: two REAL events from the same session, same
#          skill, and same second produce identical lines and collapse to
#          one — indistinguishable from a cross-copy duplicate by design.
#   CSV  — row union keyed on skill_name (header preserved; duplicate rows
#          for one skill are folded with the same rules):
#            use_count : sum        (default — correct for disjoint machine
#                                    histories, per issue #572 AC)
#                        recompute  (max of each CSV's own count and the
#                                    merged-log line count — safe under
#                                    overlap, hence idempotent; the restore
#                                    path always uses this. max, not
#                                    log-only, so a CSV-only baseline such
#                                    as the #431 fallback — counts with no
#                                    log lines behind them — survives a
#                                    restore instead of being zeroed)
#            last_used : max — a real date beats "never". Recompute also
#                        considers the merged log's last entry (UTC date).
#            start_date: min. Recompute also considers a skill's first log
#                        appearance (UTC date) — this is what lets a fresh
#                        machine reconstruct rows for skills the seed CSV
#                        never listed.
#   Dates: the tracker stamps last_used with the ET calendar date; log-derived
#          dates (recompute mode) use the UTC date of the log timestamp. The
#          two can differ by one day near midnight — acceptable for telemetry.
#
# SAFETY:
#   - Live files are backed up to <file>.bak.<UTC-ts> (a .N suffix is added
#     rather than ever overwriting an existing backup) before any write.
#   - Live-file READS and all mutations run under the same fcntl-flock
#     sidecar lock the tracker uses (~/.claude/skill-usage.csv.lock) — the
#     lock is taken before reading so a tracker CSV increment cannot land
#     between read and write and be overwritten. Writes are atomic
#     (tmp + os.replace). Dry-run is read-only and lock-free.
#   - KNOWN RACE: the tracker's log append (>>) is NOT under that lock, so a
#     merge that rewrites the log can lose a log line appended in the same
#     millisecond. Merges are rare and manual — run them when no active
#     session is mid-Skill-invocation.
#
# EXIT STATUS:
#   0  merge complete (or --dry-run report printed)
#   2  usage error
#   3  environment error (missing input file, no python3)
#   4  merge failure (lock unavailable, write failed)
#   70  --help header extraction produced no output (internal defect).

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

usage_error() {
  echo "skill-usage-merge.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

OTHER_LOG=""
OTHER_CSV=""
CSV_COUNTS="sum"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --log)
      [[ $# -ge 2 ]] || usage_error "--log requires a path"
      OTHER_LOG="$2"
      shift 2
      ;;
    --csv)
      [[ $# -ge 2 ]] || usage_error "--csv requires a path"
      OTHER_CSV="$2"
      shift 2
      ;;
    --csv-counts)
      [[ $# -ge 2 ]] || usage_error "--csv-counts requires sum or recompute"
      CSV_COUNTS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

if [[ -z "$OTHER_LOG" && -z "$OTHER_CSV" ]]; then
  usage_error "nothing to merge — pass --log and/or --csv"
fi
if [[ "$CSV_COUNTS" != "sum" && "$CSV_COUNTS" != "recompute" ]]; then
  usage_error "--csv-counts must be sum or recompute (got: $CSV_COUNTS)"
fi
if [[ -n "$OTHER_LOG" && ! -f "$OTHER_LOG" ]]; then
  echo "error: --log file not found: $OTHER_LOG" >&2
  exit 3
fi
if [[ -n "$OTHER_CSV" && ! -f "$OTHER_CSV" ]]; then
  echo "error: --csv file not found: $OTHER_CSV" >&2
  exit 3
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not found" >&2
  exit 3
fi

LIVE_LOG="$HOME/.claude/skill-usage.log"
LIVE_CSV="$HOME/.claude/skill-usage.csv"
mkdir -p "$HOME/.claude"

# Python core mirrors skill-usage-tracker.sh: fcntl flock on the CSV sidecar
# lock, atomic tmp + os.replace writes. Python 3.9-compatible (macOS CLT).
python3 - "$LIVE_LOG" "$LIVE_CSV" "$OTHER_LOG" "$OTHER_CSV" "$CSV_COUNTS" "$DRY_RUN" <<'PY'
import csv
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone

live_log, live_csv, other_log, other_csv, csv_counts, dry_run_s = sys.argv[1:7]
dry_run = dry_run_s == "1"
merge_log = bool(other_log)
merge_csv = bool(other_csv)

HEADER = ["skill_name", "start_date", "use_count", "last_used"]


def fail(msg):
    print("error: %s" % msg, file=sys.stderr)
    sys.exit(4)


def read_lines(path):
    """Non-empty lines of a log file, or [] when the file is absent."""
    if not path or not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return [ln.rstrip("\n") for ln in fh if ln.strip()]


def read_csv_rows(path):
    """(header, rows) of a CSV, or (None, []) when absent/empty."""
    if not path or not os.path.exists(path):
        return None, []
    with open(path, "r", newline="", encoding="utf-8", errors="replace") as fh:
        rows = list(csv.reader(fh))
    if not rows:
        return None, []
    return rows[0], rows[1:]


def parse_date(s):
    """YYYY-MM-DD -> date, else None ('never', blank, malformed)."""
    try:
        return datetime.strptime((s or "").strip(), "%Y-%m-%d").date()
    except ValueError:
        return None


def parse_count(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return 0


def log_utc_date(ts_raw):
    """ISO8601 log timestamp -> UTC date, else None."""
    ts = (ts_raw or "").strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(ts)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).date()


def atomic_write_text(path, text):
    dir_ = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".skill-usage-merge.", dir=dir_)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def atomic_write_csv(path, header, data):
    dir_ = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".skill-usage-merge.", dir=dir_)
    try:
        with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(header)
            w.writerows(data)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def backup(path):
    """Copy path to path.bak.<UTC-ts>[.N]; never overwrite a prior backup."""
    if not os.path.exists(path):
        return None
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = "%s.bak.%s" % (path, stamp)
    n = 0
    while os.path.exists(dest):
        n += 1
        dest = "%s.bak.%s.%d" % (path, stamp, n)
    shutil.copy2(path, dest)
    return dest


# ---- lock BEFORE reading live files ------------------------------------------
# The tracker mutates the CSV under this same lock. Reading live files before
# acquiring it would let a tracker increment land between read and write and
# be overwritten by stale merged data. Dry-run stays lock-free: it is
# read-only, so the worst case is a report computed from a mid-update
# snapshot — nothing is written.
lock_path = live_csv + ".lock"
lock_fd = None
try:
    import fcntl
except ImportError:
    fcntl = None  # mirrors the tracker: proceed unlocked on such platforms

if not dry_run and fcntl is not None:
    try:
        lock_fd = open(lock_path, "w")
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
    except OSError:
        fail("could not acquire %s — is another merge or tracker write stuck?" % lock_path)

# ---- compute merged log -----------------------------------------------------
live_lines = read_lines(live_log)
other_lines = read_lines(other_log) if merge_log else []
if merge_log:
    union = set(live_lines) | set(other_lines)
    # Lines start with an ISO8601Z timestamp, so sorting whole lines is
    # chronological; the rest of the line is a deterministic tie-break.
    merged_lines = sorted(union)
    dupes = len(live_lines) + len(other_lines) - len(merged_lines)
else:
    merged_lines = live_lines
    dupes = 0

# ---- compute merged CSV -----------------------------------------------------
merged_header = None
merged_rows = []
csv_changes = []
if merge_csv:
    live_header, live_rows = read_csv_rows(live_csv)
    other_header, other_rows = read_csv_rows(other_csv)
    merged_header = live_header or other_header or HEADER

    # Fold rows keyed on skill_name; duplicates within one file fold by the
    # same sum/max/min rules so the result is deterministic.
    order = []          # first-seen order: live rows, then other-only rows
    merged = {}         # skill -> {count, last_used(date|None), start(date|None)}

    def fold(rows, source):
        for row in rows:
            if len(row) < 4 or not row[0].strip():
                continue  # malformed CSV row — nothing usable to merge
            skill = row[0].strip()
            cnt = parse_count(row[2])
            last = parse_date(row[3])
            start = parse_date(row[1])
            if skill not in merged:
                merged[skill] = {"count": 0, "last": None, "start": None,
                                 "live_count": 0, "other_count": 0}
                order.append(skill)
            m = merged[skill]
            m["count"] += cnt
            m[source + "_count"] += cnt
            if last is not None and (m["last"] is None or last > m["last"]):
                m["last"] = last
            if start is not None and (m["start"] is None or start < m["start"]):
                m["start"] = start

    fold(live_rows, "live")
    fold(other_rows, "other")

    if csv_counts == "recompute":
        # use_count = max(live CSV count, other CSV count, merged-log count).
        # Each event is counted at most once regardless of history overlap
        # (idempotent), and a CSV-only baseline with no log lines behind it
        # (e.g. the #431 fallback, or increments whose unlocked log append
        # failed) is preserved instead of being zeroed by the log count.
        log_counts = {}
        log_first = {}
        log_last = {}
        for ln in merged_lines:
            parts = ln.split("\t")
            if len(parts) < 2 or not parts[1].strip():
                continue
            skill = parts[1].strip()
            log_counts[skill] = log_counts.get(skill, 0) + 1
            d = log_utc_date(parts[0])
            if d is not None:
                if skill not in log_first or d < log_first[skill]:
                    log_first[skill] = d
                if skill not in log_last or d > log_last[skill]:
                    log_last[skill] = d
        for skill in log_counts:
            if skill not in merged:
                merged[skill] = {"count": 0, "last": None, "start": None,
                                 "live_count": 0, "other_count": 0}
                order.append(skill)
        for skill, m in merged.items():
            m["count"] = max(m["live_count"], m["other_count"],
                             log_counts.get(skill, 0))
            log_last_d = log_last.get(skill)
            if log_last_d is not None and (m["last"] is None or log_last_d > m["last"]):
                m["last"] = log_last_d
            if skill in log_first and (m["start"] is None or log_first[skill] < m["start"]):
                m["start"] = log_first[skill]

    for skill in order:
        m = merged[skill]
        start_s = m["start"].isoformat() if m["start"] else "never"
        last_s = m["last"].isoformat() if m["last"] else "never"
        merged_rows.append([skill, start_s, str(m["count"]), last_s])
        if csv_counts == "sum":
            detail = "%d + %d -> %d" % (m["live_count"], m["other_count"], m["count"])
        else:
            detail = "max(csv %d, csv %d, log) -> %d" % (
                m["live_count"], m["other_count"], m["count"])
        csv_changes.append("  %-28s use_count %s, last_used %s, start_date %s"
                           % (skill, detail, last_s, start_s))

# ---- report -----------------------------------------------------------------
if merge_log:
    print("log: %d live + %d other -> %d merged (%d duplicate line(s) removed)"
          % (len(live_lines), len(other_lines), len(merged_lines), dupes))
if merge_csv:
    print("csv: %d skill row(s) after merge (--csv-counts %s)"
          % (len(merged_rows), csv_counts))
    for line in csv_changes:
        print(line)

if dry_run:
    print("dry-run: no files written, no backups taken")
    sys.exit(0)

# ---- write (still under the lock acquired before the reads) -------------------
try:
    backups = []
    for p in ([live_log] if merge_log else []) + ([live_csv] if merge_csv else []):
        b = backup(p)
        if b:
            backups.append(b)
    for b in backups:
        print("backup: %s" % b)

    if merge_log:
        atomic_write_text(live_log,
                          ("\n".join(merged_lines) + "\n") if merged_lines else "")
        print("wrote: %s (%d line(s))" % (live_log, len(merged_lines)))
    if merge_csv:
        atomic_write_csv(live_csv, merged_header, merged_rows)
        print("wrote: %s (%d row(s))" % (live_csv, len(merged_rows)))
finally:
    if lock_fd is not None:
        try:
            lock_fd.close()
        except OSError:
            pass
PY
