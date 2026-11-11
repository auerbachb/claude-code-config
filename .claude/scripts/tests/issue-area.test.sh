#!/usr/bin/env bash
# catalog: tests — Exercises optional area placement and the canonical wave pair check.
# covers: .claude/scripts/issue-area.py .claude/skills/wave/SKILL.md .claude/skills/subagent/SKILL.md .claude/skills/pm-handoff/SKILL.md .claude/pm-config.md .claude/scripts/tests/lib/skill-bash.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$root" "$BASH" <<'PY'
import itertools
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
BASH = sys.argv[2]
SCRIPT = ROOT / ".claude/scripts/issue-area.py"
WAVE = ROOT / ".claude/skills/wave/SKILL.md"
CONFIG = """## Independent areas

| Area | Paths | Labels | Keywords |
| --- | --- | --- | --- |
| billing | `services/billing/`, `billing.toml` | billing, team:billing | invoice, payment retry |
| mailer | `services/**/mailer/` | mailer | outgoing email |
| web | `apps/web/*`, `services/**/mailer/ui/` | web | web client |
"""
PAIR = subprocess.check_output([
    BASH, "-c", 'source "$1"; extract_skill_bash "$2" wave-area-pair', "--",
    str(ROOT / ".claude/scripts/tests/lib/skill-bash.sh"), str(WAVE),
], text=True)


def issue(number, *, labels=(), title="", body="", paths=()):
    return dict(number=number, labels=list(labels), title=title, body=body, paths=list(paths))


def compare(candidate, admitted):
    return subprocess.check_output(
        [BASH, "-euc", PAIR + '\ncompare_wave_areas "$1" "$2"', "--",
         json.dumps(candidate), json.dumps(admitted)], text=True,
    ).strip()


