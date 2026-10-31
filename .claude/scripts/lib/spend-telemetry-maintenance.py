#!/usr/bin/env python3
"""Bounded maintenance for private spend-telemetry cursors and append spool."""

import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


LOCK_WAIT_SECONDS = 0.25
LOG_SCAN_SECONDS = 2.0
LOG_SCAN_BYTES = 4 * 1024 * 1024
MAX_STATUS_CURSORS = 4096
REFRESH_SECONDS = 20.0
MAX_PENDING_ROWS = 256
MAX_CHILD_CURSORS = 128


def pending_files(directory):
    try:
        return sorted(Path(directory).glob("pending-*.tsv"))
    except OSError:
        return []


def cursor_metadata(cursor_path):
    try:
        saved = json.loads(Path(cursor_path).read_text(encoding="utf-8"))
        if not isinstance(saved, dict):
            return None
        meta = saved.get("metadata")
        if not isinstance(meta, dict):
            return None
        required = ("cursor_identity", "cursor_path_input", "transcript_path", "exec_type",
                    "session_id", "agent_id", "agent_type", "cwd", "repo_root", "repo_slug",
                    "phase", "transcript_scope")
        if any(not isinstance(meta.get(key), str) for key in required):
            return None
        identity = hashlib.sha256("\0".join((meta["session_id"], meta["agent_id"],
            meta["transcript_scope"], meta["cursor_path_input"])).encode("utf-8", errors="replace")).hexdigest()
        if identity != meta["cursor_identity"] or Path(cursor_path).stem != identity:
            return None
        if len(meta["transcript_path"]) > 4096 or not os.path.isabs(meta["transcript_path"]):
            return None
        if len(meta["cursor_path_input"]) > 4096:
            return None
        return saved
    except (OSError, ValueError, TypeError):
        return None


def child_cursors(cursor_dir, paths=None, deadline=None):
    pending = []
    unavailable = 0
    try:
        cursors = paths if paths is not None else sorted(Path(cursor_dir).glob("*.offset"))
    except OSError:
        return pending, unavailable
    deadline = deadline if deadline is not None else time.monotonic() + LOG_SCAN_SECONDS
    complete = len(cursors) <= MAX_STATUS_CURSORS
    for cursor in cursors[:MAX_STATUS_CURSORS]:
        if time.monotonic() >= deadline:
            complete = False
            break
        saved = cursor_metadata(cursor)
        if saved is None:
            continue
        meta = saved["metadata"]
        if meta["exec_type"] != "inline" or meta["transcript_scope"] != "subagent":
            continue
        try:
            stat = os.stat(meta["transcript_path"])
        except OSError:
            unavailable += 1
            continue
        offset = saved.get("offset")
        if type(offset) is not int or offset < 0:
            pending.append((cursor, saved))
            continue
        same_file = saved.get("device") == stat.st_dev and saved.get("inode") == stat.st_ino
        same_size_rewrite = saved.get("size") == stat.st_size and saved.get("mtime_ns") != stat.st_mtime_ns
        if not same_file or same_size_rewrite or offset > stat.st_size or offset < stat.st_size:
            pending.append((cursor, saved))
    return pending, unavailable if complete else -1


def pending_summary(log_path, cursor_dir):
    queue = os.path.join(os.path.dirname(log_path), "spend-telemetry-pending")
    children, unavailable = child_cursors(cursor_dir)
    return {"drained": 0, "duplicate_spool_rows_removed": 0,
            "pending_writes": len(pending_files(queue)), "resumed_children": 0,
            "pending_children": len(children) if unavailable >= 0 else -1, "unavailable_child_sources": unavailable,
            "status": "observed"}


def line_fingerprint(line):
    raw = line.encode("utf-8") if isinstance(line, str) else line
    return hashlib.sha256(raw).hexdigest()


