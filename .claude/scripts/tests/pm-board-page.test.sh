#!/usr/bin/env bash
# catalog: tests — Verifies the PM project page, private publication and real session-state wiring.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$root" "$BASH" <<'PY'
import concurrent.futures
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
BASH = sys.argv[2]
SCRIPTS = ROOT / ".claude/scripts"
HELPER = SCRIPTS / "pm-board-page.sh"
STATE = SCRIPTS / "session-state.sh"
REFERENCE = ROOT / ".claude/reference/pm-output-templates.md"
REPO = "sample/project"
FOREIGN = "elsewhere/foreign"


def block(anchor):
    return subprocess.check_output([
        BASH, "-c", 'source "$1"; extract_skill_bash "$2" "$3"', "--",
        str(SCRIPTS / "tests/lib/skill-bash.sh"), str(REFERENCE), anchor,
    ], text=True)


BEGIN = block("pm-project-board-begin")
PUBLISH = block("pm-project-board-publish")


def row(issue, group, **fields):
    return {"repo": REPO, "issue": issue, "group": group, **fields}


def fixture():
    return {
        "repo": REPO,
        "rows": [
            row(11, "running", pr=111, phase="B", title="Inspect <script>malicious()</script>",
                estimate={"low": 45, "high": 60, "plan": 60}, ends_at="2026-11-11T16:00:00Z"),
            row(12, "running", pr=112, phase="A", title="token=fixture-secret"),
            row(13, "queued", parent=9, title="Third increment"),
            row(14, "queued", title="Next task"),
            row(15, "queued", title="Later task"),
            row(21, "done", parent=9, outcome="merged", pr=121),
            row(22, "done", parent=9, outcome="merged", pr=122),
            row(23, "done", outcome="merged", pr=123),
            row(24, "done", outcome="merged", pr=124),
            row(31, "needs", outcome="blocked", pr=131),
            {**row(11, "running", title="Hidden foreign row"), "repo": FOREIGN},
        ],
        "notes": [{"repo": REPO, "name": "Release notes.md"},
                  {"repo": FOREIGN, "name": "Foreign note.md"},
                  {"repo": REPO, "name": "/tmp/hidden/path.md"}],
        "receipt": {"repo": REPO, "statuses": ["ran", "ran", "skipped", "unrecorded"]},
    }


