"""Read-only process evidence for a locally verified Claude /end stop."""

import os
import re
import shutil
import subprocess
import uuid
from dataclasses import dataclass
from pathlib import Path


NATIVE_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
REPO = re.compile(r"[a-z0-9][a-z0-9-]{0,38}/[a-z0-9_.-]{1,100}\Z")
START = re.compile(r"[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}\Z")
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
STOP_NAMESPACE = uuid.UUID("722a15d8-2b3a-437a-a07d-14aa9fa74e71")
NATIVE_COMMANDS = {"claude"}
POSSIBLE_CLAUDE = NATIVE_COMMANDS | {"Claude", "claude-code", "node"}


class EvidenceUnavailable(Exception):
    """The process check could not establish safe absence."""


@dataclass(frozen=True)
class Process:
    pid: int
    parent: int
    uid: int
    start: str
    command: str


def read_system(executable, *args):
    tool = shutil.which(executable, path=SYSTEM_PATH)
    if tool is None:
        raise EvidenceUnavailable(f"{executable} is unavailable")
    env = dict(os.environ, LC_ALL="C", TZ="UTC")
    try:
        result = subprocess.run([tool, *args], capture_output=True, env=env, timeout=5, check=True)
    except (OSError, subprocess.SubprocessError) as exc:
        raise EvidenceUnavailable(f"{executable} did not return verified evidence") from exc
    if len(result.stdout) > 4_000_000:
        raise EvidenceUnavailable(f"{executable} returned too much evidence")
    return result.stdout


def process_table(read=read_system):
    text = os.fsdecode(read("ps", "-ax", "-o", "pid=,ppid=,uid=,lstart=,comm="))
    processes = {}
    for line in text.splitlines():
        parts = line.split(maxsplit=8)
        if len(parts) != 9 or any(not field.isdecimal() for field in parts[:3]):
            raise EvidenceUnavailable("process table is unreadable")
        pid, parent, uid = map(int, parts[:3])
        start = " ".join(parts[3:8])
        if pid <= 0 or pid in processes or not START.fullmatch(start):
            raise EvidenceUnavailable("process table identity is ambiguous")
        processes[pid] = Process(pid, parent, uid, start, Path(parts[8]).name)
    if not processes:
        raise EvidenceUnavailable("process table is empty")
    return processes


def process_directory(pid, read=read_system):
    raw = read("lsof", "-nP", "-a", "-p", str(pid), "-d", "cwd", "-F0pfn")
    fields = [part.lstrip(b"\n") for part in raw.split(b"\0") if part.strip(b"\n")]
    if len(fields) != 3 or fields[:2] != [f"p{pid}".encode(), b"fcwd"] or not fields[2].startswith(b"n/"):
        raise EvidenceUnavailable("process directory could not be verified")
    try:
        path = Path(os.fsdecode(fields[2][1:])).resolve(strict=True)
        if not path.is_dir():
            raise EvidenceUnavailable("process directory is unavailable")
        return path
    except (OSError, RuntimeError, ValueError) as exc:
        raise EvidenceUnavailable("process directory is unavailable") from exc


def valid_scope(session, repo):
    return (isinstance(session, str) and NATIVE_ID.fullmatch(session)
            and isinstance(repo, str) and REPO.fullmatch(repo) and repo.rsplit("/", 1)[1] not in {".", ".."})


def stop_generation(repo, session, uid, pid, start):
    return str(uuid.uuid5(STOP_NAMESPACE, f"{repo}/{session}/{uid}/{pid}/{start}"))


def capture_origin(session, native_session, repo, parent=None, uid=None, read=read_system):
    """Bind one exact native /end to its originating, same-user Claude process."""
    if (not valid_scope(session, repo)
            or not isinstance(native_session, str) or native_session.lower() != session):
        raise EvidenceUnavailable("the native Claude session is not bound")
    parent = os.getppid() if parent is None else parent
    uid = os.getuid() if uid is None else uid
    table = process_table(read)
    for _ in range(24):
        item = table.get(parent)
        if item is None or item.uid != uid or item.pid <= 1 or item.parent == item.pid:
            break
        if item.command in NATIVE_COMMANDS:
            generation = stop_generation(repo, session, uid, item.pid, item.start)
            return {"pid": item.pid, "start": item.start, "generation": generation}
        parent = item.parent
    raise EvidenceUnavailable("the original Claude process could not be verified")


def origin_exited(origin, cwd, session, repo, uid=None, read=read_system):
    """Require the old PID gone or replaced, and no possible live Claude in this directory."""
    if not valid_scope(session, repo) or not isinstance(origin, dict) or set(origin) != {"pid", "start", "generation"}:
        return False
    pid, start, generation = origin["pid"], origin["start"], origin["generation"]
    if (type(pid) is not int or pid <= 1 or not isinstance(start, str) or not START.fullmatch(start)
            or not isinstance(generation, str) or not NATIVE_ID.fullmatch(generation)):
        return False
    uid = os.getuid() if uid is None else uid
    if generation != stop_generation(repo, session, uid, pid, start):
        return False
    try:
        directory = Path(cwd).resolve(strict=True)
        if not directory.is_dir():
            return False
        before = process_table(read)
        old = before.get(pid)
        if old is not None and old.uid == uid and old.start == start:
            return False
        candidates = {p.pid: p for p in before.values() if p.uid == uid and p.command in POSSIBLE_CLAUDE}
        if any(process_directory(p, read) == directory for p in candidates):
            return False
        # A process replaced or started while scanning is not positive absence.
        after = process_table(read)
        return (after.get(pid) == old
                and {p.pid: p for p in after.values() if p.uid == uid and p.command in POSSIBLE_CLAUDE} == candidates)
    except (EvidenceUnavailable, OSError, RuntimeError, ValueError):
        return False
