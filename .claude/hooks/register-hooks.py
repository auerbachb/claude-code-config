#!/usr/bin/env python3
"""Register hooks and the statusLine command from global-settings.json into
~/.claude/settings.json.

Purpose:
    Reads the hook manifest from the skills worktree's global-settings.json
    (source of truth) and merges missing entries into the user's live
    ~/.claude/settings.json. Matches existing hooks by script basename per
    event/matcher, so user-customized timeouts and hooks not in the template
    are preserved. Placeholder paths (e.g. "/path/to/...") are repaired in
    place to point at the real skills-worktree hooks directory.

    The same treatment is applied to the top-level `statusLine` key (issue
    #779). It is not a hook event — it is a separate settings surface whose
    `command` needs the identical placeholder-to-worktree resolution, and
    which must auto-propagate at session start so the feature lands without
    a setup.sh re-run.

Inputs:
    argv      Path to the skills worktree root (e.g. ~/.claude/skills-worktree).
              Used to locate global-settings.json, .claude/hooks/*, and
              .claude/scripts/*.
    --statusline-only
              Sync only the statusLine key; skip hook registration entirely.
              Kept for callers that need only path-repair on statusLine without
              touching the hooks section.

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
    - A statusLine already pointing at a DIFFERENT script is the user's own
      and is never touched; only our own script's path is repaired, and
      sibling keys (padding, refreshInterval, …) are always preserved.
    - If nothing needed to change, exits 0 without writing.
"""

import json
import os
import shlex
import sys
import tempfile


PLACEHOLDER_PREFIX = "/path/to/claude-code-config/"


def is_placeholder(path):
    return path.startswith(PLACEHOLDER_PREFIX)


def command_argv0(cmd):
    """Extract the executable path (argv0) from a hook command, ignoring arguments.

    Lets a hook registered as 'foo.sh --check' match its manifest entry by
    basename — os.path.basename on the raw command string would return
    'foo.sh --check', which never matches 'foo.sh'.
    """
    if not isinstance(cmd, str):
        return ""
    try:
        parts = shlex.split(cmd)
    except ValueError:
        parts = cmd.split()
    return parts[0] if parts else ""


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
            existing_argv0 = command_argv0(h.get("command", ""))
            if os.path.basename(existing_argv0) == basename:
                return h if is_placeholder(existing_argv0) else True
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


def sync_statusline(settings, template, scripts_dir):
    """Seed or path-repair settings["statusLine"] from the template.

    Returns 1 when settings was modified, 0 otherwise. Never raises: a
    statusLine problem must not stop hook registration.

    The user's own statusLine is left completely alone — this only owns the
    entry it installed. When it does own the entry, only `command` is rewritten,
    so `padding`, `refreshInterval`, and any other key the user tuned survive.

    Ownership is decided by the installed LAYOUT (a path ending in
    .claude/scripts/<script>), not by basename alone. Basename alone would claim
    a user's own ~/bin/statusline.sh purely because the filename collides, while
    matching only the exact resolved or placeholder path would fail to repair a
    path left behind by an earlier worktree location — which is a case this has
    to handle. The layout suffix is what separates the two.
    """
    tpl = template.get("statusLine")
    if not isinstance(tpl, dict):
        return 0

    tpl_command = tpl.get("command", "")
    if not isinstance(tpl_command, str) or not tpl_command:
        return 0

    script = os.path.basename(tpl_command)
    resolved = os.path.join(scripts_dir, script)
    if not os.path.isfile(resolved):
        print(
            f"statusline-sync: skipping {script} (not found in {scripts_dir})",
            file=sys.stderr,
        )
        return 0

    # Seed only when the key is genuinely ABSENT. An explicit "statusLine": null
    # is a user statement — most plausibly "disabled" — and gets the same
    # hands-off treatment as any other non-object value below. `.get()` cannot
    # tell those two apart, which is why this tests membership instead.
    if "statusLine" not in settings:
        settings["statusLine"] = dict(tpl, command=resolved)
        return 1

    live = settings["statusLine"]
    if not isinstance(live, dict):
        print(
            "statusline-sync: settings.json statusLine is not an object; leaving it alone",
            file=sys.stderr,
        )
        return 0

    # See the docstring: layout, not basename. `/Users/me/bin/statusline.sh` is
    # the user's own script that merely shares our filename; a stale
    # `/old/worktree/.claude/scripts/statusline.sh` is ours to repair.
    owned_suffix = os.sep + os.path.join(".claude", "scripts", script)
    existing = live.get("command", "")
    if not isinstance(existing, str) or not (
        existing == resolved or existing.endswith(owned_suffix)
    ):
        # Someone else's status line (or a malformed entry) — not ours to touch.
        return 0

    if existing == resolved:
        return 0

    live["command"] = resolved
    return 1


