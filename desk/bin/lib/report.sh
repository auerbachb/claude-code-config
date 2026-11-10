# shellcheck shell=bash
# desk/bin/lib/report.sh — the weekly attention report's helpers outside the
# store (issue #1771): which model a thread ran on, and the text rendering.
# Sourced by desk/bin/cmd/report.sh after lib/common.sh, lib/db.sh, and
# lib/github.sh (for hq_jq); never executed. Bash 3.2 compatible.
#
# The store keeps state changes only (desk/DESIGN.md 2.5): no event names a
# model, and none is added for this report. A feedback event names the thread
# that asked (events.session_id, migration 008), and that thread's Claude Code
# transcript on this machine names the model of every reply. The report reads
# it at the moment it runs and stores nothing.
#
# PUBLIC FUNCTIONS
#   hq_thread_model VAR SESSION
#       sets VAR to the model of SESSION's latest reply: the `message.model`
#       of the last assistant line outside a sidechain (a subagent's) in
#       <transcripts>/*/SESSION.jsonl, the most recently written such file
#       when there are several. `unknown` when SESSION is not an id that can
#       name a file (letters, digits, `-` and `_`), when no transcript is on
#       this machine (a thread that ran on another one), or when it names no
#       model. Never fails: an unreadable or half-written line is skipped.
#   hq_report_render JSON
#       prints `report --json`'s object (models resolved) as the report's
#       text: the numbered list and the small table (lib/report.jq)
#
# ENVIRONMENT
#   HUMAN_QUEUE_TRANSCRIPTS_DIR  where Claude Code keeps transcripts (default
#                                ~/.claude/projects; tests point it at
#                                fixtures)

# hq__report_model_ok VALUE — a model name safe to print in a table cell.
# LC_ALL=C so the classes are byte ranges, never a locale's.
hq__report_model_ok() {
  local LC_ALL=C re='^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,99}$'
  [[ $1 =~ $re ]]
}

hq_thread_model() {
  local hq__var="$1" hq__sid="$2" hq__root hq__f hq__best="" hq__m="" LC_ALL=C
  local hq__re='^[A-Za-z0-9][A-Za-z0-9_-]{0,199}$'
  printf -v "$hq__var" '%s' unknown
  [[ $hq__sid =~ $hq__re ]] || return 0
  hq__root="${HUMAN_QUEUE_TRANSCRIPTS_DIR:-${HOME:-}/.claude/projects}"
  for hq__f in "$hq__root"/*/"$hq__sid".jsonl; do
    [ -f "$hq__f" ] || continue
    if [ -z "$hq__best" ] || [ "$hq__f" -nt "$hq__best" ]; then hq__best="$hq__f"; fi
  done
  [ -n "$hq__best" ] || return 0
  # grep keeps jq's input to the assistant lines; jq reads each line on its
  # own (-R, fromjson?), so one half-written line never hides the rest.
  hq__m=$(grep -E '"type"[[:space:]]*:[[:space:]]*"assistant"' "$hq__best" 2>/dev/null \
    | hq_jq -R -r 'fromjson? | select(type == "object" and .type == "assistant" and .isSidechain != true)
                   | (.message | objects | .model) | strings | select(. != "<synthetic>")' 2>/dev/null \
    | tail -n 1) || hq__m=""
  if [ -n "$hq__m" ] && hq__report_model_ok "$hq__m"; then
    printf -v "$hq__var" '%s' "$hq__m"
  fi
  return 0
}

hq_report_render() {
  printf '%s' "$1" | hq_jq -r -L "$HQ_BIN_DIR/lib" 'include "report"; report_text'
}
