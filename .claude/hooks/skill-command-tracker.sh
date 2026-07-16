#!/bin/bash
# Skill command tracker — UserPromptSubmit hook (issue #584)
#
# Captures skill invocations the user types as slash commands. Those never
# reach skill-usage-tracker.sh: the surface expands the command into the prompt
# itself, and the model is told to follow an already-present <command-name>
# block rather than call the Skill tool, so no PostToolUse:Skill event fires.
# Without this hook, user-typed skills log nothing and a usage audit reads
# their zeros as "dead" (#573).
#
# Input  (stdin) : JSON with {prompt, session_id, cwd, ...}
# Output (stdout): empty JSON object — this hook injects no context
# Exit code      : always 0 — never blocks the prompt
#
# Recording, storage layout, and the marker-based dedupe against the
# PostToolUse path all live in lib/skill-usage-recorder.sh.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

# Always emit empty JSON and never fail — this hook is non-blocking.
trap 'echo "{}"; exit 0' EXIT

# Fast pre-filter. UserPromptSubmit fires on every prompt, so only pay for a
# python spawn when the payload could plausibly open with a command. Generous
# by design — a false positive costs one spawn, a false negative loses
# telemetry; the anchored parse below is the authority.
#   *<command-name>*  the pre-expanded form
#   raw_cmd_re        the raw form: a "prompt"/"message" value starting with
#                     "/", tolerating JSON spacing, an escaped leading
#                     whitespace (\n, \r, \t), and an escaped slash (\/)
raw_cmd_re='"(prompt|message)"[[:space:]]*:[[:space:]]*"([[:space:]]|\\[nrt])*\\?/'
if [[ "$INPUT" != *"<command-name>"* && ! "$INPUT" =~ $raw_cmd_re ]]; then
  exit 0
fi

RECORDER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/skill-usage-recorder.sh"
[ -r "$RECORDER" ] || exit 0
# shellcheck source=lib/skill-usage-recorder.sh
. "$RECORDER" 2>/dev/null || exit 0

# Prints two lines — skill name, then session id — only for a prompt that opens
# with a slash command naming an installed skill. Silent otherwise.
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json, os, re, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = d.get("prompt") or d.get("message") or ""
if not isinstance(prompt, str):
    sys.exit(0)

# Anchored at the very start of the prompt: a typed command opens the message.
# A "/name" mentioned mid-sentence (or a pasted <command-name> block, as in a
# discussion about this hook) must never log.
EXPANDED = re.compile(
    r"\A\s*(?:<command-message>[^<]*</command-message>\s*)?"
    r"<command-name>\s*/?([^<\s]+)\s*</command-name>",
    re.IGNORECASE,
)
RAW = re.compile(r"\A\s*/([A-Za-z0-9][A-Za-z0-9._:-]*)(?:\s|\Z)")

m = EXPANDED.match(prompt) or RAW.match(prompt)
if not m:
    sys.exit(0)
name = m.group(1).strip()

# Strip plugin prefix (e.g. "anthropic-skills:pdf" -> "pdf") so both capture
# paths key the same name — mirrors skill-usage-tracker.sh.
if ":" in name:
    name = name.split(":", 1)[1]

# Only a name that is safe as a single path component may reach the catalog
# lookup. This also rejects "." / ".." and anything unsafe for the CSV.
if not re.match(r"\A[A-Za-z0-9_][A-Za-z0-9._-]*\Z", name):
    sys.exit(0)


def installed(name, cwd):
    """True when name resolves to a skill in the project or global catalog."""
    try:
        d = os.path.realpath(cwd) if cwd else ""
    except Exception:
        d = ""
    while d:
        if os.path.isfile(os.path.join(d, ".claude", "skills", name, "SKILL.md")):
            return True
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return os.path.isfile(
        os.path.expanduser(os.path.join("~", ".claude", "skills", name, "SKILL.md"))
    )


# Built-ins (/clear, /config) and non-skill .claude/commands entries are not
# skills — an unknown token logs nothing.
if not installed(name, d.get("cwd") or ""):
    sys.exit(0)

session = d.get("session_id") or ""
if not isinstance(session, str):
    session = ""
print(name)
print(session)
' 2>/dev/null) || exit 0

[ -n "$PARSED" ] || exit 0

SKILL_NAME=""
SESSION_ID=""
{ read -r SKILL_NAME; read -r SESSION_ID; } <<<"$PARSED"

[ -n "$SKILL_NAME" ] || exit 0

record_skill_usage "$SKILL_NAME" "$SESSION_ID" userprompt

exit 0