def main(argv):
    args = [a for a in argv[1:] if a != "--statusline-only"]
    statusline_only = "--statusline-only" in argv[1:]

    if not args:
        print(
            "usage: register-hooks.py [--statusline-only] <skills-worktree-path>",
            file=sys.stderr,
        )
        return 1

    skills_wt = args[0]
    settings_file = os.path.expanduser("~/.claude/settings.json")
    template_file = os.path.join(skills_wt, "global-settings.json")
    hooks_dir = os.path.join(skills_wt, ".claude", "hooks")
    scripts_dir = os.path.join(skills_wt, ".claude", "scripts")

    # Read template (source of truth for hook and statusLine definitions)
    try:
        with open(template_file, encoding="utf-8") as f:
            template = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return 0
    if not isinstance(template, dict):
        return 0

    if statusline_only:
        manifest = []
    else:
        template_hooks = template.get("hooks", {})
        # A malformed hooks section must not suppress the statusLine sync — it is
        # an independent settings surface.
        manifest = (
            build_manifest(template_hooks, hooks_dir)
            if isinstance(template_hooks, dict)
            else []
        )

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
    # A malformed live `hooks` section is a hook-registration failure, not a
    # whole-run failure: statusLine is an independent top-level surface, and the
    # sync below is the only thing that ever repairs its placeholder path.
    # Bailing here used to strand the status line permanently —
    # session-start-sync.sh runs this script every session, so one bad hooks
    # value silently disabled the single recurring repair path statusLine has.
    # Hook work is skipped and the malformed value is left exactly as the user
    # wrote it; the exit code still reports the failure, and only the
    # independent surface proceeds.
    #
    # --statusline-only never touches hooks, so their shape is none of its
    # business: it must neither warn nor fail on it. Step 6b reads any non-zero
    # exit as "statusLine sync failed" and warns the user about a placeholder
    # path that was in fact written correctly.
    hooks_broken = False
    if "hooks" not in settings:
        # Not in --statusline-only: seeding an empty hooks object there would
        # ride along in the atomic write below and persist a hooks change the
        # mode promised not to make.
        if not statusline_only:
            settings["hooks"] = {}
    elif not isinstance(settings["hooks"], dict):
        if not statusline_only:
            print("settings.json hooks section is not an object", file=sys.stderr)
            hooks_broken = True
        manifest = []

    live = settings["hooks"] if isinstance(settings.get("hooks"), dict) else {}

    added = 0
    for item in manifest:
        event = item["event"]
        if event not in live:
            live[event] = []
        elif not isinstance(live[event], list):
            # Same reasoning as the section-level check above, one level down: a
            # single malformed event must not abort the run and strand the
            # independent statusLine surface. Skip just this event, leave its
            # value as the user wrote it, and keep registering the rest.
            print(f"settings.json hooks[{event!r}] is not a list", file=sys.stderr)
            hooks_broken = True
            continue
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

    # Prune stale hook registrations (two cases, one pass; skipped when manifest
    # is empty, e.g. --statusline-only): (1) event-migration — script moved to a
    # different event type; (2) decommissioned — script absent from manifest,
    # inside a managed hooks root, and the file no longer exists. Pruning is
    # restricted to managed hook roots so third-party registrations are untouched.
    script_to_canonical_event = {item["script"]: item["event"] for item in manifest}
    manifest_scripts = {item["script"] for item in manifest}

    _legacy_env = os.environ.get("MANAGED_LEGACY_HOOKS_DIR", "")
    managed_hook_roots = {
        os.path.abspath(os.path.expanduser(p))
        for p in [hooks_dir, _legacy_env]
        if p
    }

    def is_managed_path(cmd_path):
        return os.path.abspath(
            os.path.expanduser(os.path.dirname(cmd_path))
        ) in managed_hook_roots

    removed_stale = 0
    for event in list(live.keys()) if manifest else []:
        if not isinstance(live[event], list):
            continue
        surviving_groups = []
        for group in live[event]:
            if not isinstance(group, dict):
                surviving_groups.append(group)
                continue
            surviving_hooks = []
            for h in (group.get("hooks") or []):
                if not isinstance(h, dict):
                    surviving_hooks.append(h)
                    continue
                exe = command_argv0(h.get("command", ""))
                basename = os.path.basename(exe)
                canonical = script_to_canonical_event.get(basename)

                # (1) Script moved to a different event — drop the stale entry.
                # Restricted to managed roots (or placeholders awaiting
                # migration) so third-party registrations are untouched.
                if (canonical is not None
                        and canonical != event
                        and (is_managed_path(exe) or is_placeholder(exe))):
                    removed_stale += 1
                    continue

                # (2) Decommissioned hook: not in manifest, inside a managed
                # hooks directory, and the script file no longer exists.
                # Placeholder paths are never pruned — they need migration, not
                # removal.
                if (exe
                        and basename not in manifest_scripts
                        and is_managed_path(exe)
                        and not is_placeholder(exe)
                        and not os.path.isfile(exe)):
                    removed_stale += 1
                    continue

                surviving_hooks.append(h)
            if surviving_hooks:
                new_group = dict(group)
                new_group["hooks"] = surviving_hooks
                surviving_groups.append(new_group)
            # else: all hooks in this group were stale — drop the group.
        if surviving_groups:
            live[event] = surviving_groups
        else:
            del live[event]

    # statusLine is a top-level settings surface, not a hook event, but it needs
    # the identical placeholder-to-worktree resolution and the same auto-propagate
    # behavior (issue #779). Folded into the same atomic write rather than a
    # second one, so settings.json is never left half-synced.
    statusline_changed = sync_statusline(settings, template, scripts_dir)

    if added == 0 and removed_stale == 0 and statusline_changed == 0:
        return 1 if hooks_broken else 0

    # Atomic write
    d = os.path.dirname(settings_file) or "."
    tmp = None
    try:
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        os.replace(tmp, settings_file)
    except OSError as e:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        print(f"hook-sync: atomic write failed: {e}", file=sys.stderr)
        return 1

    parts = []
    if added:
        parts.append(f"registered {added} new hook(s)")
    if removed_stale:
        parts.append(f"removed {removed_stale} stale event registration(s)")
    if statusline_changed:
        parts.append("synced statusLine command")
    print(f"hook-sync: {', '.join(parts)}", file=sys.stderr)
    return 1 if hooks_broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