def save_private(path, state):
    """Atomic, durable metadata checkpoint; never acknowledge before fsync."""
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    fd, temporary = tempfile.mkstemp(prefix=".checkpoint-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(directory, os.O_RDONLY)
        try: os.fsync(directory_fd)
        finally: os.close(directory_fd)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def load_private(path):
    try:
        with open(path, encoding="utf-8") as stream:
            value = json.load(stream)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def spool_line(path):
    try:
        raw = path.read_bytes()
        if raw.endswith(b"\n") and raw.count(b"\n") == 1:
            raw.decode("utf-8")
            return raw
    except (OSError, UnicodeDecodeError):
        pass
    return None


def scan_boundary(stream, offset):
    stream.seek(max(0, offset - 256))
    return line_fingerprint(stream.read(min(offset, 256)))


def drain_spool(log_path, queue, refresh_deadline=None):
    files = pending_files(queue)
    if not files:
        return 0, 0, 0, "empty"
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        os.makedirs(queue, mode=0o700, exist_ok=True)
        os.chmod(queue, 0o700)
        lock = open(log_path + ".lock", "a", encoding="ascii")
    except OSError:
        return 0, 0, len(files), "storage_unavailable"
    with lock:
        deadline = min(time.monotonic() + LOCK_WAIT_SECONDS, refresh_deadline or float("inf"))
        while True:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    return 0, 0, len(pending_files(queue)), "log_lock_busy"
                time.sleep(.01)
        checkpoint = os.path.join(queue, ".drain-scan.json")
        saved = load_private(checkpoint)
        # Freeze a bounded batch. New spool files cannot invalidate its progress.
        batch = saved.get("batch")
        if not isinstance(batch, dict) or not batch or len(batch) > MAX_PENDING_ROWS:
            batch = {}
            for spool in files[:MAX_PENDING_ROWS]:
                raw = spool_line(spool)
                if raw is not None: batch[spool.name] = line_fingerprint(raw)
            saved = {}
        lines = {}
        for name, fingerprint in batch.items():
            if not isinstance(name, str) or Path(name).name != name or not name.startswith("pending-"):
                continue
            raw = spool_line(Path(queue) / name)
            if raw is not None and line_fingerprint(raw) == fingerprint:
                lines[name] = raw
        if not lines:
            save_private(checkpoint, {})
            return 0, 0, len(pending_files(queue)), "invalid_spool_rows"
        try:
            output = open(log_path, "a+b")
        except OSError:
            return 0, 0, len(pending_files(queue)), "storage_unavailable"
        with output:
            stat = os.fstat(output.fileno())
            offset = saved.get("offset", 0)
            valid = (type(offset) is int and 0 <= offset <= stat.st_size and
                saved.get("device") == stat.st_dev and saved.get("inode") == stat.st_ino and
                not (saved.get("size") == stat.st_size and saved.get("mtime_ns") != stat.st_mtime_ns) and
                saved.get("boundary") == scan_boundary(output, offset))
            matched = set(saved.get("matched", [])) & set(batch.values()) if valid else set()
            if not valid: offset = 0
            output.seek(offset)
            scan_start = offset
            deadline = min(time.monotonic() + LOG_SCAN_SECONDS, refresh_deadline or float("inf"))
            target = stat.st_size
            while offset < target and offset - scan_start < LOG_SCAN_BYTES and time.monotonic() < deadline:
                raw = output.readline(LOG_SCAN_BYTES + 1)
                # Do not checkpoint past or append behind a partial log record.
                if not raw.endswith(b"\n"): break
                offset = output.tell()
                fingerprint = line_fingerprint(raw)
                if fingerprint in batch.values(): matched.add(fingerprint)
            state = dict(batch=batch, offset=offset, device=stat.st_dev, inode=stat.st_ino,
                         size=stat.st_size, mtime_ns=stat.st_mtime_ns,
                         boundary=scan_boundary(output, offset), matched=sorted(matched))
            save_private(checkpoint, state)
            if offset < target:
                return 0, 0, len(pending_files(queue)), "log_scan_limit"
            # The durable checkpoint stays at PRE-APPEND EOF. If we crash after
            # append, the next refresh scans that tail and recognizes the replay.
            current = os.stat(log_path)
            if (current.st_dev, current.st_ino) != (stat.st_dev, stat.st_ino):
                return 0, 0, len(pending_files(queue)), "log_rotated"
            output.seek(0, os.SEEK_END)
            drained = duplicates = 0
            for raw in lines.values():
                fingerprint = line_fingerprint(raw)
                if fingerprint in matched:
                    duplicates += 1
                else:
                    output.write(raw)
                    matched.add(fingerprint)
                    drained += 1
            output.flush()
            os.fsync(output.fileno())  # Includes duplicate-only cleanup.
            current = os.stat(log_path)
            if (current.st_dev, current.st_ino) != (stat.st_dev, stat.st_ino):
                return drained, duplicates, len(pending_files(queue)), "log_rotated"
            for name in lines:
                try: (Path(queue) / name).unlink()
                except OSError: pass
            directory_fd = os.open(queue, os.O_RDONLY)
            try: os.fsync(directory_fd)
            finally: os.close(directory_fd)
            save_private(checkpoint, {})
    return drained, duplicates, len(pending_files(queue)), "drained"


def resume_children(cursor_dir, hook_path, deadline=None):
    deadline = deadline if deadline is not None else time.monotonic() + REFRESH_SECONDS
    os.makedirs(cursor_dir, mode=0o700, exist_ok=True)
    os.chmod(cursor_dir, 0o700)
    fd = os.open(os.path.join(cursor_dir, ".resume-queue.lock"), os.O_WRONLY | os.O_CREAT, 0o600)
    with os.fdopen(fd, "w") as lock:
        # Concurrent refreshes must not move the durable rotation pointer back.
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            children, unavailable = child_cursors(cursor_dir, deadline=deadline)
            return 0, len(children) if unavailable >= 0 else -1, unavailable, False
        return resume_children_locked(cursor_dir, hook_path, deadline)


def resume_children_locked(cursor_dir, hook_path, deadline):
    progress_path = os.path.join(cursor_dir, ".resume-queue.json")
    previous = load_private(progress_path).get("after", "")
    paths = sorted(Path(cursor_dir).glob("*.offset"))
    # Rotate RAW cursor paths, so invalid/completed/unavailable prefix entries
    # also consume a bounded visit and cannot starve later pending sources.
    paths = [p for p in paths if p.name > str(previous)] + [p for p in paths if p.name <= str(previous)]
    resumed = 0
    for cursor in paths[:MAX_CHILD_CURSORS]:
        if time.monotonic() >= deadline:
            break
        save_private(progress_path, {"after": cursor.name})
        candidates, _ = child_cursors(cursor_dir, [cursor], deadline)
        if not candidates:
            continue
        _, saved = candidates[0]
        meta = saved["metadata"]
        path = meta["transcript_path"]
        if not os.path.isfile(path):
            continue
        payload = {"session_id": meta["session_id"], "agent_id": meta["agent_id"],
                   "agent_type": meta["agent_type"], "cwd": meta["cwd"],
                   "repo_root": meta["repo_root"], "repo_slug": meta["repo_slug"],
                   # Reopen via the validated absolute path. Preserve the
                   # original input separately because it participates in the
                   # stable cursor identity, and may have been relative to a
                   # worktree that has since disappeared.
                   "agent_transcript_path": path,
                   "resume_cursor_path_input": meta["cursor_path_input"]}
        resume_env = os.environ.copy()
        resume_env["CLAUDE_SPEND_TELEMETRY_RESUME"] = "1"
        # A persisted unknown is not a license to borrow the report process's
        # session identity. The transcript may supply one; otherwise it stays unknown.
        resume_env["CLAUDE_CODE_SESSION_ID"] = ""
        resume_env["CLAUDE_SESSION_ID"] = ""
        previous_offset = saved.get("offset")
        if type(previous_offset) is not int or previous_offset < 0:
            previous_offset = -1
        for _ in range(10):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                subprocess.run(["bash", hook_path], input=json.dumps(payload), text=True,
                    encoding="utf-8", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    env=resume_env, timeout=min(4.5, max(.1, remaining)), check=False)
                resumed += 1
            except (OSError, subprocess.TimeoutExpired):
                break
            still_pending, _ = child_cursors(cursor_dir, [cursor], deadline)
            updated = next((item for candidate, item in still_pending if candidate == cursor), None)
            if updated is None:
                break
            offset = updated.get("offset", 0)
            if type(offset) is not int or offset <= previous_offset:
                break
            previous_offset = offset
    remaining_children, unavailable_after = child_cursors(cursor_dir, deadline=deadline)
    return resumed, len(remaining_children) if unavailable_after >= 0 else -1, unavailable_after, time.monotonic() >= deadline


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("status", "refresh"):
        raise SystemExit("usage: spend-telemetry-maintenance.py status|refresh LOG_PATH CURSOR_DIR")
    mode, log_path, cursor_dir = sys.argv[1:]
    queue = os.path.join(os.path.dirname(log_path), "spend-telemetry-pending")
    if mode == "status":
        print(json.dumps(pending_summary(log_path, cursor_dir), separators=(",", ":")))
        return
    hook_path = str(Path(__file__).resolve().parents[2] / "hooks" / "spend-subagent-tracker.sh")
    deadline = time.monotonic() + REFRESH_SECONDS
    drained, duplicates, writes_pending, drain_status = drain_spool(log_path, queue, deadline)
    resumed, child_pending, unavailable, timed_out = resume_children(cursor_dir, hook_path, deadline)
    # Child checkpoints can themselves spool while another hook holds the log.
    writes_pending = len(pending_files(queue))
    print(json.dumps({"drained": drained, "duplicate_spool_rows_removed": duplicates,
        "pending_writes": writes_pending, "resumed_children": resumed,
        "pending_children": child_pending, "unavailable_child_sources": unavailable,
        "status": "time_limited" if timed_out else drain_status}, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Maintenance is observational and best-effort. The status is explicit
        # so failures never turn missing telemetry into a clean coverage claim.
        print(json.dumps({"drained": 0, "duplicate_spool_rows_removed": 0,
            "pending_writes": -1, "resumed_children": 0, "pending_children": -1,
            "unavailable_child_sources": 0, "status": "maintenance_unavailable"}, separators=(",", ":")))
