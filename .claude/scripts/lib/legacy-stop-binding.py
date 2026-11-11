#!/usr/bin/env python3
"""Verify one candidate legacy /end stop using bounded local runtime evidence."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
from urllib.parse import urlsplit

SCRIPTS = Path(__file__).resolve().parents[1]
UUID = re.compile(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", re.I)
REPO = re.compile(r"[a-z0-9_.-]+/[a-z0-9_.-]+", re.I)
SESSION = re.compile(r"[a-z0-9_./:-]{1,128}", re.I)
TOKEN = re.compile(r"[a-f0-9]{64}")
MAX_TRANSCRIPT = 64 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024


class EvidenceError(Exception):
    pass


def timestamp(value):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise EvidenceError("transcript timestamp is missing or malformed")
    try:
        return datetime.fromisoformat(value[:-1] + "+00:00").timestamp()
    except (ValueError, OverflowError) as error:
        raise EvidenceError("transcript timestamp is malformed") from error


def run(*args, cwd=None):
    try:
        return subprocess.check_output(args, cwd=cwd, stderr=subprocess.DEVNULL,
                                       text=True, encoding="utf-8", timeout=15).strip()
    except (OSError, subprocess.SubprocessError, UnicodeError) as error:
        raise EvidenceError("scope or gate could not be read") from error


def origin(cwd):
    raw = run("git", "config", "--local", "--get", "remote.origin.url", cwd=cwd)
    ssh = re.fullmatch(r"[^@]+@([^:]+):(.+)", raw)
    if ssh:
        host, path = ssh.groups()
    else:
        parsed = urlsplit(raw)
        if parsed.scheme not in ("https", "ssh") or not parsed.hostname:
            raise EvidenceError("origin identity is unsupported")
        host, path = parsed.hostname, parsed.path.lstrip("/")
    path = path.removesuffix(".git").lower()
    if not REPO.fullmatch(path):
        raise EvidenceError("origin identity is unsupported")
    return host.lower(), path


def activation_kind(command, legacy):
    """A literal helper invocation can prove scope. Other forms can conflict."""
    if not all(word in command for word in ("--activate", "--command", "end")):
        return None
    if "execution-pause" not in command and "EXECUTION_PAUSE_SH" not in command:
        return None
    try:
        words = shlex.split(command)
    except ValueError:
        return "unknown"
    if words and words[0] == "exec":
        words = words[1:]
    if not words or not Path(words[0]).is_absolute() or Path(words[0]).name != "execution-pause.sh":
        return "unknown"
    if any(character in command for character in "$&|;<>#\n\r"):
        return "unknown"
    values = {}
    tail = words[1:]
    if tail.count("--activate") != 1:
        return "unknown"
    tail.remove("--activate")
    if len(tail) % 2:
        return "unknown"
    for flag, value in zip(tail[::2], tail[1::2]):
        if flag not in ("--session", "--command", "--window-minutes", "--repo") or flag in values:
            return "unknown"
        values[flag] = value
    if values.get("--command") != "end" or not re.fullmatch(r"[0-9]+", values.get("--window-minutes", "")):
        return "unknown"
    key = values.get("--session", "")
    if not SESSION.fullmatch(key):
        return "unknown"
    if key != legacy:
        return None
    values["script_path"] = words[0]
    return values


def scope_matches(call, current_origin, cwd):
    command_scope = call.get("--repo")
    if command_scope is not None and command_scope.lower() != current_origin[1]:
        return False
    return bool(isinstance(cwd, str) and Path(cwd).is_absolute() and origin(cwd) == current_origin)


def trusted_helper(path):
    actual = Path(path).resolve(strict=True)
    candidates = (SCRIPTS / "execution-pause.sh",
                  Path.home() / ".claude/skills-worktree/.claude/scripts/execution-pause.sh",
                  Path.home() / ".claude/scripts/execution-pause.sh")
    return any(candidate.resolve() == actual for candidate in candidates)


def transcript_activations(path, legacy, gate_time):
    """Return potential activation windows. Read only top-level runtime events."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    calls = {}
    results = {}
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_TRANSCRIPT:
            raise EvidenceError("transcript exceeds the safe read boundary")
        scanned = 0
        while True:
            raw = stream.readline(MAX_TRANSCRIPT - scanned + 1)
            if not raw:
                break
            scanned += len(raw)
            if scanned > MAX_TRANSCRIPT:
                raise EvidenceError("transcript exceeds the safe read boundary")
            row = json.loads(raw)
            if not isinstance(row, dict) or row.get("sessionId", path.stem) != path.stem:
                raise EvidenceError("transcript session identity is inconsistent")
            message = row.get("message")
            if not isinstance(message, dict) or not isinstance(message.get("content"), list):
                continue
            for part in message["content"]:
                if not isinstance(part, dict):
                    continue
                if (row.get("type") == "assistant" and part.get("type") == "tool_use"
                        and part.get("name") == "Bash"):
                    arguments = part.get("input")
                    command = arguments.get("command") if isinstance(arguments, dict) else None
                    if not isinstance(command, str):
                        continue
                    kind = activation_kind(command.strip(), legacy)
                    if kind is None:
                        continue
                    start = timestamp(row.get("timestamp"))
                    if int(start) <= gate_time:
                        if row.get("sessionId") != path.stem:
                            raise EvidenceError("activation lacks native session identity")
                        key = part.get("id")
                        if not isinstance(key, str) or not key or key in calls:
                            raise EvidenceError("activation tool identity is ambiguous")
                        calls[key] = (kind, start, row.get("cwd"))
                elif row.get("type") == "user" and part.get("type") == "tool_result":
                    key = part.get("tool_use_id")
                    if isinstance(key, str) and key in calls:
                        if row.get("sessionId") != path.stem:
                            raise EvidenceError("activation result lacks native session identity")
                        if key in results:
                            raise EvidenceError("activation tool result is ambiguous")
                        results[key] = (timestamp(row.get("timestamp")), part.get("is_error", False))
        after = os.fstat(stream.fileno())
    current = path.lstat()
    if any((getattr(before, key), getattr(after, key)) != (getattr(current, key),) * 2
           for key in ("st_dev", "st_ino", "st_size", "st_mtime_ns")):
        raise EvidenceError("transcript changed during verification")
    matches = []
    for key, (kind, start, cwd) in calls.items():
        if key not in results:
            matches.append(("unknown", cwd))
            continue
        end, is_error = results[key]
        if end < start or type(is_error) is not bool:
            raise EvidenceError("activation result is malformed")
        if int(end) >= gate_time:
            # A failed tool can still have published a marker before failing.
            matches.append(("unknown" if is_error else kind, cwd))
    return matches


