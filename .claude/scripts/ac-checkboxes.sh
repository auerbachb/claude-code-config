#!/usr/bin/env bash
# ac-checkboxes.sh — Test-Plan checkbox helper (extract / tick / all-pass).
#
# Parse Markdown checkboxes from the PR body's `## Test plan` section (case-
# insensitive match; also accepts `## Test Plan` and `## Acceptance Criteria`),
# then either emit them as JSON or flip `- [ ]` to `- [x]` via
# `gh pr edit --body-file` (using --body-file, not --body, preserves the body's
# exact whitespace and trailing-newline profile).
#
# Implements the AC-verification contract from .claude/rules/cr-merge-gate.md
# Step 2. Call sites: /check-acceptance-criteria, /merge, /wrap, /continue,
# /subagent, phase-c-merger.
#
# Usage:
#   ac-checkboxes.sh <pr_number> --extract
#   ac-checkboxes.sh <pr_number> --tick <indexes-or-regex>
#   ac-checkboxes.sh <pr_number> --all-pass
#   ac-checkboxes.sh --help
#
# Modes (exactly one required):
#   --extract            Print JSON array on stdout:
#                          [{"index": 0, "checked": false, "text": "..."}, ...]
#                        Indexes are zero-based, in document order.
#   --tick <spec>        Tick checkboxes matching <spec>, where <spec> is either:
#                          - a comma-separated list of zero-based indexes
#                            (e.g. "0,2,3")
#                          - a Python regular expression applied to each item's
#                            text (e.g. "script exists" or "--all-pass|--tick").
#                            Evaluated via Python's `re` module — NOT POSIX ERE.
#                        Only unchecked items can be ticked; already-checked items
#                        in the match set are silently skipped (idempotent).
#   --all-pass           Tick every unchecked item in the Test Plan section.
#
# Section detection:
#   Matches the first heading line (case-insensitive) of:
#     ## Test plan
#     ## Test Plan
#     ## Acceptance Criteria
#   Content continues until the next `## ` heading or EOF.
#
# Exit codes:
#   0  OK (JSON printed for --extract; body updated for --tick/--all-pass)
#   1  No Test Plan section found, OR the section exists but contains no
#      checkbox items. Both cases mean "no acceptance criteria to verify" —
#      callers MUST treat this as a blocking PR-body violation (see CLAUDE.md:
#      every PR must include a Test Plan with checkboxes).
#   2  Usage error (or internal script error — e.g., python parse failure,
#      missing prerequisite)
#   3  PR not found (or closed/merged — `gh pr view` failed)
#   4  `gh pr edit --body-file` failed (only reachable from --tick/--all-pass)
#
# Notes:
#   - `gh pr edit --body-file` replaces the entire body; this script fetches
#     first, mutates in memory, and writes back via --body-file to preserve
#     all non-Test-Plan content verbatim (trailing newlines included).
#   - --tick and --all-pass are no-ops (exit 0) when nothing needs ticking.
#   - For --tick with no matches, exit is 0 and a note is printed to stderr.

# Note: -e is intentionally omitted. Errors from `gh`, python, and jq-like calls
# are handled manually so the exit-code contract (0/1/2/3/4) can be enforced
# precisely — a bare `-e` would let any downstream failure surface as exit 1,
# colliding with the "no Test Plan section" meaning.
set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
PR_NUMBER=""
MODE=""
TICK_SPEC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --extract)
      if [[ -n "$MODE" ]]; then
        echo "ERROR: --extract conflicts with --$MODE (pick one mode)" >&2
        exit 2
      fi
      MODE="extract"
      shift
      ;;
    --all-pass)
      if [[ -n "$MODE" ]]; then
        echo "ERROR: --all-pass conflicts with --$MODE (pick one mode)" >&2
        exit 2
      fi
      MODE="all-pass"
      shift
      ;;
    --tick)
      if [[ -n "$MODE" ]]; then
        echo "ERROR: --tick conflicts with --$MODE (pick one mode)" >&2
        exit 2
      fi
      MODE="tick"
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --tick requires a value (indexes or regex)" >&2
        exit 2
      fi
      TICK_SPEC="$2"
      if [[ -z "$TICK_SPEC" ]]; then
        echo "ERROR: --tick value cannot be empty" >&2
        exit 2
      fi
      shift 2
      ;;
    --)
      shift
      ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        echo "ERROR: unexpected argument: $1 (PR number already set to $PR_NUMBER)" >&2
        exit 2
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  echo "ERROR: <pr_number> is required" >&2
  print_usage >&2
  exit 2
