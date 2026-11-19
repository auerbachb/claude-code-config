#!/usr/bin/env bash
# catalog: tests — Exercises actual PM queue selection and refill blocks, scoped plan persistence, board order and the active-work census.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$root" "$BASH" <<'PY'
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
PM = ROOT / ".claude/skills/pm/SKILL.md"
RANK_PRESENT = PM.parent / "modules/rank/present.md"
REFILL_MODULE = PM.parent / "modules/flow/refill.md"
BOARD = ROOT / ".claude/skills/board/SKILL.md"
REPO = "sample/project"
SESSION = "session.a:1"


def block(document, anchor):
    return subprocess.check_output([
        BASH, "-c", 'source "$1"; extract_skill_bash "$2" "$3"', "--",
        str(SCRIPTS / "tests/lib/skill-bash.sh"), str(document), anchor,
    ], text=True)


INITIAL = block(RANK_PRESENT, "pm-standing-queue-initial")
INITIAL_PLAN = block(RANK_PRESENT, "pm-standing-queue-initial-plan")
READ = block(REFILL_MODULE, "pm-standing-queue-read")
REFILL = block(REFILL_MODULE, "pm-standing-queue-refill")
TOP_UP = block(REFILL_MODULE, "pm-standing-queue-top-up")
PUBLISH = block(REFILL_MODULE, "pm-standing-queue-publish")
BOARD_QUEUE = block(BOARD, "board-step3-queued-from-round")


def ids(first, last):
    return [str(issue) for issue in range(first, last + 1)]


