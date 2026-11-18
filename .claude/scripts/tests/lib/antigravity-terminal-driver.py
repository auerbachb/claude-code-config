#!/usr/bin/env python3
"""Plays the person at a visible terminal for the Issue #2466 tests.

  antigravity-terminal-driver.py <none|signin|tty> <command...>

Opens a pseudo-terminal and hands it to the command as its visible tab through
AI_QUOTAS_TERMINAL_DEVICE. In "signin" mode it types one line once the tab shows the sign-in
instruction. "tty" mode is the real path: the command gets the pseudo-terminal as its stdin and
controlling terminal and no device override, as a person running it in a terminal would.
Prints one JSON object: rc, stdout, stderr and tab (what the tab displayed).
"""
import json
import os
import pty
import select
import signal
import subprocess
import sys
import termios
import threading
import time
import fcntl

mode = sys.argv[1]
master, slave = pty.openpty()
if mode == "tty":
    env = {k: v for k, v in os.environ.items() if k != "AI_QUOTAS_TERMINAL_DEVICE"}
    proc = subprocess.Popen(sys.argv[2:], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                            preexec_fn=lambda: (os.setsid(), fcntl.ioctl(0, termios.TIOCSCTTY, 0)))
else:
    env = dict(os.environ, AI_QUOTAS_TERMINAL_DEVICE=os.ttyname(slave))
    proc = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                            start_new_session=True)
out = {}
thread = threading.Thread(target=lambda: out.update(zip(("stdout", "stderr"), proc.communicate())))
thread.start()
tab = b""
typed = False
expired = False
deadline = time.time() + 240   # far above any test timeout; a hang fails the test instead of blocking it
while thread.is_alive():
    if time.time() > deadline:
        # The command runs in its own session, so killing the group also ends anything it left behind
        # holding the output pipes (communicate() would wait on those).
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            proc.kill()
        expired = True
        break
    ready, _, _ = select.select([master], [], [], 0.2)
    if master in ready:
        try:
            tab += os.read(master, 65536)
        except OSError:
            break
    if mode in ("signin", "tty-signin") and not typed and b"sign in to Antigravity in this terminal" in tab:
        os.write(master, b"human-signed-in\n")
        typed = True
thread.join()
while select.select([master], [], [], 0.3)[0]:
    try:
        more = os.read(master, 65536)
    except OSError:
        break
    if not more:
        break
    tab += more
print(json.dumps({"rc": proc.returncode, "stdout": out["stdout"].decode(), "stderr": out["stderr"].decode(),
                  "tab": tab.decode("utf-8", "replace")}))
if expired:
    sys.stderr.write("antigravity-terminal-driver: the command did not finish before the driver deadline\n")
    sys.exit(124)
