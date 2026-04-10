#!/usr/bin/env python3
"""Register hooks from global-settings.json into ~/.claude/settings.json.

Purpose:
    Reads the hook manifest from the skills worktree's global-settings.json
    (source of truth) and merges missing entries into the user's live
    ~/.claude/settings.json. Matches existing hooks by script basename per
    event/matcher, so user-customized timeouts and hooks not in the template
    are preserved. Placeholder paths (e.g. "/path/to/...") are repaired in
    place to point at the real skills-worktree hooks directory.

Inputs:
    argv[1]  Path to the skills worktree root (e.g. ~/.claude/skills-worktree).
             Used to locate global-settings.json and .claude/hooks/*.

Outputs:
    ~/.claude/settings.json is mutated atomically (tempfile + os.replace).
    Status messages are printed to stderr. Exit code 0 on success or no-op,
    1 on unrecoverable malformed-settings / write errors.

Behavior:
    - Missing template or unreadable JSON -> exit 0 (no-op).
    - Multi-hook groups in the template are flattened to one-hook-per-group
      in settings.json (intentional, matches setup-skills-worktree.sh and is
      functionally equivalent — Claude Code reads all groups).
    - Hooks whose script file is missing from the hooks dir are skipped with
      a warning.
    - If no hooks needed to be added, exits 0 without writing.
"""

import json
import os
import sys
import tempfile


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


def build_manifest(template_hooks, hooks_dir):
    """Flatten template hook groups into a manifest of individual hook entries."""
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
                    print(
                        f"hook-sync: skipping {script} (not found in {hooks_dir})",
                        file=sys.stderr,
                    )
                    continue
                manifest.append({
                    "event": event,
                    "matcher": matcher,
                    "script": script,
                    "command": cmd,
                    "timeout": h.get("timeout", 10),
                })
    return manifest


def main(argv):
    if len(argv) < 2:
        print("usage: register-hooks.py <skills-worktree-path>", file=sys.stderr)
        return 1

    skills_wt = argv[1]
    settings_file = os.path.expanduser("~/.claude/settings.json")
    template_file = os.path.join(skills_wt, "global-settings.json")
    hooks_dir = os.path.join(skills_wt, ".claude", "hooks")

    # Read template (source of truth for hook definitions)
    try:
        with open(template_file, encoding="utf-8") as f:
            template = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return 0

    template_hooks = template.get("hooks", {})
    if not isinstance(template_hooks, dict):
        return 0

    manifest = build_manifest(template_hooks, hooks_dir)
    if not manifest:
        return 0

    # Read live settings
    try:
        with open(settings_file, encoding="utf-8") as f:
            settings = json.load(f)
    except FileNotFoundError:
        settings = {}
    except json.JSONDecodeError as e:
        print(f"settings.json malformed: {e}", file=sys.stderr)
        return 1

    if not isinstance(settings, dict):
        print(
            f"settings.json top-level is {type(settings).__name__}, not object",
            file=sys.stderr,
        )
        return 1
    if "hooks" not in settings:
        settings["hooks"] = {}
    elif not isinstance(settings["hooks"], dict):
        print("settings.json hooks section is not an object", file=sys.stderr)
        return 1

    live = settings["hooks"]

    added = 0
    for item in manifest:
        event = item["event"]
        if event not in live:
            live[event] = []
        elif not isinstance(live[event], list):
            print(f"settings.json hooks[{event!r}] is not a list", file=sys.stderr)
            return 1
        match = find_existing(live[event], item["script"], item["matcher"])
        if match is True:
            continue
        if isinstance(match, dict):
            # Repair placeholder entry in-place
            match["command"] = item["command"]
            added += 1
            continue
        hook_obj = {
            "type": "command",
            "command": item["command"],
            "timeout": item["timeout"],
        }
        group = {"hooks": [hook_obj]}
        if item["matcher"]:
            group["matcher"] = item["matcher"]
        live[event].append(group)
        added += 1

    if added == 0:
        return 0

    # Atomic write
    d = os.path.dirname(settings_file) or "."
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        os.replace(tmp, settings_file)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        print(f"hook-sync: atomic write failed: {e}", file=sys.stderr)
        return 1

    print(f"hook-sync: registered {added} new hook(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
