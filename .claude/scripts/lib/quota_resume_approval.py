"""Bind an explicit Claude resume approval to a batch and reserve each stop once."""

import hashlib
import hmac
import json
import os
import re
import stat
import time
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path


UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
ACCOUNT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}\Z")
REPO = re.compile(r"[a-z0-9][a-z0-9-]{0,38}/[a-z0-9_.-]{1,100}\Z")
LAUNCHER = re.compile(r"claude-[a-z0-9]+(?:-[a-z0-9]+)*\Z")
APPROVAL = re.compile(r"(0|[1-9][0-9]{0,11})\.([0-9a-f]{64})\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
DESTINATION = re.compile(r"(terminal|tmux):[0-9a-f]{64}\Z")
MAX_STOPS = 32
APPROVAL_SECONDS = 600


def canonical_path(value):
    if not isinstance(value, str) or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise ValueError("invalid approval path")
    path = Path(value)
    if not path.is_absolute() or str(path) != value or ".." in path.parts:
        raise ValueError("approval requires a canonical absolute path")
    return path


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


@dataclass(frozen=True)
class Stop:
    account: str
    profile: str
    repo: str
    session: str
    generation: str
    cwd: str

    def __post_init__(self):
        if (not all(isinstance(v, str) for v in (self.account, self.repo, self.session, self.generation))
                or not ACCOUNT.fullmatch(self.account) or not REPO.fullmatch(self.repo)
                or self.repo.rsplit("/", 1)[1] in {".", ".."}
                or not UUID.fullmatch(self.session) or not UUID.fullmatch(self.generation)):
            raise ValueError("invalid verified stop identity")
        canonical_path(self.profile)
        canonical_path(self.cwd)

    @property
    def receipt_key(self):
        # The verified stop generation is unique to this conversation.
        # Changing account labels, paths, or targets cannot get another attempt.
        return digest([self.session, self.generation])


@dataclass(frozen=True)
class Target:
    launcher: str
    profile: str
    destination: str
    launcher_proof: str
    context_proof: str

    def __post_init__(self):
        if not isinstance(self.launcher, str) or not LAUNCHER.fullmatch(self.launcher):
            raise ValueError("invalid approved Claude launcher")
        canonical_path(self.profile)
        if not isinstance(self.destination, str) or not DESTINATION.fullmatch(self.destination):
            raise ValueError("invalid approved terminal destination")
        if not all(isinstance(proof, str) and SHA256.fullmatch(proof)
                   for proof in (self.launcher_proof, self.context_proof)):
            raise ValueError("invalid approved launcher or state proof")


@dataclass(frozen=True)
class Plan:
    target: Target
    stops: tuple
    issued_at: int

    @property
    def approval(self):
        value = [1, self.issued_at, asdict(self.target), [asdict(stop) for stop in self.stops]]
        return f"{self.issued_at}.{digest(value)}"


def make_plan(target, stops, issued_at):
    if not isinstance(target, Target) or type(issued_at) is not int or not 0 <= issued_at < 10**12:
        raise ValueError("invalid approval preview")
    batch, sessions = [], set()
    for stop in stops:
        if not isinstance(stop, Stop) or len(batch) >= MAX_STOPS:
            raise ValueError("invalid or too large approval batch")
        # A conversation is offered once; multiple generations in a single
        # preview cannot both be the currently verified stop.
        if stop.session in sessions or stop.profile == target.profile:
            raise ValueError("ambiguous stop or unchanged Claude profile")
        sessions.add(stop.session)
        batch.append(stop)
    if not batch:
        raise ValueError("no verified stops to approve")
    return Plan(target, tuple(sorted(batch, key=lambda stop: stop.receipt_key)), issued_at)


@contextmanager
def receipt_directory(directory, *, create=True):
    path = canonical_path(os.fspath(directory))
    if path.parent == path:
        raise ValueError("invalid receipt directory")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    parent = os.open(path.parent, flags)
    try:
        info = os.fstat(parent)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
            raise PermissionError("receipt parent must be owned and not writable by others")
        if create:
            try:
                os.mkdir(path.name, 0o700, dir_fd=parent)
            except FileExistsError:
                pass
        child = os.open(path.name, flags, dir_fd=parent)
        try:
            info = os.fstat(child)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise PermissionError("receipt directory must be private")
            os.fsync(parent)
            yield child
        finally:
            os.close(child)
    finally:
        os.close(parent)


def write_once(directory_fd, name, value):
    try:
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory_fd)
    except FileExistsError:
        # An empty or malformed reservation after a crash is still a hold.
        return False
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(value, stream, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.fsync(directory_fd)
    return True


def receipt_value(stop, plan):
    return {"receipt": stop.receipt_key, "state": "reserved", "approval": plan.approval,
            "target_launcher": plan.target.launcher}


def reserve(directory_fd, stop, plan):
    return write_once(directory_fd, f"{stop.receipt_key}.json", receipt_value(stop, plan))


def authorized_plan(target, stops, approval, now):
    match = APPROVAL.fullmatch(approval) if isinstance(approval, str) else None
    if not match:
        raise ValueError("an explicit approval for this batch is required")
    issued_at = int(match[1])
    observed_at = int(time.time()) if now is None else now
    if type(observed_at) is not int or not 0 <= observed_at - issued_at <= APPROVAL_SECONDS:
        raise ValueError("the approval has expired or is from the future")
    plan = make_plan(target, stops, issued_at)
    if not hmac.compare_digest(approval, plan.approval):
        raise ValueError("the approved batch has changed")

    return plan


def verified(verify, stop, target):
    try:
        return verify(stop, target) is True
    except Exception:
        return False


def execute_approved(target, current_stops, approval, directory, verify, dispatch, now=None):
    """Dispatch the exact current batch after explicit owner approval.

    Acceptance means the backend received the command, not that Claude
    started successfully. Unknown outcomes keep the reservation.
    """
    plan = authorized_plan(target, current_stops, approval, now)
    results = []
    with receipt_directory(directory) as directory_fd:
        for stop in plan.stops:
            if not verified(verify, stop, plan.target):
                status = "stop unverified"
            elif not reserve(directory_fd, stop, plan):
                status = "already reserved"
            elif not verified(verify, stop, plan.target):
                status = "stop changed after reservation"
            else:
                try:
                    sent = dispatch(stop, plan.target) is True
                except Exception:
                    sent = False
                status = "dispatch accepted" if sent else "dispatch uncertain"
            results.append({"session": stop.session, "status": status})
    return results


def consume_worker(target, approved_stops, approval, session, directory, verify, now=None):
    """Claim one reserved worker before exec, even if the terminal invokes it twice."""
    plan = authorized_plan(target, approved_stops, approval, now)
    stop = next((item for item in plan.stops if item.session == session), None)
    if stop is None or not verified(verify, stop, plan.target):
        return None
    try:
        with receipt_directory(directory, create=False) as directory_fd:
            fd = os.open(f"{stop.receipt_key}.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=directory_fd)
            with os.fdopen(fd, "rb") as stream:
                info = os.fstat(stream.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size > 4096):
                    return None
                raw = stream.read(4097)
            if len(raw) > 4096 or json.loads(raw) != receipt_value(stop, plan):
                return None
            if not write_once(directory_fd, f"{stop.receipt_key}.started",
                              {"receipt": stop.receipt_key, "approval": approval, "state": "starting"}):
                return None
            if not verified(verify, stop, plan.target):
                return None
    except (OSError, ValueError):
        return None
    return stop
