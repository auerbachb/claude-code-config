#!/usr/bin/env bash
# catalog: tests — Exercises PM split parity, resolved links, routing markers, and unverifiable history.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$root" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv[1]) / ".claude/scripts/pm-split-verbatim-check.py"
ENTRY = Path(".claude/skills/pm/SKILL.md")
MODULE = ENTRY.parent / "modules/day-tick.md"
OLD = "entry\nrepeat\nrepeat\n[shared](../../reference/example.md)\n"
NEW_ENTRY = "entry\n<!-- pm-routing:begin -->\nRead one module.\n<!-- pm-routing:end -->\n"
NEW_MODULE = "repeat\nrepeat\n[shared](../../../reference/example.md)\n"


class Parity(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="pm-split-parity-")
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.git("init", "-q", "-b", "main")
        self.write(ENTRY, OLD)
        self.git("add", str(ENTRY))
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline")
        self.baseline = self.git("rev-parse", "HEAD").strip()
        self.write(ENTRY, NEW_ENTRY)
        self.write(MODULE, NEW_MODULE)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode())

    def check(self, *args):
        return subprocess.run([str(SCRIPT), *args], cwd=self.root, text=True,
                              capture_output=True, check=False)

    def test_clean_moved_lines_and_same_resolved_link(self):
        result = self.check("--baseline-sha", self.baseline)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"4 lines match baseline {self.baseline}", result.stdout)
        self.assertEqual(self.check().returncode, 0)

    def test_missing_duplicate_line_is_reported(self):
        self.write(MODULE, NEW_MODULE.replace("repeat\n", "", 1))
        result = self.check("--base", "main")
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing (1): repeat", result.stderr)

    def test_unmarked_addition_and_changed_link_are_reported(self):
        self.write(MODULE, NEW_MODULE.replace("example.md", "wrong.md") + "extra\n")
        result = self.check("--baseline-sha", self.baseline)
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing (1): [shared](.claude/reference/example.md)", result.stderr)
        self.assertIn("unclassified extra (1): [shared](.claude/reference/wrong.md)", result.stderr)
        self.assertIn("unclassified extra (1): extra", result.stderr)

    def test_invalid_text_and_markers_are_unverifiable(self):
        for content in (NEW_MODULE.rstrip("\n"), NEW_MODULE.replace("\n", "\r\n"),
                        "<!-- pm-routing:begin -->\n<!-- pm-routing:end -->\n" + NEW_MODULE):
            with self.subTest(content=content):
                self.write(MODULE, content)
                result = self.check("--base", "main")
                self.assertEqual(result.returncode, 2)
                self.assertIn("unverifiable", result.stderr)

    def day_split(self):
        phases = ("preconditions", "arm", "tick", "teardown", "recovery",
                  "park-reactive", "park-preemptive")
        modules = [ENTRY.parent / "modules" / f"day-{phase}.md" for phase in phases]
        blocks = [
            f"### 2D.{number}: {phase}\n\n```bash\nprintf first\nprintf second\n```\n\n"
            for number, phase in enumerate(phases, 1)
        ]
        intro = "PM entry\n\n"
        suffix = "---\n\n## Step 3: Orchestration Loop\n"
        self.write(ENTRY, intro + "".join(blocks) + suffix)
        self.git("add", str(ENTRY))
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline day")
        baseline = self.git("rev-parse", "HEAD").strip()
        self.write(ENTRY, intro + suffix)
        for path, block in zip(modules, blocks):
            self.write(path, block)
        self.assertEqual(self.check("--baseline-sha", baseline).returncode, 0)
        return baseline, modules, blocks

    def test_swapped_modules_fail_even_with_identical_multiset(self):
        baseline, modules, blocks = self.day_split()
        self.write(modules[1], blocks[3])
        self.write(modules[3], blocks[1])
        result = self.check("--baseline-sha", baseline)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ordered baseline instructions differ", result.stderr)
        self.assertIn("day-arm.md", result.stderr)
        self.assertIn("day-teardown.md", result.stderr)

    def test_reordered_fenced_commands_fail_even_with_identical_multiset(self):
        baseline, modules, blocks = self.day_split()
        self.write(modules[2], blocks[2].replace("printf first\nprintf second",
                                                "printf second\nprintf first"))
        result = self.check("--baseline-sha", baseline)
        self.assertEqual(result.returncode, 1)
        self.assertIn("day-tick.md", result.stderr)

    def test_rank_split_preserves_shared_gates_and_existing_module_order(self):
        separator = "---\n\n"
        resume_head = "## Step 1A: Resume mode\n"
        rank_head = "## Step 1B: Cold start (default)\n"
        cleanup = "## Step 1C: Backlog & workspace cleanup (always-on)\n"
        resume = (
            "### 1A.1: Load\n### 1A.2: State\n",
            "### 1A.3: Fetch\n",
            "### 1A.4: Present\n",
        )
        priority = "### 1B.1a: Operator priority\n"
        window = "**Window-fit gate\n"
        ownership = "**Ownership sweep\n"
        dispatch = "**Dispatch the selected batch by default.**\n"
        pause = "**Read the refill pause before dispatching anything\n"
        verify = "**This read gates the batch\n"
        rank = (
            "### 1B.1: Load\n",
            "### 1B.2: Fetch\n",
            "### 1B.3: Score\n### 1B.4: Rank\n",
            "### 1B.5: Present\n",
        )
        entry = resume_head + "".join(resume) + separator + rank_head
        entry += rank[0] + priority + "".join(rank[1:]) + window + ownership + dispatch
        entry += pause + verify + separator + cleanup
        self.write(ENTRY, entry)
        self.write(MODULE, "D0 first\nD1 second\n")
        self.git("add", str(ENTRY), str(MODULE))
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline rank")
        baseline = self.git("rev-parse", "HEAD").strip()
        self.write(ENTRY, resume_head + separator + rank_head + separator + cleanup)
        modules = ENTRY.parent / "modules"
        for phase, block in zip(("load", "fetch", "present"), resume):
            self.write(modules / "resume" / f"{phase}.md", block)
        for phase, block in zip(("load", "fetch", "score", "present"),
                                (rank[0] + pause, rank[1], rank[2], rank[3] + dispatch + verify)):
            self.write(modules / "rank" / f"{phase}.md", block)
        for phase, block in (("priority", priority), ("window-fit", window), ("ownership", ownership)):
            self.write(modules / "shared" / f"{phase}.md", block)
        result = self.check("--baseline-sha", baseline)
        self.assertEqual(result.returncode, 0, result.stderr)

        self.write(MODULE, "D1 second\nD0 first\n")
        result = self.check("--baseline-sha", baseline)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ordered baseline instructions differ", result.stderr)
        self.assertIn("day-tick.md", result.stderr)

        self.write(MODULE, "D0 first\nD1 second\n")
        self.write(modules / "shared/priority.md", ownership)
        self.write(modules / "shared/ownership.md", priority)
        result = self.check("--baseline-sha", baseline)
        self.assertEqual(result.returncode, 1)
        self.assertIn("shared/priority.md", result.stderr)
        self.assertIn("shared/ownership.md", result.stderr)

    def test_flow_split_preserves_section_order_and_entry_boundaries(self):
        sections = (
            ("## Step 1C: Cleanup", "cleanup", "clean first"),
            ("## Step 1D: Forgotten PRs", "forgotten-prs", "triage next"),
            ("## Step 2: Monitoring", "monitor", "set up monitoring"),
            ("## Step 2D: Day mode", None, "keep day entry"),
            ("### 3.1: Launch", "launch", "launch once"),
            ("### 3.2: Track", "track", "track once"),
            ("### 3.3: Progress", "progress", "progress first"),
            ("### 3.3a: Board", "progress", "progress second"),
            ("### 3.4: Refill", "refill", "refill once"),
            ("### 3.5: Handoff", "handoff", "handoff once"),
            ("## Execution Boundary", None, "keep the boundary"),
        )
        self.write(ENTRY, "".join(f"{heading}\n{text}\n" for heading, _, text in sections))
        self.write(MODULE, "unchanged day module\n")
        self.git("add", str(ENTRY), str(MODULE))
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "baseline flow")
        baseline = self.git("rev-parse", "HEAD").strip()

        retained = []
        flow = {}
        for heading, module, text in sections:
            retained.append(heading + "\n")
            if module is None:
                retained.append(text + "\n")
            else:
                flow.setdefault(module, []).append(text + "\n")
        self.write(ENTRY, "".join(retained))
        folder = ENTRY.parent / "modules/flow"
        for name, contents in flow.items():
            self.write(folder / f"{name}.md", "".join(contents))
        clean = self.check("--baseline-sha", baseline)
        self.assertEqual(clean.returncode, 0, clean.stderr)

        self.write(folder / "progress.md", "".join(reversed(flow["progress"])))
        reordered = self.check("--baseline-sha", baseline)
        self.assertEqual(reordered.returncode, 1)
        self.assertIn("ordered baseline instructions differ", reordered.stderr)
        self.assertIn("flow/progress.md", reordered.stderr)
        self.assertNotIn("missing (", reordered.stderr)

    def test_missing_ref_or_missing_historical_source(self):
        result = self.check("--base", "unknown")
        self.assertEqual(result.returncode, 2)
        self.assertIn("base ref is missing", result.stderr)
        self.git("rm", "--cached", str(ENTRY))
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "-qm", "empty tree")
        result = self.check("--baseline-sha", self.git("rev-parse", "HEAD").strip())
        self.assertEqual(result.returncode, 2)
        self.assertIn("unverifiable", result.stderr)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