fi

if ! [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: <pr_number> must be a positive integer (got: $PR_NUMBER)" >&2
  exit 2
fi

if [[ -z "$MODE" ]]; then
  echo "ERROR: one of --extract, --tick, --all-pass is required" >&2
  print_usage >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found on PATH" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Fetch PR body
# ---------------------------------------------------------------------------
TMPDIR_AC=$(mktemp -d) || TMPDIR_AC=""
if [[ -z "$TMPDIR_AC" ]] || [[ ! -d "$TMPDIR_AC" ]] || [[ ! -w "$TMPDIR_AC" ]]; then
  echo "ERROR: failed to create temporary directory" >&2
  exit 2
fi
# Only install the cleanup trap after validation — with `set -e` off, a failed
# mktemp would otherwise leave TMPDIR_AC empty and trap `rm -rf ""` as a no-op
# while the script continued writing to absolute paths like `/body.json`.
trap 'rm -rf "$TMPDIR_AC"' EXIT

BODY_ERR_FILE="$TMPDIR_AC/body-stderr"
BODY_JSON_FILE="$TMPDIR_AC/body.json"
# Stream gh output to a file (not command substitution) so we don't strip trailing
# newlines from the PR body. Command substitution strips trailing `\n`, which would
# otherwise silently mutate the body on every `--tick`/`--all-pass` write-back.
if ! gh pr view "$PR_NUMBER" --json body >"$BODY_JSON_FILE" 2>"$BODY_ERR_FILE"; then
  BODY_ERR=$(cat "$BODY_ERR_FILE")
  if printf '%s' "$BODY_ERR" | grep -qiE 'could not resolve|not found|no pull request'; then
    echo "ERROR: PR #$PR_NUMBER not found" >&2
    exit 3
  fi
  echo "ERROR: gh pr view failed:" >&2
  printf '%s\n' "$BODY_ERR" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Delegate parsing + mutation to Python (multi-line text + JSON is painful in
# pure bash/jq/awk). Python 3 is assumed available — same assumption as cr-plan.sh.
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found on PATH" >&2
  exit 2
fi

# Extract .body from the JSON via Python so trailing newlines survive. `jq -r`
# strips a single trailing newline; Python's json.load + file write does not.
# Guard explicitly — with `set -e` disabled, a silent failure here would
# cascade into a misleading "python parsing failed" downstream.
BODY_FILE="$TMPDIR_AC/body.md"
BODY_EXTRACT_ERR="$TMPDIR_AC/body-extract-err"
python3 - "$BODY_JSON_FILE" "$BODY_FILE" <<'PY' 2>"$BODY_EXTRACT_ERR"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as src:
    body = (json.load(src).get("body") or "")
with open(sys.argv[2], "w", encoding="utf-8", newline="") as dst:
    dst.write(body)
PY
BODY_EXTRACT_STATUS=$?
if [[ $BODY_EXTRACT_STATUS -ne 0 ]] || [[ ! -f "$BODY_FILE" ]]; then
  echo "ERROR: failed to extract PR body from JSON (exit $BODY_EXTRACT_STATUS):" >&2
  cat "$BODY_EXTRACT_ERR" >&2
  exit 2
fi

PY_OUT="$TMPDIR_AC/py-out"
PY_ERR="$TMPDIR_AC/py-err"

python3 - "$MODE" "$TICK_SPEC" "$BODY_FILE" "$PY_OUT" <<'PY' 2>"$PY_ERR"
import json
import os
import re
import sys

mode = sys.argv[1]
tick_spec = sys.argv[2]
body_path = sys.argv[3]
out_path = sys.argv[4]

with open(body_path, "r", encoding="utf-8") as fh:
    body = fh.read()

lines = body.splitlines(keepends=True)

# Section detection. Match the first heading line (level 2) whose text is
# "test plan" or "acceptance criteria" (case-insensitive). Content runs until
# the next `## ` heading or EOF.
# Anchor the section name with \s*$ (not \b) so "## Test plan notes" does not
# match. Only exact "## Test plan" / "## Test Plan" / "## Acceptance Criteria"
# (optionally followed by trailing whitespace) select the section.
SECTION_RE = re.compile(r"^\s*##\s+(test\s+plan|acceptance\s+criteria)\s*$", re.IGNORECASE)
HEADING_RE = re.compile(r"^\s*##\s+")
CHECKBOX_RE = re.compile(r"^(\s*-\s*\[)( |x|X)(\]\s*)(.*?)(\s*)$")

section_start = None  # index of first line *after* the section heading
section_end = None    # exclusive end (index of next heading or len(lines))

for i, line in enumerate(lines):
    if section_start is None and SECTION_RE.match(line):
        section_start = i + 1
        continue
    if section_start is not None and HEADING_RE.match(line):
        section_end = i
        break

if section_start is None:
    # No section found — exit 1 handled by shell wrapper via sentinel file.
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"error": "no_section"}, fh)
    sys.exit(0)

