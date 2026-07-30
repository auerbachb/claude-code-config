#!/usr/bin/env bash
# model-fleet.sh — Resolve the current Claude model fleet from one source.
#
# PURPOSE
#   Reads `.claude/model-fleet.json` and answers "what is the top-tier model
#   right now?" so callers never carry a model literal in their own body. The
#   audit skill `/harness-audit` (issue #770) is the first consumer; the
#   broader migration of `/prompt`, chip `**Model:**` lines, and the agent
#   definitions off their hardcoded names is tracked in issue #749.
#
#   The point of the indirection is that a fleet change is a one-file edit.
#   Anything that resolves through this script picks the new tier up with no
#   further change; anything that spells the name out does not.
#
# FAIL-CLOSED CONTRACT
#   There is no fallback model name anywhere in this script. A missing file,
#   unparseable JSON, an absent/empty `top_tier`, or a `top_tier` that is not
#   itself a member of `fleet[]` all exit non-zero with a specific message.
#   A caller that silently degraded to a stale hardcoded default would defeat
#   the entire purpose of having a single source, so the script would rather
#   stop the caller than answer wrongly.
#
# USAGE
#   model-fleet.sh [--top-tier | --top-tier-display | --list | --json]
#                  [--file <path>]
#   model-fleet.sh --help | -h
#
#   --top-tier          Print the top-tier model id (DEFAULT when no mode flag
#                       is given), e.g. `claude-fable-5`.
#   --top-tier-display  Print the top-tier human-facing name, e.g. `Fable 5`.
#                       This is what belongs on a `**Model:**` chip line.
#   --list              Print the ordered fleet, one `id<TAB>display` per line,
#                       strongest first.
#   --json              Print the raw fleet document (validated, compact).
#   --file <path>       Read from <path> instead of the repo's
#                       `.claude/model-fleet.json`. Also settable via the
#                       CLAUDE_MODEL_FLEET_FILE environment variable; the flag
#                       wins. Exists so tests can point at a fixture and so a
#                       fleet change can be rehearsed before it is committed.
#
#   Mode flags are mutually exclusive.
#
# OUTPUT
#   stdout: the requested value (see each flag above).
#   stderr: one-line error message on failure.
#
# EXIT STATUS
#   0  Success — value printed on stdout.
#   1  Fleet file missing, unreadable, invalid JSON, or internally
#      inconsistent (no `top_tier`, empty `top_tier`, `top_tier` absent from
#      `fleet[]`, missing/empty `fleet[]`, or a fleet entry missing `id`).
#   2  Usage error (unknown flag, missing value, conflicting mode flags).
#
# EXAMPLES
#   TOP=$(.claude/scripts/model-fleet.sh --top-tier)
#   echo "**Model:** $(.claude/scripts/model-fleet.sh --top-tier-display) — deep judgment pass"
#   .claude/scripts/model-fleet.sh --list

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "${HOME:-/tmp}/.claude/script-usage.log" 2>/dev/null || true

print_help() {
  # Header block from the line after the shebang to the first blank line,
  # matching off-peak-minute.sh / hhg-state.sh.
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "model-fleet.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

data_error() {
  echo "model-fleet.sh: $1" >&2
  exit 1
}

MODE=""
FLEET_FILE="${CLAUDE_MODEL_FLEET_FILE:-}"

set_mode() {
  # Mode flags are exclusive: silently honoring the last one would make
  # `--list --json` quietly mean `--json` instead of surfacing the mistake.
  [[ -z "$MODE" ]] || usage_error "conflicting mode flags: --$MODE and --$1"
  MODE="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          print_help; exit 0 ;;
    --top-tier)         set_mode "top-tier"; shift ;;
    --top-tier-display) set_mode "top-tier-display"; shift ;;
    --list)             set_mode "list"; shift ;;
    --json)             set_mode "json"; shift ;;
    --file)
      [[ $# -ge 2 ]] || usage_error "--file requires a value"
      [[ -n "$2" ]] || usage_error "--file value cannot be empty"
      FLEET_FILE="$2"
      shift 2
      ;;
    --file=*)
      FLEET_FILE="${1#--file=}"
      [[ -n "$FLEET_FILE" ]] || usage_error "--file value cannot be empty"
      shift
      ;;
    --) shift; break ;;
    -*) usage_error "unknown flag: $1" ;;
    *)  usage_error "unexpected positional argument: $1" ;;
  esac
done

