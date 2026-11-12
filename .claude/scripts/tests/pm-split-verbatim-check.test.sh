#!/usr/bin/env bash
# catalog: tests — Exercises PM split parity, resolved links, routing markers, and unverifiable history.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$root" <<'PY'
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1]).resolve()
SCRIPT = ROOT / ".claude/scripts/pm-split-verbatim-check.py"
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


MODULES = ENTRY.parent / 'modules'
DISPATCH = ENTRY.parent / 'scripts/dispatch-module.sh'

GUARDS = {
    'execution boundary': '## Execution Boundary (CRITICAL)',
    'refill pause': 'apply the persisted pause and scope',
    'credit budget': 'credit budget, usage horizon',
    'usage horizon': 'usage horizon, deadline',
    'launch deadline': 'deadline, and author scope',
    'author scope': 'author scope at their existing gates',
    'identity check': '## Step 0a: Identify the current gh user',
    'deadline calculation': '## Step 0b: Window planning',
    'hold unreadable gates': "A gate's missing or unreadable evidence keeps the affected launch held.",
    'selected module only': 'read only its returned path',
}


def check_entry(text):
    for name, fragment in GUARDS.items():
        if fragment not in text:
            raise ValueError(name)
    if re.search(r'(?:^|[\s`])@[^\s`]*modules(?:/|\b)', text, re.MULTILINE):
        raise ValueError('automatic module import')
    if re.search(r'(?im)^.*(?:read|load|cat)[^\n]*modules/[^\n]*\*', text):
        raise ValueError('wholesale module read')


def read_trace(root, routes):
    seen = {ENTRY: (root / ENTRY).read_bytes()}
    for op, phase in routes:
        path = subprocess.check_output([str(root / DISPATCH), op, phase], text=True)
        paths = path.splitlines()
        if len(paths) != 1:
            raise ValueError(f'{op}:{phase} returned {len(paths)} paths')
        selected = Path(paths[0]).relative_to(root)
        if selected not in seen:
            seen[selected] = (root / selected).read_bytes()
    return seen


class PMReadTrace(unittest.TestCase):
    def test_entry_guards_and_import_controls(self):
        source = (ROOT / ENTRY).read_text()
        check_entry(source)
        for name, fragment in GUARDS.items():
            with self.subTest(guard=name), self.assertRaises(ValueError):
                check_entry(source.replace(fragment, '', 1))
        for unsafe in ('@./modules/day-tick.md', 'Read modules/*.md'):
            with self.subTest(unsafe=unsafe), self.assertRaises(ValueError):
                check_entry(source + '\n' + unsafe + '\n')

    def test_four_caller_source_traces(self):
        cases = (
            ('ranking-only', ('rank:load', 'shared:priority', 'rank:fetch', 'rank:score',
                              'rank:present', 'flow:cleanup', 'flow:forgotten-prs'),
             ('rank/load', 'shared/priority', 'rank/fetch', 'rank/score', 'rank/present',
              'flow/cleanup', 'flow/forgotten-prs')),
            ('status', ('flow:progress', 'flow:progress'), ('flow/progress',)),
            ('refill', ('flow:refill', 'shared:priority', 'shared:ownership', 'shared:window-fit'),
             ('flow/refill', 'shared/priority', 'shared/ownership', 'shared/window-fit')),
            ('day tick', ('day:tick', 'flow:refill', 'shared:priority', 'shared:ownership',
                          'shared:window-fit', 'flow:progress'),
             ('day-tick', 'flow/refill', 'shared/priority', 'shared/ownership',
              'shared/window-fit', 'flow/progress')),
        )
        for name, requested, expected in cases:
            with self.subTest(route=name):
                trace = read_trace(ROOT, (route.split(':') for route in requested))
                self.assertEqual(tuple(trace), (ENTRY,) + tuple(MODULES / (f + '.md') for f in expected))
                self.assertTrue(all(trace.values()))

    def test_resume_reads_only_available_saved_phase(self):
        with tempfile.TemporaryDirectory(prefix='pm-resume-trace-') as private:
            root = Path(private).resolve()
            files = (ENTRY, DISPATCH, MODULES / 'flow/refill.md')
            for file in files:
                (root / file).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / file, root / file)
            # The fixture has no earlier phases or sibling modules. Recovery
            # supplies the previously selected route after revalidating evidence.
            self.assertEqual(tuple(read_trace(root, [('flow', 'refill')])), (ENTRY, files[-1]))
            (root / files[-1]).unlink()
            result = subprocess.run([str(root / DISPATCH), 'flow', 'refill'],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 3)
            self.assertEqual(result.stdout, '')
            self.assertIn(str(root / files[-1]), result.stderr)

    def test_resume_cites_the_canonical_truncation_warning(self):
        rank = (ROOT / MODULES / 'rank/fetch.md').read_text()
        resume = (ROOT / MODULES / 'resume/fetch.md').read_text()
        self.assertIn('### 1B.2: Fetch GitHub state', rank)
        self.assertIn('If the returned issue count equals 500, warn:', rank)
        self.assertEqual(rank.count('Showing 500 issues'), 1)
        self.assertNotIn('Showing 500 issues', resume)
        self.assertIn('If 500 issues are returned', resume)
        self.assertIn('../rank/fetch.md#1b2-fetch-github-state', resume)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