if section_end is None:
    section_end = len(lines)

# Collect checkbox items in document order.
items = []  # list of (line_index, checked_bool, text)
for idx in range(section_start, section_end):
    m = CHECKBOX_RE.match(lines[idx])
    if not m:
        continue
    checked = m.group(2).lower() == "x"
    text = m.group(4).strip()
    items.append((idx, checked, text))

if not items:
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"error": "no_checkboxes"}, fh)
    sys.exit(0)

if mode == "extract":
    payload = [
        {"index": i, "checked": checked, "text": text}
        for i, (_, checked, text) in enumerate(items)
    ]
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"result": "extracted", "items": payload}, fh)
    sys.exit(0)

# --tick or --all-pass: identify which indexes to flip.
target_indexes = set()

if mode == "all-pass":
    for i, (_, checked, _) in enumerate(items):
        if not checked:
            target_indexes.add(i)
elif mode == "tick":
    # Disambiguate: pure comma-separated integers → indexes; else → regex.
    if re.fullmatch(r"\s*\d+(\s*,\s*\d+)*\s*", tick_spec):
        for tok in tick_spec.split(","):
            tok = tok.strip()
            if not tok:
                continue
            n = int(tok)
            if 0 <= n < len(items):
                if not items[n][1]:
                    target_indexes.add(n)
            else:
                # Out-of-range index: warn but continue. Partial-match semantics
                # match the regex case; strict-fail would be worse UX when a
                # caller passes stale indexes.
                print(f"WARNING: index {n} out of range (0..{len(items)-1})", file=sys.stderr)
    else:
        try:
            pattern = re.compile(tick_spec)
        except re.error as e:
            print(f"ERROR: invalid regex '{tick_spec}': {e}", file=sys.stderr)
            sys.exit(2)
        for i, (_, checked, text) in enumerate(items):
            if checked:
                continue
            if pattern.search(text):
                target_indexes.add(i)
else:
    print(f"ERROR: unknown mode '{mode}'", file=sys.stderr)
    sys.exit(2)

if not target_indexes:
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"result": "noop", "ticked": [], "items": len(items)}, fh)
    sys.exit(0)