class ProjectBoard(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)
        (self.home / ".claude").mkdir()
        self.state = self.home / ".claude/session-state.json"
        self.path = self.home / ".claude/boards/sample/project/board.html"
        self.env = {**os.environ, "HOME": str(self.home), "CLAUDE_SESSION_REPO": REPO,
                    "SESSION_STATE_SH": str(STATE), "BOARD_TEST_HELPER": str(HELPER)}
        self.env.pop("BASH_ENV", None)
        self.env.pop("ENV", None)

    def run_command(self, command, payload=None, **extra):
        return subprocess.run(command, cwd=ROOT, env={**self.env, **extra}, text=True,
                              input=None if payload is None else json.dumps(payload),
                              capture_output=True, timeout=20)

    def execute(self, *args, payload=None, expect=0, helper=HELPER):
        result = self.run_command([BASH, str(helper), "--repo", REPO, *args], payload=payload)
        self.assertEqual(result.returncode, expect, result.stderr)
        return json.loads(result.stdout) if expect == 0 else result

    def test_scoped_groups_chain_fields_and_privacy(self):
        notes = self.home / ".claude/handoffs/sample/project"
        notes.mkdir(parents=True)
        (notes / "pr-111-handoff.json").write_text("Private handoff body")
        (notes / "linked.md").symlink_to(notes / "pr-111-handoff.json")
        other = self.home / ".claude/handoffs/elsewhere/foreign"
        other.mkdir(parents=True)
        (other / "other-repo.md").touch()
        saved = self.execute("--expect-digest", "absent", payload=fixture())
        self.assertEqual(Path(saved["path"]), self.path)
        html = self.path.read_text()
        for group, label, count in (("needs", "Needs you", 1), ("running", "Running", 2),
                                    ("queued", "Queued", 3), ("done", "Done", 4)):
            self.assertIn(f'id="{group}-heading">{label} <small>{count}</small>', html)
        for visible in ("2 of 3 done", "pr-111-handoff.json", "Release notes.md", "Phase B",
                        "Est 45–60 min", 'datetime="2026-11-11T16:00:00Z"', "2 ran",
                        "/sample/project/issues/11", "/sample/project/pull/111",
                        "&lt;script&gt;malicious()&lt;/script&gt;", "[redacted]",
                        "prefers-color-scheme: dark", "max-width: 520px", "#column-view"):
            self.assertIn(visible, html)
        for hidden in ("Hidden foreign row", "other-repo.md", "Foreign note.md", "linked.md",
                       "Private handoff body", "/tmp/hidden/path.md", "fixture-secret"):
            self.assertNotIn(hidden, html)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_html_mode_renders_without_publishing(self):
        result = self.run_command([BASH, str(HELPER), "--repo", REPO, "--html"], fixture())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("<!doctype html>", result.stdout)
        self.assertIn("2 of 3 done", result.stdout)
        self.assertFalse(self.path.parent.exists())
        self.assertFalse(self.state.exists())

    def test_stable_mtime_and_verified_merge_movement(self):
        start = self.execute("--current")
        self.assertEqual(start, {"repo": REPO, "path": None, "digest": None})
        self.assertFalse(self.path.parent.exists())
        model = fixture()
        first = self.execute("--expect-digest", "absent", payload=model)
        before = self.path.stat().st_mtime_ns
        again = self.execute("--expect-digest", first["digest"], payload=model)
        self.assertFalse(again["updated"])
        self.assertEqual(self.path.stat().st_mtime_ns, before)
        updated = copy.deepcopy(model)
        updated["rows"][0].update(group="done", outcome="merged", phase=None)
        merged = self.execute("--expect-digest", first["digest"], payload=updated)
        self.assertTrue(merged["updated"])
        html = self.path.read_text()
        running = html.split('id="running-heading"', 1)[1].split("</section>", 1)[0]
        done = html.split('id="done-heading"', 1)[1].split("</section>", 1)[0]
        self.assertNotIn("/issues/11", running)
        self.assertIn("/issues/11", done)
        stale = self.execute("--expect-digest", first["digest"], payload=model, expect=2)
        self.assertIn("collect again", stale.stderr)
        self.assertEqual(self.execute("--current")["digest"], merged["digest"])

    def test_concurrent_publishers_and_symlink_guard(self):
        models = [fixture(), {"repo": REPO, "rows": []}]
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            jobs = [pool.submit(self.run_command, [BASH, str(HELPER), "--repo", REPO,
                                                 "--expect-digest", "absent"], payload)
                    for payload in models]
            outcomes = [job.result() for job in jobs]
        self.assertEqual(sorted(result.returncode for result in outcomes), [0, 2])
        winner = json.loads(next(result.stdout for result in outcomes if result.returncode == 0))
        self.assertEqual(self.execute("--current")["digest"], winner["digest"])
        wrapper_link = self.home / "board-link"
        wrapper_link.symlink_to(HELPER)
        self.assertEqual(self.execute("--current", helper=wrapper_link)["digest"], winner["digest"])
        target = self.home / "untouched"
        target.write_text("unchanged")
        self.path.unlink()
        self.path.symlink_to(target)
        self.execute("--expect-digest", winner["digest"], payload=fixture(), expect=2)
        self.assertEqual(target.read_text(), "unchanged")

    def test_rejects_malformed_terminal_or_foreign_snapshot(self):
        first = self.execute("--expect-digest", "absent", payload=fixture())
        for model in ({"repo": FOREIGN, "rows": []},
                      {"repo": REPO, "rows": [row(51, "done")]},
                      {"repo": REPO, "rows": [row(51, "done", outcome="closed")]},
                      {"repo": REPO, "rows": [row(51, ["invalid"])]}):
            self.execute("--expect-digest", first["digest"], payload=model, expect=2)
        self.assertEqual(self.execute("--current")["digest"], first["digest"])

    def test_all_trigger_paths_write_only_location(self):
        result = self.run_command([BASH, str(STATE), "--repo", FOREIGN,
                                   "--set", '.repos["elsewhere/foreign"].marker=42'])
        self.assertEqual(result.returncode, 0, result.stderr)
        harness = ('resolve_script() { [[ $1 == pm-board-page.sh ]] && printf "%s\\n" "$BOARD_TEST_HELPER"; }\n'
                   + BEGIN + "\n" + PUBLISH
                   + '\nprintf "%s\\n" "$PM_BOARD_PATH"')
        modes = ({}, {"PM_BOARD_DISPATCHED": "true"}, {"PM_BOARD_TERMINAL": "true"},
                 {"REPORT_RESULT": '{"due":true}'})
        for count, events in enumerate(modes):
            result = self.run_command([BASH, "-euc", harness],
                                      PM_BOARD_PAGE_JSON=json.dumps(fixture()), **events)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "" if count == 0 else str(self.path))
            if count == 0:
                self.assertFalse(self.path.exists())
            elif count == 1:
                before = self.state.read_bytes()
                mtime = self.path.stat().st_mtime_ns
            else:
                self.assertEqual(self.state.read_bytes(), before)
                self.assertEqual(self.path.stat().st_mtime_ns, mtime)
        state = json.loads(self.state.read_bytes())["repos"]
        self.assertEqual(state[REPO], {"pm_board_page": {"location": str(self.path)}})
        self.assertEqual(state[FOREIGN]["marker"], 42)

    def test_pm_routes_use_shared_publication(self):
        skill = (ROOT / ".claude/skills/pm/SKILL.md").read_text()
        launch = skill.split("### 3.1:", 1)[1].split("### 3.2:", 1)[0]
        progress = skill.split("### 3.3a:", 1)[1].split("### 3.4:", 1)[0]
        self.assertIn("#persistent-project-board", launch)
        self.assertIn("each observed merged or blocked outcome", progress)
        self.assertIn("every due report", progress)
        self.assertIn("#persistent-project-board", progress)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