class StandingQueue(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)
        (self.home / ".claude").mkdir()
        self.state = self.home / ".claude/session-state.json"
        self.env = dict(os.environ, HOME=str(self.home), REPO_KEY=REPO,
                        CLAUDE_SESSION_ID=SESSION, LIMIT="6", PM_QUEUE_RUNNING_ISSUES="[]",
                        PM_STANDING_QUEUE_SH=str(SCRIPTS / "pm-standing-queue.sh"))
        self.env.pop("BASH_ENV", None)
        self.env.pop("ENV", None)

    def run_command(self, command, stdin=None, **extra):
        return subprocess.run(command, cwd=ROOT, env=dict(self.env, **extra),
                              input=stdin, capture_output=True, text=True, timeout=20)

    def shell(self, code, **extra):
        result = self.run_command([BASH, "-eu", "-c", code], **extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def queue(self, verb, session=SESSION, repo=REPO, value=None, expect_rc=0):
        args = [BASH, str(SCRIPTS / "pm-standing-queue.sh"), verb, repo, session]
        if verb == "save":
            args.append("6")
        result = self.run_command(args, stdin=None if value is None else json.dumps(value))
        self.assertEqual(result.returncode, expect_rc, result.stderr)
        if expect_rc == 0:
            return json.loads(result.stdout)

    def save(self, issues, expect=None, **scope):
        return self.queue("save", value={"expect": expect, "issues": issues}, **scope)

    def evaluate(self, removed, vacancies=0, additions=(), running=()):
        code = "\n".join([READ, REFILL, TOP_UP, PUBLISH,
                         'jq -cn --argjson plan "${PM_QUEUE_STATE:-null}" '
                         '--argjson scan "$PM_QUEUE_TOP_UP" \'{plan:$plan,scan:$scan}\''])
        return json.loads(self.shell(code, PM_QUEUE_REMOVED=json.dumps(removed),
                                    PM_QUEUE_VACANCIES=str(vacancies),
                                    PM_QUEUE_ADDITIONS=json.dumps(additions),
                                    PM_QUEUE_RUNNING_ISSUES=json.dumps(running)))

    def initial_selection(self, ranked):
        output = self.shell(INITIAL + '\nprintf "%s" "$PM_QUEUE_SELECTION"',
                            PM_INLINE_RANKED=json.dumps(ranked))
        return json.loads(output)

    def publish_initial(self, ranked, removed):
        code = "\n".join([READ, INITIAL, INITIAL_PLAN, PUBLISH,
                         'printf "%s" "$PM_QUEUE_STATE"'])
        return json.loads(self.shell(code, PM_INLINE_RANKED=json.dumps(ranked),
                                    PM_QUEUE_REMOVED=json.dumps(removed)))

    def test_initial_twenty_ranked_give_six_running_and_six_planned(self):
        ranked = ids(1, 20)
        selection = self.initial_selection(ranked)
        self.assertEqual(selection, {"batch": ids(1, 6), "ranked": ids(1, 12)})
        self.assertEqual(self.publish_initial(ranked, selection["batch"])["issues"], ids(7, 12))
        self.assertEqual(self.queue("read")["issues"], ids(7, 12))
        self.assertNotIn("pipelines", json.loads(self.state.read_text())["repos"][REPO])

    def test_window_trimmed_initial_picks_keep_their_queue_priority(self):
        ranked = ids(1, 12)
        batch = self.initial_selection(ranked)["batch"]
        # Step 1B.5 drops the lowest rank until the real makespan fits.
        while batch:
            estimates = [{"num": int(issue), "est_lo": 60,
                          "est_hi": 120 if issue == "4" else 60, "deps": []}
                         for issue in batch]
            result = self.run_command([BASH, str(SCRIPTS / "makespan.sh"),
                                       "--ceiling", "6", "--cr-rate", "60",
                                       "--now", "2026-11-11T13:23:00Z"],
                                      stdin=json.dumps({"issues": estimates}))
            self.assertEqual(result.returncode, 0, result.stderr)
            span = result.stdout.split(" · binding:", 1)[0]
            if span == "1 h":
                break
            self.assertEqual(span, "1 h–2 h")
            batch.pop()
        self.assertEqual(batch, ids(1, 3))
        self.assertEqual(self.publish_initial(ranked, batch)["issues"], ids(4, 9))
        # A definitive rejection is removed from the entire ranked pool.
        self.assertEqual(self.publish_initial(ranked, batch + ["5"])["issues"],
                         ["4", *ids(6, 10)])

    def test_unreadable_initial_outcomes_preserve_prior_plan(self):
        original = self.save(["77"])
        before = self.state.read_bytes()
        self.assertEqual(self.publish_initial(ids(1, 12), None), original)
        self.assertEqual(self.state.read_bytes(), before)

    def test_two_finished_slots_dispatch_before_any_scan(self):
        self.save(ids(7, 12))
        self.assertEqual(self.shell(READ + '\nprintf "%s" "$PM_QUEUE_PICKS"'),
                         json.dumps(ids(7, 12), separators=(",", ":")))
        # These are the verified outcomes of revalidating and starting 7 and 8.
        result = self.evaluate(["7", "8"])
        self.assertFalse(result["scan"])
        self.assertEqual(result["plan"]["issues"], ids(9, 12))
        at_half = self.evaluate(["9"])
        self.assertFalse(at_half["scan"])
        self.assertEqual(at_half["plan"]["issues"], ids(10, 12))

    def test_below_half_tops_up_without_displacing_retained_order(self):
        self.save(["11", "12"])
        result = self.evaluate([], additions=["12", *ids(13, 20)])
        self.assertTrue(result["scan"])
        self.assertEqual(result["plan"]["issues"], ids(11, 16))

    def test_closed_candidate_is_evicted_and_next_pick_fills_the_slot(self):
        self.save(ids(7, 12))
        picks = json.loads(self.shell(READ + '\nprintf "%s" "$PM_QUEUE_PICKS"'))
        # Stub the live checks that the skill performs before invoking /subagent.
        removed = []
        launched = []
        for issue in picks:
            removed.append(issue)
            if issue == "7":
                continue  # GitHub reports this pick closed.
            launched.append(issue)
            break
        self.assertEqual(launched, ["8"])
        result = self.evaluate(removed)
        self.assertEqual(result["plan"]["issues"], ids(9, 12))
        self.assertFalse(result["scan"])
        # If every planned pick is deferred, a real vacancy still permits fallback.
        result = self.evaluate([], vacancies=1)
        self.assertTrue(result["scan"])
        self.assertEqual(result["plan"]["issues"], ids(9, 12))

    def test_plan_cas_preserves_other_sessions_and_repos(self):
        self.assertIsNone(self.queue("read"))
        first = self.save(["1", "3"])
        sibling = self.save(["9"], session="sibling")
        foreign = self.save(["99"], repo="foreign/elsewhere")
        before = self.state.read_bytes()
        self.assertEqual(self.save(["1", "3"], expect=first), first)
        self.assertEqual(self.state.read_bytes(), before)
        newer = self.save(["3", "1"], expect=first)
        self.assertNotEqual(first["generation"], newer["generation"])
        self.save(["77"], expect=first, expect_rc=7)
        self.assertEqual(self.queue("read"), newer)
        retired = self.save([], expect=newer)
        self.assertEqual(retired["issues"], [])
        self.assertNotEqual(retired["generation"], newer["generation"])
        self.save(["77"], expect=None, expect_rc=7)
        self.assertEqual(self.queue("read"), retired)
        self.assertEqual(self.queue("read", session="sibling"), sibling)
        self.assertEqual(self.queue("read", repo="foreign/elsewhere"), foreign)

    def test_retire_absent_plan_blocks_a_stale_first_writer(self):
        self.assertIsNone(self.queue("read"))
        retired = self.save([])
        self.assertEqual(retired["issues"], [])
        self.save(["7"], expect=None, expect_rc=7)
        self.assertEqual(self.queue("read"), retired)

    def test_repeated_retirement_rejects_a_writer_that_saw_empty_plan(self):
        first = self.save([])
        second = self.save([], expect=first)
        self.assertNotEqual(first["generation"], second["generation"])
        self.save(["77"], expect=first, expect_rc=7)
        self.assertEqual(self.queue("read"), second)

    def test_recovered_plan_excludes_running_pick_before_dispatch_and_depth(self):
        self.save(["7", "8", "9"])
        result = self.shell(READ + '\nprintf "%s" "$PM_QUEUE_PICKS"',
                            PM_QUEUE_RUNNING_ISSUES='["7"]')
        self.assertEqual(json.loads(result), ["8", "9"])
        evaluated = self.evaluate([], additions=ids(10, 13), running=["7"])
        self.assertTrue(evaluated["scan"])
        self.assertEqual(evaluated["plan"]["issues"], ids(8, 13))

    def test_unreadable_running_evidence_preserves_the_queue(self):
        original = self.save(["7"])
        before = self.state.read_bytes()
        result = self.evaluate([], running=None)
        self.assertIsNone(result["plan"])
        self.assertFalse(result["scan"])
        self.assertEqual(self.state.read_bytes(), before)
        self.assertEqual(self.queue("read"), original)

    def test_malformed_queue_and_invalid_scope_never_mutate_state(self):
        self.save(["7", "8"])
        before = self.state.read_bytes()
        self.save(["8", "8"], expect=self.queue("read"), expect_rc=2)
        self.save(ids(1, 7), expect=self.queue("read"), expect_rc=2)
        self.queue("read", session="default", expect_rc=2)
        self.assertEqual(self.state.read_bytes(), before)
        self.state.write_text('{"repos":{"sample/project":{"pm_standing_queues":false}}}')
        before = self.state.read_bytes()
        self.queue("read", expect_rc=5)
        self.save(["1"], expect_rc=5)
        self.assertEqual(self.state.read_bytes(), before)

    def test_missing_helper_keeps_old_backlog_fallback(self):
        code = READ + "\n" + REFILL + '\nprintf "%s" "$PM_QUEUE_TOP_UP"'
        for vacancies, wanted in [(0, "false"), (1, "true")]:
            result = self.shell(code, PM_STANDING_QUEUE_SH="", PM_QUEUE_REMOVED="[]",
                                PM_QUEUE_VACANCIES=str(vacancies))
            self.assertEqual(result, wanted)

    def test_board_plans_follow_round_scope_and_ignore_running_duplicates(self):
        self.save(["10", "9", "12", "8"])
        self.save(["15", "10"], session="sibling")
        self.save(["777"], session="ended")
        data = json.loads(self.state.read_text())
        stamp = "2026-11-11T12:00:00Z"
        data["repos"][REPO]["rounds"] = {
            SESSION: dict(session=SESSION, members=["1", "8"], dispatched_at=stamp),
            "sibling": dict(session="sibling", members=["2"], dispatched_at=stamp),
            "ended": None,
        }
        self.state.write_text(json.dumps(data))

        def board(session, repo=REPO):
            result = self.run_command([BASH, str(SCRIPTS / "round-membership.sh"),
                                       "--repo", repo, "--session", session,
                                       "--include-pm-queue"])
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

        own = board(SESSION)
        self.assertEqual(own["planned"], ["10", "9", "12", "8"])
        self.assertEqual(own["members"], ["1", "8"])
        self.assertEqual(board("observer")["planned"], ["10", "9", "12", "8", "15"])
        self.assertEqual(board("observer", "foreign/repo")["planned"], [])
        queued = self.shell(BOARD_QUEUE + '\nprintf "%s" "$QUEUED_ISSUES"',
                            ROW_ROUND_MEMBERS=json.dumps(own["members"]),
                            ROW_ROUND_PLANNED=json.dumps(own["planned"]),
                            ROW_PIPELINES=json.dumps({"1": {"started_at": stamp}}),
                            ROW_RUNNING_IDS='["12"]')
        self.assertEqual(queued.splitlines(), ["8", "10", "9"])

    def test_unclaimed_plan_does_not_occupy_active_work_slots(self):
        self.save(ids(7, 12))
        binary_dir = self.home / "bin"
        binary_dir.mkdir()
        gh = binary_dir / "gh"
        gh.write_text('#!/usr/bin/env bash\ncase "$*" in\n'
                      '  --version) echo "gh version 2.99.0" ;;\n'
                      '  "pr list "*) echo "[]" ;;\n'
                      '  *) exit 1 ;;\nesac\n')
        gh.chmod(0o700)
        result = self.run_command([BASH, str(SCRIPTS / "active-work-cap.sh"),
                                   "--repo", REPO, "--path", str(self.home), "--json"],
                                  PATH=f"{binary_dir}:{self.env['PATH']}")
        self.assertEqual(result.returncode, 0, result.stderr)
        counts = json.loads(result.stdout)
        self.assertEqual(counts["active"], 0)
        self.assertEqual(counts["free"], counts["cap"])


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
