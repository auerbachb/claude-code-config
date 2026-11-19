"""Verified Terminal.app or tmux tab dispatch for an already approved worker."""

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


OSASCRIPT = Path("/usr/bin/osascript")
ZSH = Path("/bin/zsh")
TERMINAL_SCRIPT = Path(__file__).resolve().with_name("quota-resume-terminal.applescript")
TMUX_LOCATIONS = tuple(Path(p) for p in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux", "/bin/tmux"))
PANE_ID = re.compile(r"%[0-9]+\Z")
SESSION_ID = re.compile(r"\$[0-9]+\Z")
WINDOW_ID = re.compile(r"@[0-9]+\Z")
TERMINAL_ACCEPTED = re.compile(r"accepted /dev/tty[A-Za-z0-9._-]+\Z")


class BackendUnavailable(Exception):
    """No verified destination can create a tab."""


def file_identity(path, *, private=False):
    info = path.lstat()
    modes = 0o077 if private else 0o022
    owners = {os.getuid()} if private else {0, os.getuid()}
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in owners or stat.S_IMODE(info.st_mode) & modes:
        raise BackendUnavailable("an unsafe terminal or worker file was found")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def socket_identity(path):
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise BackendUnavailable("the tmux socket is not private")
    return info.st_dev, info.st_ino


def run(argv, *, timeout=10):
    return subprocess.run([str(arg) for arg in argv], capture_output=True, text=True, timeout=timeout)


@dataclass(frozen=True)
class Backend:
    kind: str
    executable: Path
    identity: tuple
    context: Path
    session: str = ""

    @property
    def approval_destination(self):
        raw = json.dumps([self.kind, str(self.executable), self.identity, str(self.context), self.session])
        return self.kind + ":" + hashlib.sha256(raw.encode()).hexdigest()

    @property
    def description(self):
        if self.kind == "terminal":
            return "new tabs in Terminal.app"
        return f"new windows in tmux session {self.session}"

    def current_identity(self):
        if self.kind == "terminal":
            return (*file_identity(self.executable), *file_identity(self.context))
        return (*file_identity(self.executable), *socket_identity(self.context))

    def submit(self, worker, runner=run):
        worker = Path(worker)
        if not worker.is_absolute():
            raise BackendUnavailable("the resume worker must be an absolute path")
        file_identity(worker, private=True)
        if self.current_identity() != self.identity:
            raise BackendUnavailable("the approved terminal destination changed")
        if self.kind == "terminal":
            argv = [self.executable, self.context, worker]
            expected = TERMINAL_ACCEPTED
        elif self.kind == "tmux" and SESSION_ID.fullmatch(self.session):
            # Multiple command arguments invoke zsh directly. The private
            # worker changes to the approved directory; no path is shell text.
            argv = [self.executable, "-S", self.context, "new-window", "-d", "-P", "-F",
                    "#{window_id}", "-t", self.session + ":", "--", ZSH, "-f", worker]
            expected = WINDOW_ID
        else:
            raise BackendUnavailable("the terminal destination is invalid")
        result = runner(argv)
        return result.returncode == 0 and bool(expected.fullmatch(result.stdout.strip()))


def tmux_backend(environment, runner=run):
    tmux = environment.get("TMUX", "")
    pane = environment.get("TMUX_PANE", "")
    parts = tmux.rsplit(",", 2)
    if (not PANE_ID.fullmatch(pane) or len(parts) != 3
            or not all(p.isdecimal() for p in parts[1:])):
        raise BackendUnavailable("no current tmux session could be verified")
    socket = Path(parts[0])
    if not socket.is_absolute():
        raise BackendUnavailable("the tmux socket path is invalid")
    identity = socket_identity(socket)
    for candidate in TMUX_LOCATIONS:
        if not candidate.is_file():
            continue
        executable = candidate.resolve(strict=True)
        binary = file_identity(executable)
        if not os.access(executable, os.X_OK):
            continue
        result = runner([executable, "-S", socket, "display-message", "-p", "-t", pane, "#{session_id}"])
        session = result.stdout.strip()
        if result.returncode == 0 and SESSION_ID.fullmatch(session) and identity == socket_identity(socket):
            return Backend("tmux", executable, (*binary, *identity), socket, session)
        raise BackendUnavailable("the tmux pane did not resolve to a verified session")
    raise BackendUnavailable("no trusted tmux executable was found")


def discover(environment=None, runner=run, platform=None):
    environment = os.environ if environment is None else environment
    platform = sys.platform if platform is None else platform
    if environment.get("TMUX") or environment.get("TMUX_PANE"):
        # Do not silently move an intended tmux dispatch to a different app.
        return tmux_backend(environment, runner)
    if platform == "darwin" and OSASCRIPT.is_file() and ZSH.is_file():
        identity = (*file_identity(OSASCRIPT), *file_identity(TERMINAL_SCRIPT))
        return Backend("terminal", OSASCRIPT, identity, TERMINAL_SCRIPT)
    raise BackendUnavailable("no supported terminal tab destination is available")
