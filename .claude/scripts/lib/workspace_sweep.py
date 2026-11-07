"""Cadence adapter only: stale-cleanup owns every destructive decision."""
import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import time


LIMIT = 16 * 1024 * 1024


def command(args, cwd=None, timeout=15, evidence=None, record_row=None):
    # Files bound resident memory; a whole process group owns the deadline.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        proc = subprocess.Popen(args, cwd=cwd, stdout=out, stderr=err,
                                start_new_session=True)
        failure = None
        try:
            proc.wait(timeout=timeout)
        except BaseException as exc:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            failure = exc
        oversized = out.tell() > LIMIT or err.tell() > LIMIT
        out.seek(0)
        err.seek(0)
        stdout, stderr = out.read(LIMIT), err.read(LIMIT)
        if evidence is not None:
            # Includes the helper's refused-path directory listing. Captures
            # survive subsequent clean runs; user output stays decision-only.
            folder = Path(tempfile.mkdtemp(prefix="run-", dir=evidence))
            if record_row is not None:
                record_row['evidence'] = str(folder)
            for name, body in (("stdout", stdout), ("stderr", stderr),
                               ("exit-code", str(proc.returncode).encode()),
                               ("capture.json", json.dumps({"output_limit_exceeded": oversized,
                                "exception": type(failure).__name__ if failure else None}).encode())):
                fd = private_open(folder / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
                with os.fdopen(fd, "wb") as stream:
                    stream.write(body)
        if failure is not None:
            raise failure
        if oversized:
            raise ValueError("command output exceeds limit")
        return proc.returncode, stdout.decode("utf-8")


def git(path, *args):
    rc, result = command(["git", "-C", str(path), *args])
    if rc:
        raise ValueError("repository unavailable")
    return result.strip()


def identity(path):
    root = Path(git(path, "rev-parse", "--show-toplevel")).resolve()
    common = Path(git(root, "rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = root / common
    common = common.resolve()
    return root, hashlib.sha256(os.fsencode(common)).hexdigest()


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("unsafe sweep state directory")


def private_open(path, flags):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1 or info.st_mode & 0o077):
        os.close(fd)
        raise ValueError("unsafe sweep state file")
    return fd


@contextlib.contextmanager
def lock(path, wait=0):
    fd = private_open(path, os.O_RDWR | os.O_CREAT)
    try:
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.02)
        yield
    finally:
        os.close(fd)


def load(path, default):
    try:
        fd = private_open(path, os.O_RDONLY)
    except FileNotFoundError:
        return default
    with os.fdopen(fd) as stream:
        text = stream.read(LIMIT + 1)
    if len(text) > LIMIT:
        raise ValueError("state exceeds limit")
    try:
        return json.loads(text)
    except ValueError:
        return default


def save(path, value):
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".publish-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


def register(base, root, key, now):
    # Persist the main checkout rather than a feature worktree about to finish.
    listed = git(root, "worktree", "list", "--porcelain")
    main = next((line[9:] for line in listed.splitlines() if line.startswith("worktree ")), None)
    if main and identity(main)[1] == key:
        root = Path(main)
    with lock(base / "registry.lock"):
        registry = load(base / "repos.json", {})
        if not isinstance(registry, dict):
            raise ValueError("invalid repository registry")
        registry[key] = {"path": str(root), "seen": now}
        save(base / "repos.json", registry)


def configured(base, home, now):
    explicit = home / ".claude/workspace-sweep-repos"
    if explicit.exists():
        # One literal absolute checkout path per line. Never shell-evaluated.
        if explicit.stat().st_size > LIMIT:
            raise ValueError("repository list exceeds limit")
        return [line for line in explicit.read_text().splitlines()
                if line.strip() and not line.lstrip().startswith("#")]
    registry = load(base / "repos.json", {})
    if not isinstance(registry, dict):
        raise ValueError("invalid repository registry")
    # Bootstrap pre-existing sessions using stored absolute paths, never keys.
    sessions = load(home / ".claude/session-state.json", {})
    repos = sessions.get("repos", {}) if isinstance(sessions, dict) else {}
    if isinstance(repos, dict):
        for repo in repos.values():
            if not isinstance(repo, dict):
                continue
            candidates = [repo]
            prs = repo.get("prs", {})
            if isinstance(prs, dict):
                candidates += [p for p in prs.values() if isinstance(p, dict)]
            for entry in candidates:
                path = entry.get("root_repo")
                if not isinstance(path, str) or not Path(path).is_absolute():
                    continue
                action = entry.get("last_cron_action", {})
                at = action.get("at") if isinstance(action, dict) else None
                seen = 0
                if isinstance(at, str):
                    try:
                        date = datetime.fromisoformat(at.replace("Z", "+00:00"))
                        if date.tzinfo is not None:
                            seen = int(date.astimezone(timezone.utc).timestamp())
                    except (ValueError, OverflowError):
                        pass
                registry.setdefault("session:" + path, {"path": path, "seen": seen})
    paths = []
    for entry in registry.values():
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            continue
        recent = (type(entry.get("seen")) is int and 0 <= now - entry["seen"] <= 14 * 86400)
        if recent:
            paths.append(entry["path"])
        else:
            try:
                # Only actual registered linked worktrees qualify, not a folder.
                listed = git(entry["path"], "worktree", "list", "--porcelain")
                if any(line.startswith("worktree ") and "/.claude/worktrees/" in line
                       for line in listed.splitlines()):
                    paths.append(entry["path"])
            except (OSError, ValueError, subprocess.TimeoutExpired):
                paths.append(entry["path"])  # log the stale/moved path below
    return paths


def record(base, row):
    with lock(base / "log.lock", wait=5):
        fd = private_open(base / "runs.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND)
        with os.fdopen(fd, "a") as stream:
            stream.write(json.dumps(row, separators=(",", ":")) + "\n")


def sweep(base, path, args, now):
    row = {"at": now, "repo": str(path), "trigger": args.trigger,
           "removed": 0, "skipped_with_reason": 0}
    try:
        if not Path(path).is_absolute():
            raise ValueError("repository path must be absolute")
        root, key = identity(path)
        register(base, root, key, now)
        with lock(base / (key + ".lock")):
            stamp = base / (key + ".json")
            previous = load(stamp, {})
            last = previous.get("attempted_at") if isinstance(previous, dict) else None
            if (args.trigger == "pm-day" and type(last) is int
                    and 0 <= now - last < args.min_interval):
                return 0
            helper = os.environ.get("WORKSPACE_SWEEP_CLEANUP_SH")
            if not helper:
                helper = str(Path(__file__).resolve().parents[1] / "stale-cleanup.sh")
            # A killed/invalid adapter may have completed some safe removals
            # before losing its final report. Never label unproved counts zero.
            row.update(removed=None, skipped_with_reason=None)
            rc, raw = command(["/bin/bash", helper, "--apply-finished", "--root", str(root), "--json"],
                              cwd=root, timeout=300, evidence=base, record_row=row)
            report = json.loads(raw)
            if not isinstance(report, dict) or report.get("finished_scan") not in ("complete", "incomplete"):
                raise ValueError("finished-only cleanup interface unavailable")
            arrays = [report.get(k) for k in ("finished_worktrees", "skipped_finished_worktrees",
                                             "unknown_finished_worktrees", "finished_apply")]
            if any(not isinstance(a, list) or any(not isinstance(r, dict) for r in a) for a in arrays):
                raise ValueError("invalid finished-only cleanup report")
            _, skipped, unknown, applied = arrays
            if any(not isinstance(r.get("path"), str) or not isinstance(r.get("reason"), str)
                   for r in skipped + unknown + applied):
                raise ValueError("invalid cleanup outcome identity/reason")
            row["removed"] = sum(r.get("worktree_removed") is True for r in applied)
            retained = {r.get("path"): r.get("reason", "unknown") for r in skipped + unknown}
            retained.update({r.get("path"): r.get("reason", "unknown") for r in applied
                             if r.get("outcome") != "removed"})
            row["skipped_with_reason"] = len(retained)
            row["reasons"] = sorted(set(str(r) for r in retained.values()))
            ordinary = {"desktop_session_liveness_unknown"}
            action = [r.get("reason", "unknown") for r in unknown if r.get("reason") not in ordinary]
            action += [r.get("reason", "unknown") for r in applied if r.get("outcome") == "failed"]
            if rc not in (0, 1, 2):
                raise ValueError("cleanup could not complete")
            save(stamp, {"attempted_at": now})
            row["action"] = sorted(set(action))
            record(base, row)
            if action:
                print("Workspace sweep needs attention: " + str(root) + "; " + ", ".join(row["action"]))
            return int(bool(action))
    except BlockingIOError:
        row["status"] = "busy"
        with contextlib.suppress(BlockingIOError):
            record(base, row)
        return 0
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        row["action"] = [str(exc)]
        record(base, row)
        print("Workspace sweep needs attention: " + str(path) + "; " + str(exc))
        return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trigger", choices=("post-merge", "pm-day", "daily"), default="daily")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--repo-dir")
    group.add_argument("--configured", action="store_true")
    group.add_argument("--register-repo")
    parser.add_argument("--min-interval", type=int, default=3600)
    parser.add_argument("--now", type=int, help="offline fixture clock")
    args = parser.parse_args()
    if args.min_interval < 0:
        parser.error("interval must be nonnegative")
    now = int(time.time()) if args.now is None else args.now
    home = Path.home()
    base = home / ".claude/workspace-sweep"
    try:
        private_dir(base)
        if args.register_repo:
            root, key = identity(args.register_repo)
            register(base, root, key, now)
            return 0
        paths = configured(base, home, now) if args.configured else [args.repo_dir]
        seen, result = set(), 0
        for path in paths:
            try:
                _, key = identity(path)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                key = path
            if key in seen:
                continue
            seen.add(key)
            result = max(result, sweep(base, path, args, now))
        return result
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        if args.register_repo:
            return 0  # SessionStart registration is deliberately fail-open/silent.
        print("Workspace sweep needs attention: " + str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