def projects_transcripts(project_roots, native, gate_time):
    selected = []
    candidates = []
    size = 0
    directories = [directory for projects in project_roots for directory in projects.iterdir()]
    for directory in directories:
        if directory.is_symlink():
            raise EvidenceError("transcript inventory contains a linked project")
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if path.suffix != ".jsonl" or not UUID.fullmatch(path.stem):
                continue
            meta = path.lstat()
            if path.stem == native:
                selected.append(path)
            if meta.st_mtime >= gate_time or path.stem == native:
                if not stat.S_ISREG(meta.st_mode):
                    raise EvidenceError("transcript inventory contains an unreadable candidate")
                size += meta.st_size
                if size > MAX_TOTAL:
                    raise EvidenceError("transcript inventory exceeds the safe read boundary")
                candidates.append(path)
    if len(selected) != 1:
        raise EvidenceError("selected native transcript is missing or ambiguous")
    return selected[0], candidates


def verify(repo, native, legacy, project_roots, cwd):
    if (not REPO.fullmatch(repo) or not UUID.fullmatch(native)
            or not SESSION.fullmatch(legacy) or legacy == native):
        raise EvidenceError("invalid legacy stop scope")
    current_origin = origin(cwd)
    if current_origin[1] != repo.lower():
        raise EvidenceError("current checkout does not match the requested repository")
    snapshot = json.loads(run(str(SCRIPTS / "execution-pause.sh"), "--repo", repo,
                              "--snapshot-legacy", "--session", legacy))
    if not isinstance(snapshot, dict) or not TOKEN.fullmatch(snapshot.get("token", "")):
        raise EvidenceError("legacy gate token is unreadable")
    gate_time = int(timestamp(snapshot.get("at")))
    selected, candidates = projects_transcripts(project_roots, native, gate_time)
    proof = transcript_activations(selected, legacy, gate_time)
    if len(proof) != 1 or not isinstance(proof[0][0], dict):
        raise EvidenceError("selected transcript lacks one exact legacy activation")
    call, activation_cwd = proof[0]
    if not trusted_helper(call["script_path"]) or not scope_matches(call, current_origin, activation_cwd):
        raise EvidenceError("activation repository does not match")
    for other in candidates:
        if other == selected:
            continue
        for kind, activation_cwd in transcript_activations(other, legacy, gate_time):
            if kind == "unknown" or scope_matches(kind, current_origin, activation_cwd):
                raise EvidenceError("another activation may match the legacy gate")
    return {"verdict": "verified", "repo": repo, "native_session": native,
            "legacy_session": legacy, "gate_token": snapshot["token"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--native-session", required=True)
    parser.add_argument("--legacy-session", required=True)
    args = parser.parse_args()
    primary = Path.home() / ".claude/projects"
    profile = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"
    try:
        roots = [profile.resolve(strict=True)]
        if primary.exists() and primary.resolve() not in roots:
            roots.append(primary.resolve())
        verdict = verify(args.repo, args.native_session, args.legacy_session,
                         roots, Path.cwd())
    except EvidenceError as error:
        verdict = {"verdict": "held", "reason": str(error)}
    except (OSError, ValueError, TypeError):
        verdict = {"verdict": "held", "reason": "local evidence is unreadable"}
    print(json.dumps(verdict, separators=(",", ":")))
    return 0 if verdict["verdict"] == "verified" else 1


if __name__ == "__main__":
    raise SystemExit(main())
