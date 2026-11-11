#!/usr/bin/env python3
"""Capture explicitly marked Decisions; never read a conversation transcript."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import time
import unicodedata

import capture

MAX_INPUT = 256 * 1024
MAX_BLOCK = 4096
OPEN = "```desk-decision"
CLOSE = "```"
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.I)
EVENT_ID = re.compile(r"[A-Za-z0-9_.:-]{1,128}")
HEX = re.compile(r"[0-9a-f]{64}")
WORK_REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


class Invalid(ValueError):
    pass


def symbol_joiner(value, index):
    # Recognize a joiner between symbols (including the previous symbol's
    # optional variation selector and skin tone). A joiner inside plain
    # text could hide a credential pattern or change an identifier.
    left = index - 1
    if left >= 0 and "\U0001f3fb" <= value[left] <= "\U0001f3ff":
        left -= 1
    if left >= 0 and value[left] == "\ufe0f":
        left -= 1
    return (left >= 0 and index + 1 < len(value)
            and unicodedata.category(value[left]) == "So"
            and unicodedata.category(value[index + 1]) == "So")


def text(value, limit, *, display=False):
    if (not isinstance(value, str) or not 0 < len(value) <= limit
            or value != value.strip()
            or any(ch in "\u2028\u2029" or
                   (unicodedata.category(ch).startswith("C")
                    and not (display and ch == "\u200d" and symbol_joiner(value, i)))
                   for i, ch in enumerate(value))):
        raise Invalid("a Decision field is not a bounded single line")
    # The store refuses format controls. Keep the visible symbols as
    # separate emoji rather than rejecting the entire Decision.
    return value.replace("\u200d", "") if display else value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid("the Decision repeats a JSON field")
        result[key] = value
    return result


def decision_block(message):
    if not isinstance(message, str):
        return None
    lines = message.rstrip().splitlines()
    opens = [i for i, line in enumerate(lines) if line == OPEN]
    if not opens:
        return None
    if len(opens) != 1 or lines[-1] != CLOSE or any(line == CLOSE for line in lines[opens[0] + 1:-1]):
        raise Invalid("a single Decision block must be the last part of the message")
    raw = "\n".join(lines[opens[0] + 1:-1])
    if len(raw.encode("utf-8")) > MAX_BLOCK:
        raise Invalid("the Decision block is too large")
    item = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(item, dict) or set(item) - {"question", "options", "default", "context"}:
        raise Invalid("the Decision block contains an unknown field")
    question = text(item.get("question"), 500, display=True)
    context = item.get("context", [])
    options = item.get("options", [])
    if not isinstance(context, list) or len(context) > 3:
        raise Invalid("the Decision needs at most three context lines")
    if not isinstance(options, list) or not 2 <= len(options) <= 4:
        raise Invalid("the Decision needs two to four options")
    context = [text(line, 600, display=True) for line in context]
    options = [text(option, 500, display=True) for option in options]
    default = item.get("default")
    if default is not None:
        default = text(default, 500, display=True)
    if (sum(map(len, context)) > 600 or len(set(options)) != len(options)
            or (default is not None and default not in options)):
        raise Invalid("the Decision context, options or default is invalid")
    return question, context, options, default


def private_bytes(path, limit):
    """Read a bounded, user-owned file without following a final symlink."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as src:
        st = os.fstat(src.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > limit:
            raise Invalid("the local configuration is unsafe or too large")
        raw = src.read(limit + 1)
        if len(raw) > limit:
            raise Invalid("the local configuration is too large")
        return raw, st.st_mode


def registry():
    path = Path(os.environ.get("AI_QUOTAS_CONFIG") or Path.home() / ".claude" / "ai-quotas.json")
    try:
        raw, mode = private_bytes(path, MAX_INPUT)
        if mode & 0o022:
            return []
        data = json.loads(raw)
        if isinstance(data, dict) and isinstance(data.get("accounts"), list):
            return [row for row in data["accounts"] if isinstance(row, dict)]
    except (OSError, ValueError, UnicodeError, RecursionError):
        pass
    return []


def real_directory(value):
    try:
        path = Path(value)
        if path.is_absolute() and path.is_dir():
            return path.resolve(strict=True)
    except (OSError, TypeError, ValueError, RuntimeError):
        pass
    return None


def nickname(row):
    try:
        return text(row.get("nickname"), 32)
    except Invalid:
        return "unknown"


def route_path():
    return Path.home() / ".claude" / "desk-decision-route-id"


def local_route_id():
    try:
        raw, mode = private_bytes(route_path(), 65)
        value = raw.decode("ascii").strip()
        if not mode & 0o077 and HEX.fullmatch(value):
            return value
    except (OSError, ValueError):
        pass
    return None


def init_route():
    if local_route_id():
        return
    path = route_path()
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise Invalid("the installed .claude directory is unavailable")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as dst:
        dst.write(secrets.token_hex(32) + "\n")


def digest(*parts):
    return hashlib.sha256(json.dumps(parts, ensure_ascii=True, separators=(",", ":")).encode()).hexdigest()


def profile_route(seed, profile):
    return digest("desk-codex-route-v1", seed, str(profile))


def source_account(tool, payload, rows):
    candidates = [row for row in rows if row.get("provider") == tool]
    if tool == "cursor":
        email = payload.get("user_email")
        matches = [row for row in candidates if isinstance(email, str) and email
                   and isinstance(row.get("label"), str) and row["label"].casefold() == email.casefold()]
        return (nickname(matches[0]) if len(matches) == 1 else "unknown"), None
    profile = real_directory(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    matches = [row for row in candidates if profile and real_directory(row.get("profile_dir")) == profile]
    if len(matches) != 1:
        return "unknown", None
    seed = local_route_id()
    return nickname(matches[0]), profile_route(seed, profile) if seed else None


def event(tool, payload):
    if not isinstance(payload, dict):
        raise Invalid("the hook input is not an object")
    if tool == "codex":
        if payload.get("hook_event_name") != "Stop":
            return None
        message = payload.get("last_assistant_message")
        cwd, sid, generation = (payload.get(k) for k in ("cwd", "session_id", "turn_id"))
    else:
        if payload.get("hook_event_name") != "afterAgentResponse":
            return None
        message = payload.get("text")
        roots = payload.get("workspace_roots")
        cwd = roots[0] if isinstance(roots, list) and len(roots) == 1 else None
        sid, generation = (payload.get(k) for k in ("conversation_id", "generation_id"))
    item = decision_block(message)
    if item is None:
        return None
    if not (real_directory(cwd) and isinstance(sid, str) and EVENT_ID.fullmatch(sid)
            and isinstance(generation, str) and EVENT_ID.fullmatch(generation)):
        raise Invalid("the Decision has no exact workspace or event identity")
    if tool == "codex":
        if not UUID.fullmatch(sid):
            raise Invalid("the Codex thread ID is not an exact UUID")
        sid = sid.lower()
    return item, cwd, sid, generation


def store_for(hook):
    # The account's queue and binding name, as the capture hook resolves them
    # (issue #2184): the queue refuses a call whose name is not its owner. An
    # unbound account raises FailOpen here, as it does for the capture hook.
    schema, binding = capture.queue_for_this_account()
    env = dict(os.environ, HUMAN_QUEUE_DATABASE_URL=capture.resolve_url(hook),
               HUMAN_QUEUE_SCHEMA=schema, HUMAN_QUEUE_BINDING=binding)
    return capture.Store(hook, capture.resolve_cli(), env)


def submit(store, tool, account, route, sid, repo, key, capture_key, item):
    question, context, options, default = item
    argv = ["add", "--kind", "decision", "--repo", repo, "--key", key,
            "--question", question, "--source-tool", tool, "--source-account", account,
            "--capture-key", capture_key]
    if route:
        argv += ["--return-route", route, "--session", sid]
    for line in context:
        argv += ["--context", line]
    for option in options:
        argv += ["--option", option]
    if default:
        argv += ["--default", default]
    result = store.call(argv, "Decision capture").strip()
    if not capture.ID_RE.fullmatch(result):
        raise Invalid("the queue did not return a Decision ID")
    return result


def read_input():
    value = sys.stdin.buffer.read(MAX_INPUT + 1)
    if len(value) > MAX_INPUT:
        raise Invalid("the input is too large")
    return value.decode("utf-8")


def hook_capture(mode, hook):
    payload = json.loads(read_input())
    found = event(mode, payload)
    if not found:
        return
    item, cwd, sid, generation = found
    store = store_for(hook)
    if capture.live_control_session(hook, store) is None:
        return
    # Account identity comes from the native event or the Codex process
    # environment, never from the assistant's Decision block.
    account, route = source_account(mode, payload, registry())
    repo, key = capture.repo_and_key(hook, cwd, sid)
    submit(store, mode, account, route, sid, repo, key,
           digest(mode, sid, generation), item)


def codex_binary():
    # The worktree and PATH may be controlled by the repository containing
    # the question. Only use an installed launcher or an explicit host path.
    configured = os.environ.get("DESK_CODEX_BIN")
    paths = [Path(configured)] if configured else [
        Path("/opt/homebrew/bin/codex"), Path("/usr/local/bin/codex"),
        Path("/usr/bin/codex"), Path.home() / ".local" / "bin" / "codex",
    ]
    for path in paths:
        if not path.is_absolute():
            continue
        try:
            actual = path.resolve(strict=True)
            info = actual.stat()
            if (stat.S_ISREG(info.st_mode) and info.st_uid in {0, os.getuid()}
                    and not info.st_mode & 0o022 and os.access(actual, os.X_OK)):
                return actual
        except (OSError, RuntimeError):
            pass
    return None


def wake(hook, item_id):
    if not capture.ID_RE.fullmatch(item_id):
        raise Invalid("an exact Decision ID is required")
    row = json.loads(store_for(hook).call(["get", item_id, "--json"], "Decision lookup"))
    if row.get("id") != item_id or row.get("source_tool") != "codex" or row.get("status") != "answered":
        return 5
    route, sid, seed = row.get("return_route"), row.get("session_id"), local_route_id()
    if not (isinstance(route, str) and HEX.fullmatch(route)
            and isinstance(sid, str) and UUID.fullmatch(sid) and seed):
        return 5
    paths = [real_directory(r.get("profile_dir")) for r in registry() if r.get("provider") == "codex"]
    matches = [path for path in paths if path and profile_route(seed, path) == route]
    if len(matches) != 1:
        return 5
    binary = codex_binary()
    if binary is None:
        return 5
    env = dict(capture.git_env(), CODEX_HOME=str(matches[0]))
    rc, _, _ = capture.run_bounded(hook, [str(binary), "queue", "--thread", sid, "--message",
                                          f"human-queue: {item_id} answered"], env, 5, "Codex queue")
    return 0 if rc == 0 else 5


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="mode", required=True)
    for mode in ("codex", "cursor", "init-route"):
        commands.add_parser(mode)
    imp = commands.add_parser("import")
    imp.add_argument("--repo", required=True)
    imp.add_argument("--key", required=True)
    commands.add_parser("wake").add_argument("id")
    args = parser.parse_args()
    hook = capture.Hook(time.monotonic())
    native = args.mode in {"codex", "cursor"}
    try:
        if native:
            hook_capture(args.mode, hook)
        elif args.mode == "init-route":
            init_route()
        elif args.mode == "wake":
            return wake(hook, args.id)
        else:
            if not WORK_REPO.fullmatch(args.repo) or len(args.repo) > 200:
                raise Invalid("a canonical owner/repo is required")
            key = text(args.key, 200)
            item = decision_block(read_input())
            if item is None:
                raise Invalid("no Decision block found")
            token = digest("local", args.repo, key, item)
            print(submit(store_for(hook), "local", "unknown", None, None, args.repo, key, token, item))
    except (capture.FailOpen, OSError, ValueError, RecursionError, TypeError):
        # Do not echo hook payloads, paths, database errors or registry values.
        print("desk: external Decision operation unavailable", file=sys.stderr)
        if not native:
            return 5
    if args.mode == "codex":
        print("{}")  # Stop accepts JSON; never ask it to extend the turn.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
