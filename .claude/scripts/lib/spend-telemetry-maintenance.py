#!/usr/bin/env python3
"""Bounded maintenance for private spend-telemetry cursors and append spool."""

import fcntl
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path


LOCK_WAIT_SECONDS = 0.25
LOG_SCAN_SECONDS = 2.0
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


def child_cursors(cursor_dir):
    pending = []
    unavailable = 0
    try:
        cursors = sorted(Path(cursor_dir).glob("*.offset"))
    except OSError:
        return pending, unavailable
    for cursor in cursors:
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
    return pending, unavailable


def pending_summary(log_path, cursor_dir):
    queue = os.path.join(os.path.dirname(log_path), "spend-telemetry-pending")
    children, unavailable = child_cursors(cursor_dir)
    return {"drained": 0, "duplicate_spool_rows_removed": 0,
            "pending_writes": len(pending_files(queue)), "resumed_children": 0,
            "pending_children": len(children), "unavailable_child_sources": unavailable,
            "status": "observed"}


def line_fingerprint(line):
    return hashlib.sha256(line.encode("utf-8", errors="replace")).digest()


def drain_spool(log_path, queue):
    files = pending_files(queue)
    if not files:
        return 0, 0, len(files), "empty"
    lock_path = log_path + ".lock"
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        os.makedirs(queue, mode=0o700, exist_ok=True)
        os.chmod(queue, 0o700)
        lock = open(lock_path, "a", encoding="ascii")
    except OSError:
        return 0, 0, len(pending_files(queue)), "storage_unavailable"
    with lock:
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    return 0, 0, len(pending_files(queue)), "log_lock_busy"
                time.sleep(.01)
        try:
            output = open(log_path, "a+", encoding="utf-8")
        except OSError:
            return 0, 0, len(pending_files(queue)), "storage_unavailable"
        with output:
            fingerprints = set()
            scan_deadline = time.monotonic() + LOG_SCAN_SECONDS
            output.seek(0)
            for existing in output:
                if time.monotonic() >= scan_deadline:
                    return 0, 0, len(pending_files(queue)), "log_scan_limit"
                fingerprints.add(line_fingerprint(existing))
            output.seek(0, os.SEEK_END)
            drained = duplicates = 0
            changed = False
            remove_after_sync = []
            for spool in files[:MAX_PENDING_ROWS]:
                try:
                    raw = spool.read_bytes()
                    if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
                        continue
                    line = raw.decode("utf-8")
                except (OSError, UnicodeDecodeError):
                    continue
                fingerprint = line_fingerprint(line)
                if fingerprint not in fingerprints:
                    output.write(line)
                    fingerprints.add(fingerprint)
                    drained += 1
                    changed = True
                else:
                    duplicates += 1
                remove_after_sync.append(spool)
            if changed:
                output.flush()
                os.fsync(output.fileno())
            for spool in remove_after_sync:
                try:
                    spool.unlink()
                except OSError:
                    continue
        if drained or duplicates:
            try:
                directory_fd = os.open(queue, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            except OSError:
                pass
    return drained, duplicates, len(pending_files(queue)), "drained"


def resume_children(cursor_dir, hook_path):
    candidates, unavailable = child_cursors(cursor_dir)
    candidates = candidates[:MAX_CHILD_CURSORS]
    deadline = time.monotonic() + REFRESH_SECONDS
    resumed = 0
    for cursor, saved in candidates:
        if time.monotonic() >= deadline:
            break
        meta = saved["metadata"]
        path = meta["transcript_path"]
        if not os.path.isfile(path):
            continue
        payload = {"session_id": meta["session_id"], "agent_id": meta["agent_id"],
                   "agent_type": meta["agent_type"], "cwd": meta["cwd"],
                   "repo_root": meta["repo_root"], "repo_slug": meta["repo_slug"],
                   "agent_transcript_path": meta["cursor_path_input"]}
        resume_env = os.environ.copy()
        resume_env["CLAUDE_SPEND_TELEMETRY_RESUME"] = "1"
        # A persisted unknown is not a license to borrow the report process's
        # session identity. The transcript may supply one; otherwise it stays unknown.
        resume_env["CLAUDE_CODE_SESSION_ID"] = ""
        resume_env["CLAUDE_SESSION_ID"] = ""
        previous_offset = saved.get("offset", 0)
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
            still_pending, _ = child_cursors(cursor_dir)
            updated = next((item for candidate, item in still_pending if candidate == cursor), None)
            if updated is None:
                break
            offset = updated.get("offset", 0)
            if type(offset) is not int or offset <= previous_offset:
                break
            previous_offset = offset
    remaining_children, unavailable_after = child_cursors(cursor_dir)
    return resumed, len(remaining_children), max(unavailable, unavailable_after), time.monotonic() >= deadline


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("status", "refresh"):
        raise SystemExit("usage: spend-telemetry-maintenance.py status|refresh LOG_PATH CURSOR_DIR")
    mode, log_path, cursor_dir = sys.argv[1:]
    queue = os.path.join(os.path.dirname(log_path), "spend-telemetry-pending")
    if mode == "status":
        print(json.dumps(pending_summary(log_path, cursor_dir), separators=(",", ":")))
        return
    hook_path = str(Path(__file__).resolve().parents[2] / "hooks" / "spend-subagent-tracker.sh")
    resumed, child_pending, unavailable, timed_out = resume_children(cursor_dir, hook_path)
    drained, duplicates, writes_pending, drain_status = drain_spool(log_path, queue)
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
