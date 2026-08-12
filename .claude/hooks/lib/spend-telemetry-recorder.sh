#!/bin/bash
# Shared spend/thread-type telemetry recorder — sourced by hooks, never executed directly.
#
# Single authoritative writer for the spend telemetry stream (issue #710).
# Both capture paths funnel through record_spend_telemetry():
#   - spend-session-tracker.sh  (SessionStart)  -> exec_type "thread"
#   - spend-subagent-tracker.sh (SubagentStop)  -> exec_type "inline"
#
# Storage model — everything lives under ~/.claude/. NEVER write telemetry into
# the skills worktree: session-start-sync.sh can `git reset --hard` it away.
#   - ~/.claude/spend-telemetry.log — append-only, one tab-separated line per
#     event. Read by spend-telemetry-report.sh. The line format is a contract;
#     consumers should tolerate unknown trailing fields.
#
# LOG SCHEMA (tab-separated, ISO8601 UTC):
#   ISO8601Z  event_type  exec_type  model_tier  agent_type  session_id  agent_id  tokens
#
#   event_type  : session_start | subagent_stop
#   exec_type   : thread | inline
#   model_tier  : opus | sonnet | haiku | fable | unknown
#   agent_type  : for subagent_stop: the agent_type field from payload;
#                 for session_start: "session"
#   session_id  : payload value -> $CLAUDE_SESSION_ID -> "unknown"
#   agent_id    : for subagent_stop: the agent_id field; for session_start: ""
#   tokens      : best-effort integer from transcript; empty when unavailable
#
# record_spend_telemetry() is best-effort and always returns 0 — telemetry must
# never break a hook, and both callers are non-blocking.
#
# Observational-only: per safety.md §"Anthropic Quota & Spend Authority", this
# data MUST NOT gate any agent decision, spending estimate, or quota check.

SPEND_TELEMETRY_LOG="${HOME}/.claude/spend-telemetry.log"

# Sanitize a field value for TSV: strip tabs and newlines to prevent log injection.
_spend_sanitize() {
  local raw="${1:-}"
  printf '%s' "${raw}" | LC_ALL=C tr -d '\t\r\n'
}

# Resolve session id: payload value -> ambient $CLAUDE_SESSION_ID -> "unknown".
# Mirrors the resolution in skill-usage-recorder.sh.
_spend_resolve_session() {
  local session="${1:-}"
  session="${session:-${CLAUDE_SESSION_ID:-}}"
  session="$(_spend_sanitize "$session")"
  printf '%s' "${session:-unknown}"
}

# Derive model tier from agent_type by reading the agent frontmatter.
# Looks for 'model: <tier>' in the YAML front matter of the agent definition.
# Falls back to "unknown" when the file or field is absent.
#
# Arguments: $1 = agent_type (e.g. "phase-a-fixer"), $2 = repo_root (optional)
_spend_model_tier_from_agent_type() {
  local agent_type="${1:-}"

  # Sanitize agent_type before using as a path component.
  agent_type="${agent_type//[^[:alnum:]_.-]/}"
  [ -z "$agent_type" ] && printf 'unknown' && return 0

  # Build candidate search paths for the agents directory.
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  # lib/ is one level below hooks/; .claude/ is one above hooks/
  local hooks_dir="${self_dir%/lib}"
  local claude_dir="${hooks_dir%/hooks}"

  local agents_dir=""
  for candidate in \
    "${claude_dir}/agents" \
    "${HOME}/.claude/skills-worktree/.claude/agents"; do
    [ -n "$candidate" ] && [ -d "$candidate" ] && { agents_dir="$candidate"; break; }
  done

  if [ -n "$agents_dir" ]; then
    local agent_file="${agents_dir}/${agent_type}.md"
    if [ -f "$agent_file" ]; then
      # Read YAML front matter (between --- delimiters), extract model field.
      local model
      model=$(python3 - "$agent_file" <<'PY' 2>/dev/null
import re, sys
try:
    content = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    m = re.match(r"^---\s*\n(.*?)\n---", content, re.DOTALL)
    if m:
        mm = re.search(r"^model:\s*(\S+)", m.group(1), re.MULTILINE)
        if mm:
            print(mm.group(1).strip().lower())
except Exception:
    pass
PY
) || model=""
      [ -n "$model" ] && printf '%s' "$model" && return 0
    fi
  fi

  printf 'unknown'
  return 0
}

# Best-effort token extraction from a transcript path.
# Attempts to sum token count fields from JSONL transcript lines.
# Returns empty on any failure — never blocks the hook.
_spend_tokens_from_transcript() {
  local transcript_path="${1:-}"
  [ -z "$transcript_path" ] && printf '' && return 0
  [ -f "$transcript_path" ] || { printf ''; return 0; }

  python3 - "$transcript_path" <<'PY' 2>/dev/null || printf ''
import json, sys
path = sys.argv[1]
total = 0
found = False
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            # Look for usage dicts at the top level of each record.
            usage = obj.get("usage") if isinstance(obj, dict) else None
            if isinstance(usage, dict):
                for sub in ("input_tokens", "output_tokens",
                            "cache_read_input_tokens",
                            "cache_creation_input_tokens"):
                    sv = usage.get(sub)
                    if isinstance(sv, (int, float)):
                        total += int(sv)
                        found = True
            # Also accept bare token fields at top level.
            for key in ("input_tokens", "output_tokens"):
                if key in obj and isinstance(obj[key], (int, float)):
                    total += int(obj[key])
                    found = True
except Exception:
    pass
if found and total > 0:
    print(total)
PY
  return 0
}

# Append one line to the telemetry log.
# Wraps the redirect so open failures are silenced (a trailing 2>/dev/null
# only covers the command's stderr, not the shell's redirection error).
_spend_append_log() {
  local event_type="${1:-}" exec_type="${2:-}" model_tier="${3:-}" \
        agent_type="${4:-}" session_id="${5:-}" agent_id="${6:-}" tokens="${7:-}"

  mkdir -p "$(dirname "$SPEND_TELEMETRY_LOG")" 2>/dev/null || return 1
  { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%FT%TZ)" \
      "$event_type" \
      "$exec_type" \
      "$model_tier" \
      "$agent_type" \
      "$session_id" \
      "$agent_id" \
      "$tokens" \
      >>"$SPEND_TELEMETRY_LOG"; } 2>/dev/null || return 1
  return 0
}

# record_spend_telemetry <event_type> <exec_type> <model_tier> <agent_type>
#                        <session_id> <agent_id> <tokens>
#
#   event_type : session_start | subagent_stop
#   exec_type  : thread | inline
#   All fields are sanitized before writing.
#   Always returns 0 — telemetry must never break a hook.
record_spend_telemetry() {
  local event_type="${1:-}" exec_type="${2:-}" model_tier="${3:-}" \
        agent_type="${4:-}" session_id="${5:-}" agent_id="${6:-}" tokens="${7:-}"

  event_type="$(_spend_sanitize "$event_type")"
  exec_type="$(_spend_sanitize "$exec_type")"
  model_tier="$(_spend_sanitize "$model_tier")"
  agent_type="$(_spend_sanitize "$agent_type")"
  session_id="$(_spend_resolve_session "$session_id")"
  agent_id="$(_spend_sanitize "$agent_id")"
  tokens="$(_spend_sanitize "$tokens")"

  [ -z "$event_type" ] && return 0
  [ -z "$exec_type" ] && return 0

  _spend_append_log "$event_type" "$exec_type" "$model_tier" \
                    "$agent_type" "$session_id" "$agent_id" "$tokens" || true
  return 0
}
