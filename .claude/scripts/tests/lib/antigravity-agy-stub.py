#!/usr/bin/env python3
"""Stand-in for interactive `agy` (Issue #2466 tests). Reads typed lines from the terminal.

AGY_STUB_MODE: ready    prints a banner, answers "/usage" with the panel in AGY_STUB_PANEL
               signedout asks for a sign-in, waits for ONE typed line (the "human"), then behaves as ready
               nosignin  asks for a sign-in and never continues
               repaint   like ready, but prints the panel twice (a TUI that redrew in place)
               spinner   like nosignin, but redraws a spinner character every 3 seconds without clearing the screen
AGY_STUB_LOG: every typed line is appended there, so a test can see exactly what was sent.
"""
import os
import sys
import time

mode = os.environ.get("AGY_STUB_MODE", "ready")
log = os.environ.get("AGY_STUB_LOG")


def record(line):
    if log:
        with open(log, "a") as handle:
            handle.write(line + "\n")


def say(text):
    sys.stdout.write(text)
    sys.stdout.flush()


record("ARGS " + " ".join(sys.argv[1:]))
if mode in ("signedout", "nosignin", "spinner"):
    say("Antigravity CLI\r\nYou must sign in to continue. Open accounts.google.com in your browser, then press Enter here.\r\n")
    if mode == "spinner":
        import threading

        def spin():
            while True:
                time.sleep(3)
                say("|\r")
        threading.Thread(target=spin, daemon=True).start()
    if mode in ("nosignin", "spinner"):
        # Stays signed out, but records anything typed so a test can see input sent too early.
        for line in sys.stdin:
            record("LINE " + line.strip())
        sys.exit(0)
    record("HUMAN " + sys.stdin.readline().strip())
    say("\x1b[2J\x1b[HSigned in.\r\n")
say("Antigravity CLI ready >\r\n")
for line in sys.stdin:
    line = line.strip()
    record("LINE " + line)
    if line == "/usage":
        panel = open(os.environ["AGY_STUB_PANEL"]).read().replace("\n", "\r\n")
        say(panel * (2 if mode == "repaint" else 1))
