#!/bin/bash
# Session-start sync — PostToolUse hook (fires after every tool call)
# Syncs the skills worktree and root repo ONCE per session to ensure
# skills, rules, and CLAUDE.md are up to date with origin/main.
#
# Uses a sentinel file to run only once per session.

# Consume stdin (required by hook protocol)
cat > /dev/null

# Session-scoped sentinel file
session_id="${CLAUDE_SESSION_ID:-${PPID:-$$}}"
session_id="${session_id//[^[:alnum:]_.-]/_}"
sentinel="/tmp/claude-config-synced-${session_id}"

# Already synced this session — exit fast
if [[ -f "$sentinel" ]]; then
  echo '{}'
  exit 0
fi

# Mark as synced (even if sync fails — don't retry every tool call)
touch "$sentinel"

# --- Sync skills worktree ---
skills_wt="$HOME/.claude/skills-worktree"
setup_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/setup-skills-worktree.sh"
errors=""

# Bootstrap missing skills worktree if setup script is available
if [[ ! -d "$skills_wt/.claude/skills" || ! -f "$skills_wt/.git" ]]; then
  if [[ -x "$setup_script" || -f "$setup_script" ]]; then
    if ! err=$(bash "$setup_script" 2>&1); then
      errors="skills worktree setup failed: $err"
    fi
  fi
fi

if [[ -z "$errors" && -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  if ! err=$(git -C "$skills_wt" fetch origin main --quiet 2>&1); then
    errors="skills worktree fetch failed: $err"
  elif ! err=$(git -C "$skills_wt" reset --hard origin/main --quiet 2>&1); then
    errors="skills worktree reset failed: $err"
  fi
elif [[ -z "$errors" ]]; then
  errors="skills worktree not found at $skills_wt"
fi

# --- Sync root repo (derives path from skills worktree) ---
# Re-check skills worktree availability independently — fetch/reset errors above
# don't block this pull, and the root repo path is derived from the worktree.
if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  root_repo=$(git -C "$skills_wt" worktree list 2>/dev/null | head -1 | awk '{print $1}')
  if [[ -n "$root_repo" && -e "$root_repo/.git" ]]; then
    # Only pull if on main branch (don't disrupt feature branches)
    current_branch=$(git -C "$root_repo" branch --show-current 2>/dev/null)
    if [[ "$current_branch" == "main" ]]; then
      if ! err=$(git -C "$root_repo" pull origin main --ff-only --quiet 2>&1); then
        errors="${errors:+$errors; }root repo pull failed: $err"
      fi
    fi
  else
    errors="${errors:+$errors; }root repo could not be resolved from skills worktree at $skills_wt"
  fi
fi

# --- Sync hooks from global-settings.json into ~/.claude/settings.json ---
# Ensures new hooks added to the template are auto-registered each session.
# Uses the same registration logic as setup-skills-worktree.sh Step 6.
# Matches by script basename to detect existing hooks; preserves user hooks
# and custom timeouts. No-op if root_repo is unavailable or template is missing.

if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  if ! err=$(python3 - "$skills_wt" <<'HOOK_SYNC_PYTHON' 2>&1
import json, os, sys, tempfile

skills_wt = sys.argv[1]
settings_file = os.path.expanduser("~/.claude/settings.json")
template_file = os.path.join(skills_wt, "global-settings.json")
hooks_dir = os.path.join(skills_wt, ".claude", "hooks")

# Read template (source of truth for hook definitions)
try:
    with open(template_file) as f:
        template = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)

template_hooks = template.get("hooks", {})
if not isinstance(template_hooks, dict):
    sys.exit(0)

# Extract individual hook entries from template structure.
# Note: multi-hook groups in the template are flattened to one-hook-per-group
# in settings.json. This is intentional (matches setup-skills-worktree.sh) and
# functionally equivalent — Claude Code reads all groups regardless of grouping.
manifest = []
for event, groups in template_hooks.items():
    if not isinstance(groups, list):
        continue
    for group in groups:
        if not isinstance(group, dict):
            continue
        matcher = group.get("matcher")
        hook_list = group.get("hooks", [])
        if not isinstance(hook_list, list):
            continue
        for h in hook_list:
            if not isinstance(h, dict):
                continue
            script = os.path.basename(h.get("command", ""))
            if not script:
                continue
            cmd = os.path.join(hooks_dir, script)
            if not os.path.isfile(cmd):
                print(f"hook-sync: skipping {script} (not found in {hooks_dir})", file=sys.stderr)
                continue
            manifest.append({
                "event": event,
                "matcher": matcher,
                "script": script,
                "command": cmd,
                "timeout": h.get("timeout", 10),
            })

if not manifest:
    sys.exit(0)

# Read live settings
try:
    with open(settings_file) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}
except json.JSONDecodeError as e:
    print(f"settings.json malformed: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(settings, dict):
    print(f"settings.json top-level is {type(settings).__name__}, not object", file=sys.stderr)
    sys.exit(1)
if "hooks" not in settings:
    settings["hooks"] = {}
elif not isinstance(settings["hooks"], dict):
    print("settings.json hooks section is not an object", file=sys.stderr)
    sys.exit(1)

live = settings["hooks"]

def is_placeholder(path):
    return "/path/to/" in path or not os.path.isabs(path)

def find_existing(entries, basename, matcher):
    """Return True for a real match, or the placeholder hook dict to repair."""
    for g in entries:
        if not isinstance(g, dict):
            continue
        if g.get("matcher") != matcher:
            continue
        for h in (g.get("hooks") or []):
            if not isinstance(h, dict):
                continue
            existing = h.get("command", "")
            if os.path.basename(existing) == basename:
                return h if is_placeholder(existing) else True
    return None

added = 0
for item in manifest:
    event = item["event"]
    if event not in live:
        live[event] = []
    elif not isinstance(live[event], list):
        print(f"settings.json hooks[{event!r}] is not a list", file=sys.stderr)
        sys.exit(1)
    match = find_existing(live[event], item["script"], item["matcher"])
    if match is True:
        continue
    if isinstance(match, dict):
        # Repair placeholder entry in-place
        match["command"] = item["command"]
        added += 1
        continue
    hook_obj = {"type": "command", "command": item["command"], "timeout": item["timeout"]}
    group = {"hooks": [hook_obj]}
    if item["matcher"]:
        group["matcher"] = item["matcher"]
    live[event].append(group)
    added += 1

if added == 0:
    sys.exit(0)

# Atomic write
d = os.path.dirname(settings_file) or "."
fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, settings_file)
except OSError as e:
    try: os.unlink(tmp)
    except OSError: pass
    print(f"hook-sync: atomic write failed: {e}", file=sys.stderr)
    sys.exit(1)

print(f"hook-sync: registered {added} new hook(s)", file=sys.stderr)
HOOK_SYNC_PYTHON
  ); then
    errors="${errors:+$errors; }hook sync failed: $err"
  fi
fi

# Report result
if [[ -n "$errors" ]]; then
  jq -n --arg errors "$errors" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("SESSION SYNC WARNING: Config sync encountered errors: " + $errors + ". Skills, rules, or CLAUDE.md may be stale. Run manually: git -C ~/.claude/skills-worktree fetch origin main && git -C ~/.claude/skills-worktree reset --hard origin/main")
    }
  }'
else
  echo '{}'
fi

exit 0