# Flip - [ ] to - [x] on the matched lines. Preserve original indentation and
# any trailing whitespace around the marker — only the ` ` → `x` substitution
# changes.
new_lines = list(lines)
ticked_indexes = []
for idx_in_items in sorted(target_indexes):
    line_idx = items[idx_in_items][0]
    m = CHECKBOX_RE.match(new_lines[line_idx])
    if not m:
        continue
    new_lines[line_idx] = f"{m.group(1)}x{m.group(3)}{m.group(4)}{m.group(5)}"
    ticked_indexes.append(idx_in_items)

new_body = "".join(new_lines)
# Preserve the exact trailing-newline profile of the input — if the original
# body didn't end with a newline, neither does the output. splitlines(keepends=True)
# + join does the right thing here.

body_out_path = out_path + ".body"
with open(body_out_path, "w", encoding="utf-8") as fh:
    fh.write(new_body)

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump({
        "result": "updated",
        "ticked": ticked_indexes,
        "body_path": body_out_path,
        "items": len(items),
    }, fh)
PY

PY_STATUS=$?
if [[ $PY_STATUS -ne 0 ]]; then
  echo "ERROR: python parsing failed:" >&2
  cat "$PY_ERR" >&2
  # Normalize to 2 (internal script error) — NEVER forward a raw $PY_STATUS.
  # A Python crash exiting 1 would collide with the "no Test Plan section"
  # meaning and mislead callers into declaring AC clean.
  exit 2
fi

# Surface non-fatal python warnings (e.g., "index N out of range") to the caller.
if [[ -s "$PY_ERR" ]]; then
  cat "$PY_ERR" >&2
fi

# ---------------------------------------------------------------------------
# Handle python output
# ---------------------------------------------------------------------------
if [[ ! -s "$PY_OUT" ]]; then
  echo "ERROR: python produced no output" >&2
  # Exit 2 (internal script error) — NOT 4. Exit 4 is reserved for `gh pr edit`
  # failures; an empty py-out file is an internal parser fault.
  exit 2
fi

RESULT=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print(data.get("error") or data.get("result"))' "$PY_OUT" 2>/dev/null || true)

case "$RESULT" in
  no_section)
    echo "No Test Plan section found in PR #$PR_NUMBER body." >&2
    exit 1
    ;;
  no_checkboxes)
    echo "Test Plan section in PR #$PR_NUMBER has no checkbox items." >&2
    exit 1
    ;;
  extracted)
    # Print JSON array on stdout.
    python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["items"]))' "$PY_OUT"
    exit 0
    ;;
  noop)
    TICKED=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); n=d["items"]; print(f"0 ticked (of {n} items — nothing to do)")' "$PY_OUT")
    echo "$TICKED"
    exit 0
    ;;
  updated)
    BODY_PATH=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body_path"])' "$PY_OUT")
    TICKED=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); t=d["ticked"]; n=d["items"]; print(f"ticked {len(t)} of {n} items: {t}")' "$PY_OUT")
    # gh pr edit --body-file reads the full body verbatim (preserves newlines).
    EDIT_ERR_FILE="$TMPDIR_AC/edit-stderr"
    if ! gh pr edit "$PR_NUMBER" --body-file "$BODY_PATH" >/dev/null 2>"$EDIT_ERR_FILE"; then
      echo "ERROR: gh pr edit failed for PR #$PR_NUMBER:" >&2
      cat "$EDIT_ERR_FILE" >&2
      exit 4
    fi
    echo "$TICKED"
    exit 0
    ;;
  *)
    echo "ERROR: unexpected python result: $RESULT" >&2
    # Exit 2 (internal script error) — NOT 4. An unrecognized Python result is
    # an internal parser fault, matching the "empty py-out" sibling case above.
    # Exit 4 is reserved for `gh pr edit` failures only.
    exit 2
    ;;
esac
