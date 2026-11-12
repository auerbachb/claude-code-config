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
DAY_PHASES = (
    "preconditions", "arm", "tick", "teardown", "recovery",
    "park-reactive", "park-preemptive",
)
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


def split_day(expected):
    before = expected[ENTRY]
    starts = []
    for number in range(1, len(DAY_PHASES) + 1):
        positions = [i for i, line in enumerate(before) if line.startswith(f"### 2D.{number}:")]
        if len(positions) > 1:
            raise ValueError(f"ambiguous baseline Step 2D.{number}")
        if positions:
            starts.append(positions[0])
    if not starts:
        return
    if len(starts) != len(DAY_PHASES) or starts != sorted(starts):
        raise ValueError("baseline day phases are missing or out of order")
    end = before.index("## Step 3: Orchestration Loop\n")
    if end <= starts[-1] or before[end-2:end] != ["---\n", "\n"]:
        raise ValueError("could not identify the end of baseline Step 2D")
    starts.append(end - 2)
    expected[ENTRY] = before[:starts[0]] + before[starts[-1]:]
    for index, phase in enumerate(DAY_PHASES):
        path = ENTRY.parent / "modules" / f"day-{phase}.md"
        expected[path] = before[starts[index]:starts[index + 1]]


RANK_PHASES = (
    ("resume", (("load", "1A.1"), ("fetch", "1A.3"), ("present", "1A.4")),
     "## Step 1B: Cold start"),
    ("rank", (("load", "1B.1"), ("fetch", "1B.2"), ("score", "1B.3"), ("present", "1B.5")),
     "## Step 1C: Backlog"),
)


def unique_prefix(lines, prefix):
    matches = [index for index, line in enumerate(lines) if line.startswith(prefix)]
    if len(matches) != 1:
        raise ValueError(f"expected one baseline line starting with {prefix!r}")
    return matches[0]


def split_rank(expected, current):
    module_dir = ENTRY.parent / "modules"
    for operation, phases, following_step in RANK_PHASES:
        paths = [module_dir / operation / f"{phase}.md" for phase, _ in phases]
        if not any(path in current and path not in expected for path in paths):
            continue

        before = expected[ENTRY]
        starts = [unique_prefix(before, f"### {step}:") for _, step in phases]
        end = unique_prefix(before, following_step) - 2
        starts.append(end)
        if starts != sorted(set(starts)) or before[end:end + 2] != ["---\n", "\n"]:
            raise ValueError(f"could not identify ordered baseline {operation} phases")

        for index, path in enumerate(paths):
            expected[path] = before[starts[index]:starts[index + 1]]
        expected[ENTRY] = before[:starts[0]] + before[end:]

        if operation == "rank":
            # The existing presentation prose calls for this read before ranking.
            present = expected[paths[-1]]
            start = unique_prefix(present, "**Read the refill pause before dispatching anything")
            end = unique_prefix(present, "**This read gates the batch")
            if end <= start:
                raise ValueError("could not identify the ordered baseline pause and scope gate")
            expected[paths[0]].extend(present[start:end])
            del present[start:end]


            shared = (
                ("priority", paths[0], "### 1B.1a:", "**Read the refill pause before dispatching anything"),
                ("window-fit", paths[-1], "**Window-fit gate", "**Ownership sweep"),
                ("ownership", paths[-1], "**Ownership sweep", "**Dispatch the selected batch by default."),
            )
            for name, source, first, following in shared:
                contents = expected[source]
                start = unique_prefix(contents, first)
                end = unique_prefix(contents, following)
                if end <= start:
                    raise ValueError(f"could not identify the ordered baseline {name} gate")
                expected[module_dir / "shared" / f"{name}.md"] = contents[start:end]
                del contents[start:end]


FLOW_PHASES = (
    ("cleanup", "## Step 1C:", "## Step 1D:"),
    ("forgotten-prs", "## Step 1D:", "## Step 2:"),
    ("monitor", "## Step 2:", "## Step 2D:"),
    ("launch", "### 3.1:", "### 3.2:"),
    ("track", "### 3.2:", "### 3.3:"),
    ("progress", "### 3.3:", "### 3.3a:"),
    ("progress", "### 3.3a:", "### 3.4:"),
    ("refill", "### 3.4:", "### 3.5:"),
    ("handoff", "### 3.5:", "## Execution Boundary"),
)


def split_flow(expected, current):
    module_dir = ENTRY.parent / "modules" / "flow"
    paths = {module_dir / f"{name}.md" for name, _, _ in FLOW_PHASES}
    if not any(path in current and path not in expected for path in paths):
        return
    before = expected[ENTRY]
    retained = []
    preceding = 0
    for name, start, following in FLOW_PHASES:
        first = unique_prefix(before, start) + 1
        last = unique_prefix(before, following)
        if before[last - 2:last] == ["---\n", "\n"]:
            last -= 2
        if first < preceding or last <= first:
            raise ValueError(f"could not identify ordered baseline flow {name} section")
        retained.extend(before[preceding:first])
        expected.setdefault(module_dir / f"{name}.md", []).extend(before[first:last])
        preceding = last
    retained.extend(before[preceding:])
    expected[ENTRY] = retained


def ordered_mismatches(baseline, current):
    expected = baseline.copy()
    has_layout = len(baseline) > 1 or any(
        line.startswith(("### 2D.1:", "### 1A.1:", "### 1B.1:")) for line in baseline[ENTRY]
    )
    if not has_layout:
        return []
    split_day(expected)
    split_rank(expected, current)
    split_flow(expected, current)
    return [path for path in sorted(expected.keys() | current.keys())
            if expected.get(path) != current.get(path)]


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
        module_dir = ENTRY.parent / "modules"
        tracked = git(root, "ls-tree", "-r", "-z", "--name-only", baseline, "--", str(module_dir))
        old_paths = [ENTRY, *(Path(os.fsdecode(raw)) for raw in tracked.split(b"\0")
                             if raw.endswith(b".md"))]
        original = {path: instruction_lines(git(root, "show", f"{baseline}:{path}"), path)
                    for path in old_paths}
        paths = [ENTRY, *(path.relative_to(root) for path in sorted((root / module_dir).rglob("*.md")))]
        documents = {path: instruction_lines((root / path).read_bytes(), path) for path in paths}
        before = Counter(line for lines in original.values() for line in lines)
        after = Counter(line for lines in documents.values() for line in lines)
        mismatched = ordered_mismatches(original, documents)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"PM split parity unverifiable: {error}", file=sys.stderr)
        return 2
    missing, extra = before - after, after - before
    for label, counts in (("missing", missing), ("unclassified extra", extra)):
        for line, count in counts.items():
            print(f"{label} ({count}): {line.rstrip()}", file=sys.stderr)
    for path in mismatched:
        print(f"ordered baseline instructions differ in {path}", file=sys.stderr)
    if missing or extra or mismatched:
        return 1
    print(f"PM split parity: {sum(before.values())} lines match baseline {baseline}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
