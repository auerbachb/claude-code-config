#!/usr/bin/env python3
# catalog: utilities — Verify that PM entry and module text preserves its committed baseline.
"""Compare the original PM instructions with the entry and moved modules."""

import argparse
from collections import Counter
import os
from pathlib import Path
import re
import subprocess
import sys


ENTRY = Path(".claude/skills/pm/SKILL.md")
START = "<!-- pm-routing:begin -->"
END = "<!-- pm-routing:end -->"
RELATIVE_LINK = re.compile(r"\]\((\.\.?/[^\s)]+)\)")


def instruction_lines(raw, relative):
    if not raw or not raw.endswith(b"\n") or b"\r" in raw:
        raise ValueError(f"{relative}: expected nonempty LF text with a final newline")

    def target(match):
        return "](" + os.path.normpath(str(relative.parent / match[1])) + ")"

    lines = []
    route_lines = None
    for text in raw.decode("utf-8").split("\n")[:-1]:
        line = text + "\n"
        if text == START:
            if route_lines is not None:
                raise ValueError(f"{relative}: nested routing marker")
            route_lines = 0
        elif text == END:
            if not route_lines:
                raise ValueError(f"{relative}: routing marker has no content")
            route_lines = None
        elif route_lines is None:
            lines.append(RELATIVE_LINK.sub(target, line))
        else:
            route_lines += int(bool(line.strip()))
    if route_lines is not None:
        raise ValueError(f"{relative}: unclosed routing marker")
    return lines


def git(root, *args):
    return subprocess.run(["git", *args], cwd=root, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    ref = parser.add_mutually_exclusive_group()
    ref.add_argument("--base", help="compare against the merge base with this ref")
    ref.add_argument("--baseline-sha", help="compare against this exact commit")
    options = parser.parse_args()
    try:
        root = Path(git(None, "rev-parse", "--show-toplevel").decode().rstrip("\n"))
        if options.baseline_sha:
            baseline = git(root, "rev-parse", "--verify", "--end-of-options",
                           options.baseline_sha + "^{commit}").decode().strip()
        else:
            candidates = [options.base] if options.base else ["origin/main", "main"]
            for name in candidates:
                try:
                    commit = git(root, "rev-parse", "--verify", "--end-of-options",
                                 name + "^{commit}").decode().strip()
                    break
                except subprocess.CalledProcessError:
                    continue
            else:
                raise ValueError("base ref is missing")
            baseline = git(root, "merge-base", "HEAD", commit).decode().strip()
        before = Counter(instruction_lines(git(root, "show", f"{baseline}:{ENTRY}"), ENTRY))
        paths = [root / ENTRY, *sorted((root / ENTRY.parent / "modules").glob("*.md"))]
        after = Counter(line for path in paths
                        for line in instruction_lines(path.read_bytes(), path.relative_to(root)))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"PM split parity unverifiable: {error}", file=sys.stderr)
        return 2
    missing, extra = before - after, after - before
    for label, counts in (("missing", missing), ("unclassified extra", extra)):
        for line, count in counts.items():
            print(f"{label} ({count}): {line.rstrip()}", file=sys.stderr)
    if missing or extra:
        return 1
    print(f"PM split parity: {sum(before.values())} lines match baseline {baseline}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