[[ $# -eq 0 ]] || usage_error "unexpected positional argument: $1"

MODE="${MODE:-top-tier}"

# --- resolve the fleet file ---
if [[ -z "$FLEET_FILE" ]]; then
  # Resolve relative to this script rather than the caller's cwd, so the
  # resolver works from any worktree or subdirectory.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FLEET_FILE="${SCRIPT_DIR}/../model-fleet.json"
fi

if [[ ! -f "$FLEET_FILE" ]]; then
  data_error "fleet file not found: $FLEET_FILE (no fallback model name exists — fix the file)"
fi
if [[ ! -r "$FLEET_FILE" ]]; then
  data_error "fleet file is not readable: $FLEET_FILE"
fi

# --- validate + extract in one python pass ---
# Python (not jq) so the script has no dependency beyond what the repo's other
# Python-touching tooling already assumes, and so every consistency failure
# gets its own message instead of a bare jq null.
OUT=""
RC=0
OUT="$(MODEL_FLEET_MODE="$MODE" python3 - "$FLEET_FILE" <<'PY'
import json
import os
import sys

path = sys.argv[1]
mode = os.environ.get("MODEL_FLEET_MODE", "top-tier")

try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except json.JSONDecodeError as exc:
    print("fleet file is not valid JSON: %s (%s)" % (path, exc), file=sys.stderr)
    sys.exit(1)
except OSError as exc:
    print("cannot read fleet file: %s (%s)" % (path, exc), file=sys.stderr)
    sys.exit(1)

if not isinstance(doc, dict):
    print("fleet file must contain a JSON object: %s" % path, file=sys.stderr)
    sys.exit(1)

fleet = doc.get("fleet")
if not isinstance(fleet, list) or not fleet:
    print("fleet file has a missing or empty 'fleet' array: %s" % path, file=sys.stderr)
    sys.exit(1)

def require_str(value, label):
    """Reject non-string values instead of coercing them.

    str(True) is "True" and str(5) is "5" — both are perfectly usable model
    names as far as the rest of this script is concerned, so a coercion here
    would turn a typo in the fleet file into a confident wrong answer. Model
    identity must be spelled as a string or not accepted at all.
    """
    if value is None:
        return ""
    if not isinstance(value, str):
        print(
            "%s must be a string, got %s: %s" % (label, type(value).__name__, path),
            file=sys.stderr,
        )
        sys.exit(1)
    return value.strip()


entries = []
for idx, item in enumerate(fleet):
    if not isinstance(item, dict):
        print("fleet[%d] is not an object: %s" % (idx, path), file=sys.stderr)
        sys.exit(1)
    ident = require_str(item.get("id"), "fleet[%d].id" % idx)
    if not ident:
        print("fleet[%d] is missing 'id': %s" % (idx, path), file=sys.stderr)
        sys.exit(1)
    # A missing display falls back to the id: a human-facing label is a
    # nicety, an id is not.
    display = require_str(item.get("display"), "fleet[%d].display" % idx) or ident
    if any(ident == seen for seen, _ in entries):
        print(
            "fleet[%d] duplicates an earlier id (%s): %s" % (idx, ident, path),
            file=sys.stderr,
        )
        sys.exit(1)
    entries.append((ident, display))

top = require_str(doc.get("top_tier"), "top_tier")
if not top:
    print("fleet file has a missing or empty 'top_tier': %s" % path, file=sys.stderr)
    sys.exit(1)

match = [d for i, d in entries if i == top]
if not match:
    print(
        "'top_tier' (%s) is not a member of fleet[]: %s" % (top, path),
        file=sys.stderr,
    )
    sys.exit(1)

# fleet[] is documented as ordered strongest-first, so top_tier naming anything
# other than the first entry means the file contradicts itself — and the two
# readings ("--list is ordered" vs "top_tier is the strongest") would disagree
# about which model is best. Refuse rather than silently pick one reading.
if entries[0][0] != top:
    print(
        "'top_tier' (%s) is not the first fleet[] entry (%s) — fleet[] must be "
        "ordered strongest-first: %s" % (top, entries[0][0], path),
        file=sys.stderr,
    )
    sys.exit(1)

if mode == "top-tier":
    sys.stdout.write(top + "\n")
elif mode == "top-tier-display":
    sys.stdout.write(match[0] + "\n")
elif mode == "list":
    for ident, display in entries:
        sys.stdout.write("%s\t%s\n" % (ident, display))
elif mode == "json":
    sys.stdout.write(json.dumps(doc, separators=(",", ":"), sort_keys=True) + "\n")
else:
    print("internal error: unknown mode %r" % mode, file=sys.stderr)
    sys.exit(1)
PY
)" || RC=$?

# `set -e` would abort on the non-zero exit before the message could be
# re-framed; capture the rc explicitly instead (memory:
# feedback_set_e_subshell_assignment).
if (( RC != 0 )); then
  exit 1
fi

printf '%s\n' "$OUT"