class IssueAreas(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="issue-area-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.config = self.root / "pm-config.md"
        self.config.write_text(CONFIG, encoding="utf-8")

    def run_cli(self, issues=(), *, only=False, file=None):
        args = [str(SCRIPT), "--file", str(file or self.config)]
        if only:
            args.append("--config-only")
        return subprocess.run(args, cwd=self.root, input=json.dumps(issues), text=True,
                              capture_output=True, check=False)

    def project(self, *issues):
        result = self.run_cli(issues)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(result.stderr)
        output = json.loads(result.stdout)
        rows = {}
        for row in issues:
            tagged = output["issues"][str(row["number"])]
            rows[row["number"]] = dict(tagged, number=row["number"],
                                      undeclared=not row["paths"] and tagged["area"] is None)
        return output["enabled"], rows

    def test_three_labelled_pathless_issues_are_independent(self):
        enabled, rows = self.project(issue(1, labels=["BILLING"]), issue(2, labels=["mailer"]),
                                     issue(3, labels=["web"]))
        self.assertTrue(enabled)
        self.assertEqual([row["area"] for row in rows.values()], ["billing", "mailer", "web"])
        self.assertEqual([row["source"] for row in rows.values()], ["label"] * 3)
        for left, right in itertools.combinations(rows.values(), 2):
            self.assertEqual(compare(right, left), "")

    def test_same_area_and_unknown_chain_at_different_stages(self):
        _, rows = self.project(issue(1, labels=["team:billing"]),
                               issue(2, body="Fix a payment retry"),
                               issue(3, title="Recheck invoiceless records"),
                               issue(4, title="Recheck the backup"))
        self.assertEqual(rows[2]["source"], "keyword")
        self.assertEqual(compare(rows[2], rows[1]), "same area billing as #1; chains behind it at launch")
        self.assertEqual(compare(rows[3], rows[2]), "")
        self.assertEqual(compare(rows[4], rows[3]), "footprint undeclared; can't rule out overlap with #3")

    def test_multiple_hints_stay_undeclared_and_unique_label_wins(self):
        _, rows = self.project(issue(1, labels=["billing", "web"], title="Fix invoice"),
                               issue(2, title="Fix invoice in the web client"),
                               issue(3, labels=["mailer"], title="Fix invoice"))
        self.assertEqual([rows[k]["area"] for k in (1, 2, 3)], [None, None, "mailer"])
        self.assertTrue(rows[1]["undeclared"])
        self.assertTrue(rows[2]["undeclared"])

    def test_paths_take_precedence_and_mixed_pairs_compare_in_both_directions(self):
        _, rows = self.project(
            issue(1, labels=["billing"]),
            issue(2, labels=["web"], paths=["services/billing/internal/refund.py"]),
            issue(3, paths=["billing.toml"]),
            issue(4, paths=["services/mailer/ui/index.ts"]),
            issue(5, paths=["services/east/mailer/cmd/worker.py"]),
            issue(6, labels=["billing"], paths=["package-lock.json"]),
            issue(7, labels=["mailer"], paths=["package-lock.json"]),
        )
        self.assertIsNone(rows[2]["area"])
        self.assertEqual(rows[4]["path_areas"], ["mailer", "web"])
        self.assertEqual(rows[5]["path_areas"], ["mailer"])
        self.assertIn("same area billing", compare(rows[2], rows[1]))
        self.assertIn("same area billing", compare(rows[1], rows[3]))
        self.assertEqual(compare(rows[2], rows[3]), "")
        self.assertEqual(rows[6]["path_areas"], [])
        self.assertIsNone(rows[6]["area"])
        self.assertIsNone(rows[7]["area"])
        wave = WAVE.read_text(encoding="utf-8")
        self.assertLess(wave.index("Any surface shared"), wave.index("<!-- test-anchor: wave-area-pair -->"))

    def test_inactive_config_preserves_prior_pair_decisions(self):
        for content in ("", "## Independent Areas\n", "## Independent areas\n",
                        "## Independent areas\n<!--\n" + CONFIG + "-->\n",
                        "```markdown\n" + CONFIG + "```\n",
                        "~~~markdown\n" + CONFIG + "~~~\n", "# Other\n"):
            with self.subTest(content=content):
                self.config.write_text(content, encoding="utf-8")
                enabled, rows = self.project(issue(1, labels=["billing"]), issue(2, labels=["mailer"]),
                                             issue(3, paths=["billing.toml"]))
                self.assertFalse(enabled)
                self.assertEqual(compare(rows[2], rows[1]),
                                 "footprint undeclared; can't rule out overlap with #1")
                self.assertEqual(compare(rows[3], rows[1]), "")
        self.config.unlink()
        self.assertEqual(json.loads(self.run_cli(only=True).stdout), {"enabled": False})

    def test_active_section_beats_examples_and_accepts_crlf(self):
        fake = CONFIG.replace("billing.toml", "example.toml")
        config = "## Examples\n````markdown\n```\n" + fake + "````\n<!--\n" + fake + "-->\n" + CONFIG
        self.config.write_bytes(config.replace("\n", "\r\n").encode())
        _, rows = self.project(issue(1, paths=["example.toml"]), issue(2, paths=["billing.toml"]))
        self.assertEqual(rows[1]["path_areas"], [])
        self.assertEqual(rows[2]["path_areas"], ["billing"])

    def test_invalid_config_or_incomplete_issue_never_emits_partial_output(self):
        for content in (CONFIG + CONFIG, CONFIG + "| BILLING | other/ | | |\n",
                        CONFIG.replace("billing.toml", "../outside.toml"),
                        CONFIG.replace("| Labels |", "| Other |"),
                        CONFIG + "\n| other | unrelated/ | | |\n"):
            with self.subTest(content=content):
                self.config.write_text(content, encoding="utf-8")
                result = self.run_cli([issue(1, labels=["billing"])])
                self.assertEqual(result.returncode, 2)
                self.assertFalse(result.stdout)
                self.assertIn("issue-area:", result.stderr)
        self.config.write_bytes(b"\xff")
        self.assertEqual(self.run_cli(only=True).returncode, 2)
        self.config.write_text(CONFIG, encoding="utf-8")
        result = self.run_cli([issue(1, labels=["billing"]), {"number": 2, "labels": ["mailer"]}])
        self.assertEqual(result.returncode, 2)
        self.assertFalse(result.stdout)

    def test_workflow_wiring_and_inactive_project_example(self):
        wave = WAVE.read_text(encoding="utf-8")
        step3 = wave.split("## Step 3:", 1)[1].split("## Step 4:", 1)[0]
        self.assertLess(step3.index("Subject inference"), step3.index("Configured area"))
        self.assertLess(step3.index("Configured area"), step3.index("Nothing at all"))
        self.assertIn('--config-only', step3)
        subagent = (ROOT / ".claude/skills/subagent/SKILL.md").read_text(encoding="utf-8")
        step60 = subagent.split("### 6.0b:", 1)[1].split("### 6.0c:", 1)[0]
        self.assertIn("../wave/SKILL.md#step-3", step60)
        self.assertIn("area-only chain", step60)
        self.assertNotIn("| Area | Paths |", step60)
        handoff = (ROOT / ".claude/skills/pm-handoff/SKILL.md").read_text(encoding="utf-8")
        self.assertIn("## Independent areas\n\n<!--\n| Area | Paths |", handoff)
        self.assertIn("The `Independent areas`, `Active work`, and `Budget` sections", handoff)
        result = self.run_cli(only=True, file=ROOT / ".claude/pm-config.md")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"enabled": False})


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
