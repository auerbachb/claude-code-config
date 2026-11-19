"""Real claim/logger and workflow boundaries; all GitHub state is private JSON."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELL = os.environ.get("BOOKKEEPING_TEST_SHELL", "bash")
FAKE_GH = r'''#!/usr/bin/env python3
import json,os,re,sys,subprocess
from pathlib import Path
p=Path(os.environ['BOOKKEEPING_GH_STATE']);d=json.loads(p.read_text());a=sys.argv[1:]
def flag(name,default=None):return a[a.index(name)+1] if name in a else default
repo=flag('--repo',os.environ.get('GH_REPO','alice/demo'));result=None
d['calls'].append(a)
if d.get('fail_view') and a[:2]==['pr','view']:p.write_text(json.dumps(d));sys.exit(1)
if a[:2]==['repo','view']:result={'nameWithOwner':repo}
elif a[:2]==['pr','view']:
 result=d['prs'][repo+'#'+a[2]].copy()
elif a[:2]==['pr','merge']:
 result={};d['prs'][repo+'#'+a[2]]['state']='MERGED'
elif a[:2]==['issue','edit']:
 issue=d['issues'][repo+'#'+a[2]]
 for name,field,key in [('--remove-label','labels','name'),('--remove-assignee','assignees','login')]:
  if name in a:issue[field]=[x for x in issue[field] if x[key]!=flag(name)]
 result={}
elif a and a[0]=='api':
 endpoint=next((x for x in a[1:] if x=='user' or x.startswith('repos/')),None)
 method=flag('-X','GET');ep=(endpoint or '').replace('{owner}/{repo}',repo).split('?')[0]
 if ep=='user':result={'login':'alice'}
 elif ep.endswith('/branches/main/protection'):result={'enforce_admins':{'enabled':False},'required_status_checks':{'strict':True}}
 else:
  m=re.fullmatch(r'repos/([^/]+/[^/]+)/(issues|pulls)/([0-9]+)(?:/(comments|timeline))?',ep)
  deletion=re.fullmatch(r'repos/([^/]+/[^/]+)/issues/comments/([0-9]+)',ep)
  if deletion and method=='DELETE':
   if d.get('delete_fail'):p.write_text(json.dumps(d));sys.exit(1)
   for k,v in d['issues'].items():
    if k.startswith(deletion[1]+'#'):v['comments']=[c for c in v['comments'] if c['id']!=int(deletion[2])]
   result={}
  elif m:
   rep,kind,n,suffix=m.groups();key=rep+'#'+n
   if kind=='pulls':
    v=d['prs'][key];result={'state':v['state'].lower(),'merged_at':v['mergedAt'] if v['state']=='MERGED' else None,'created_at':v['createdAt'],'body':v['body'],'commits':1}
   elif suffix=='comments':
    if d.get('fail_comments'):p.write_text(json.dumps(d));sys.exit(1)
    result=d['issues'][key]['comments']
   elif suffix=='timeline':result=[]
   else:result=d['issues'][key]
  else:raise RuntimeError('unexpected endpoint '+str(a))
else:raise RuntimeError('unexpected gh call '+str(a))
p.write_text(json.dumps(d))
if '--jq' in a:
 r=subprocess.run(['jq','-r',flag('--jq')],input=json.dumps(result),text=True);sys.exit(r.returncode)
print(json.dumps(result))
'''


class Bookkeeping(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="post-merge-bookkeeping-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", str(self.base)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["git", "-C", str(self.base), "remote", "add", "origin", "https://github.com/alice/demo.git"], check=True)
        self.scripts = self.base / ".claude/scripts"
        self.scripts.mkdir(parents=True)
        for name in ("post-merge-bookkeeping.sh", "estimate-log.sh", "pr-issue-ref.sh", "issue-claim.sh", "admin-merge.sh"):
            shutil.copy2(os.environ.get("BOOKKEEPING_HELPER_TEST_SOURCE", ROOT / ".claude/scripts" / name) if name == "post-merge-bookkeeping.sh" else ROOT / ".claude/scripts" / name, self.scripts / name)
        shutil.copytree(ROOT / ".claude/scripts/lib", self.scripts / "lib")
        self.bin = self.base / "bin"
        self.bin.mkdir()
        (self.bin / "bash").symlink_to(shutil.which(SHELL))
        (self.bin / "gh").write_text(FAKE_GH)
        (self.bin / "gh").chmod(0o755)
        self.home = self.base / "home"
        (self.home / ".claude").mkdir(parents=True)
        self.state = self.base / "state.json"
        self.log = self.home / ".claude/estimate-log.jsonl"
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), PATH=str(self.bin) + os.pathsep + self.env["PATH"], GH_REPO="alice/demo", BOOKKEEPING_GH_STATE=str(self.state), ESTIMATE_LOG_FILE=str(self.log), CLAUDE_CLAIM_HOLDER="fixture")
        self.env.pop("CLAUDE_HANDOFF_FLAT_OK", None)
        self.data = dict(prs={}, issues={}, calls=[])
        self.seed()

    def seed(self, repo="alice/demo", renewed=False, owner="alice", claim=True, state="MERGED", body="Closes #7"):
        self.data["prs"][repo + "#41"] = dict(number=41, state=state, mergedAt="2026-11-08T09:00:00Z", createdAt="2026-11-08T07:15:00Z", body=body, baseRefName="main", headRefName="issue-7", headRefOid="a" * 40)
        for n in (7, 8, 9):
            at = "2026-11-08T08:00:00Z" if renewed else "2026-11-08T07:00:00Z"
            payload = dict(login=owner, holder="fixture")
            if renewed:
                payload["since"] = "2026-11-08T07:00:00Z"
            comments = [dict(id=n, created_at=at, user=dict(login=owner), body="<!-- claude-claim: " + json.dumps(payload) + " -->")] if claim else []
            self.data["issues"][repo + "#" + str(n)] = dict(number=n, state="closed", body="Light · Est: 60–90 min · plan on 90", comments=comments, labels=[dict(name="in-progress")] if claim else [], assignees=[dict(login=owner)] if claim else [])
        self.save()

    def save(self):
        self.state.write_text(json.dumps(self.data))

    def load(self):
        self.data = json.loads(self.state.read_text())
        return self.data

    def run_script(self, name="post-merge-bookkeeping.sh", *args, repo="alice/demo"):
        env = dict(self.env, GH_REPO=repo)
        return subprocess.run([SHELL, str(self.scripts / name), "41", *args, "--repo", repo] if name == "post-merge-bookkeeping.sh" else [SHELL, str(self.scripts / name), "41", *args], env=env, cwd=self.base, text=True, capture_output=True, timeout=45)

    def rows(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_clean(self, repo="alice/demo", n=7):
        issue = self.load()["issues"][repo + "#" + str(n)]
        self.assertEqual(issue["comments"], [])
        self.assertEqual(issue["labels"], [])
        self.assertEqual(issue["assignees"], [])

    def test_scope_detection_and_invalid_explicit_scope(self):
        r = self.run_script(repo="invalid//scope")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.load()["calls"], [])
        self.assertFalse(self.log.exists())
        r = subprocess.run([SHELL, str(self.scripts / "post-merge-bookkeeping.sh"), "41"], cwd=self.base, env=self.env, text=True, capture_output=True, timeout=45)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.rows()[0]["repo"], "alice/demo")
        self.assert_clean()

    def test_original_and_renewed_pickup_survive_cleanup_and_replay(self):
        for renewed in (False, True):
            with self.subTest(renewed=renewed):
                self.seed(renewed=renewed)
                self.log.unlink(missing_ok=True)
                r = self.run_script()
                self.assertEqual(r.returncode, 0, r.stderr)
                row = self.rows()[0]
                self.assertEqual((row["claim_ts"], row["start_source"], row["actual_min"]), ("2026-11-08T07:00:00Z", "claim_comment", 120))
                self.assert_clean()
                original = self.log.read_bytes()
                self.assertEqual(self.run_script().returncode, 0)
                self.assertEqual(self.log.read_bytes(), original)

    def test_no_claim_and_unmerged_read_failure_paths(self):
        self.seed(claim=False)
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual((self.rows()[0]["start_source"], self.rows()[0]["actual_min"]), ("pr_created", 105))
        for state, failure in (("OPEN", False), ("CLOSED", False), ("MERGED", True)):
            self.log.unlink(missing_ok=True)
            self.seed(state=state)
            self.data["fail_view"] = failure
            self.save()
            r = self.run_script()
            self.assertEqual(r.returncode, 3, r.stderr)
            self.assertFalse(self.log.exists())
            self.assertTrue(self.load()["issues"]["alice/demo#7"]["comments"])

    def test_multiple_trailers_foreign_claims_and_repo_scope(self):
        self.seed(body="Closes #7\nCloses #8\n\nSome prose fixes #9")
        self.data["issues"]["alice/demo#8"]["comments"][0]["user"]["login"] = "bob"
        payload = dict(login="bob", holder="other")
        self.data["issues"]["alice/demo#8"]["comments"][0]["body"] = "<!-- claude-claim: " + json.dumps(payload) + " -->"
        self.save()
        self.assertEqual(self.run_script().returncode, 0)
        self.assert_clean()
        self.assertTrue(self.data["issues"]["alice/demo#8"]["comments"])
        self.assertTrue(self.data["issues"]["alice/demo#9"]["comments"])
        self.assertEqual(self.rows()[0]["issue"], 7)
        self.seed(repo="alice/other", renewed=True)
        self.assertEqual(self.run_script(repo="alice/other").returncode, 0)
        self.assertEqual({r["repo"] for r in self.rows()}, {"alice/demo", "alice/other"})
        self.assert_clean(repo="alice/other")

    def test_all_winning_tier_claims_are_released(self):
        self.seed(body="Closes #7\nCloses #8\n\nSome prose fixes #9")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["issues"], [7, 8])
        self.assert_clean(n=7)
        self.assert_clean(n=8)
        self.assertTrue(self.data["issues"]["alice/demo#9"]["comments"])

    def test_logger_failure_still_releases_with_pickup_evidence(self):
        logger = self.scripts / "estimate-log.sh"
        original = logger.read_bytes()
        for mode in ("missing", "failure"):
            with self.subTest(mode=mode):
                self.seed(renewed=True)
                if mode == "missing":
                    logger.unlink()
                else:
                    logger.write_text("#!/bin/sh\necho 'WARN: fixture write failed' >&2\nexit 5\n")
                    logger.chmod(0o755)
                r = self.run_script()
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("pickup=2026-11-08T07:00:00Z", r.stderr)
                self.assertIn("WARN:", r.stderr)
                self.assert_clean()
                logger.write_bytes(original)
                logger.chmod(0o755)

    def test_partial_release_retries_without_duplicate_row(self):
        self.data["delete_fail"] = True
        self.save()
        r = self.run_script()
        self.assertEqual(r.returncode, 0)
        self.assertIn("WARNING: could not release", r.stderr)
        self.assertTrue(self.load()["issues"]["alice/demo#7"]["labels"])
        original = self.log.read_bytes()
        self.data["delete_fail"] = False
        self.save()
        self.assertEqual(self.run_script().returncode, 0)
        self.assert_clean()
        self.assertEqual(self.log.read_bytes(), original)

    def test_actual_wrap_fence_and_already_merged_resume(self):
        skill = Path(os.environ.get("BOOKKEEPING_WORKFLOW_TEST_SOURCE", ROOT / ".claude/skills/wrap/SKILL.md")).read_text()
        m = re.search(r'<!-- test-anchor: wrap-post-merge-bookkeeping -->\s*```bash\n(.*?)\n```', skill, re.S)
        self.assertIsNotNone(m)
        env = dict(self.env, POST_MERGE_BOOKKEEPING_SH=str(self.scripts / "post-merge-bookkeeping.sh"), CURRENT_REPO="alice/demo", PR_NUM="41", PR_ISSUE_REF_SH=str(self.scripts / "pr-issue-ref.sh"), ISSUE_CLAIM_SH=str(self.scripts / "issue-claim.sh"), BOOKKEEPING_SCRIPTS=str(self.scripts))
        for _ in range(2):
            r = subprocess.run([SHELL, "-c", 'resolve_script() { printf "%s/%s\\n" "$BOOKKEEPING_SCRIPTS" "$1"; }\n' + 'reconcile_issue_completion() { return 0; }\n' + m[1]], cwd=self.base, env=env, text=True, capture_output=True, timeout=45)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.rows()[0]["actual_min"], 120)
            self.assert_clean()
        self.assertEqual(len(self.rows()), 1)
        self.assertIn("If already merged, use the Phase 3 merged entry below", skill)
        self.assertIn("`MERGED` → use the Phase 3 merged entry", skill)

    def test_claim_replacement_during_real_logger_lock_wait_is_retained(self):
        self.seed(body="Closes #7\nCloses #8")
        barrier = self.base / "logger-waiting"
        gate = self.base / "logger-continue"
        target = str(self.log) + ".lock"
        real_mkdir = shutil.which("mkdir")
        wrapper = self.bin / "mkdir"
        wrapper.write_text("#!/usr/bin/env python3\nimport os,sys,time\nfrom pathlib import Path\n"
                           + "if sys.argv[1:]==[" + repr(target) + "]:\n"
                           + " Path(" + repr(str(barrier)) + ").touch()\n"
                           + " deadline=time.monotonic()+15\n"
                           + " while not Path(" + repr(str(gate)) + ").exists():\n"
                           + "  if time.monotonic()>deadline: sys.exit(98)\n"
                           + "  time.sleep(0.02)\n"
                           + "os.execv(" + repr(real_mkdir) + ",[" + repr(real_mkdir) + "]+sys.argv[1:])\n")
        wrapper.chmod(0o755)
        process = subprocess.Popen([SHELL, str(self.scripts / "post-merge-bookkeeping.sh"), "41", "--repo", "alice/demo"], cwd=self.base, env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            import time
            deadline = time.monotonic() + 15
            while not barrier.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(barrier.exists(), "real logger never reached the lock-acquisition boundary")
            self.load()
            for n in (7, 8):
                issue = self.data["issues"]["alice/demo#" + str(n)]
                issue["state"] = "open"
                payload = dict(login="alice", holder="new-thread-" + str(n))
                issue["comments"].append(dict(id=n + 70, created_at="2026-11-08T09:01:00Z", user=dict(login="alice"), body="<!-- claude-claim: " + json.dumps(payload) + " -->"))
            self.save()
            gate.touch()
            stdout, stderr = process.communicate(timeout=20)
        finally:
            if process.poll() is None:
                import signal
                gate.touch()
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(self.rows()[0]["actual_min"], 120)
        self.load()
        for n in (7, 8):
            issue = self.data["issues"]["alice/demo#" + str(n)]
            self.assertTrue(any(c["id"] == n + 70 for c in issue["comments"]), "new same-account claim " + str(n + 70) + " was removed")
            self.assertEqual(issue["labels"], [dict(name="in-progress")])
            self.assertEqual(issue["assignees"], [dict(login="alice")])
        self.assertEqual(json.loads(stdout)["release_failed"], [7, 8])
        self.assertFalse(any(c[:2] == ["api", "-X"] and "DELETE" in c for c in self.data["calls"]))
        original = self.log.read_bytes()
        replay = self.run_script()
        self.assertEqual(replay.returncode, 0, replay.stderr)
        self.assertEqual(self.log.read_bytes(), original)
        self.assertEqual(json.loads(replay.stdout)["release_failed"], [7, 8])
        self.load()
        for n in (7, 8):
            self.assertTrue(any(c["id"] == n + 70 for c in self.data["issues"]["alice/demo#" + str(n)]["comments"]), "replay adopted a post-merge claim")

    def test_same_second_marker_is_retained_as_ambiguous(self):
        self.data["issues"]["alice/demo#7"]["comments"][0]["created_at"] = self.data["prs"]["alice/demo#41"]["mergedAt"]
        self.save()
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["release_failed"], [7])
        self.assertTrue(self.load()["issues"]["alice/demo#7"]["comments"])
        self.assertEqual(self.data["issues"]["alice/demo#7"]["labels"], [dict(name="in-progress")])

    def test_unreadable_claim_snapshot_skips_cleanup(self):
        self.data["fail_comments"] = True
        self.save()
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ownership unreadable", r.stderr)
        self.assertEqual(json.loads(r.stdout)["release_failed"], [7])
        self.assertTrue(self.load()["issues"]["alice/demo#7"]["comments"])
        self.assertEqual(self.data["issues"]["alice/demo#7"]["labels"], [dict(name="in-progress")])

    def test_label_only_claim_cleans_up_with_no_marker_expectation(self):
        self.data["issues"]["alice/demo#7"]["comments"] = []
        self.save()
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assert_clean()

    def test_actual_merged_entry_guard_prevents_closed_followups(self):
        skill = Path(os.environ.get("BOOKKEEPING_ENTRY_GUARD_TEST_SOURCE", ROOT / ".claude/skills/wrap/SKILL.md")).read_text()
        m = re.search(r'<!-- test-anchor: wrap-confirm-merged-entry -->\s*```bash\n(.*?)\n```', skill, re.S)
        self.assertIsNotNone(m)
        followup = self.base / "followup-ran"
        env = dict(self.env, CURRENT_REPO="alice/demo", PR_NUM="41", GUARD_FOLLOWUP_MARK=str(followup))
        for state in ("CLOSED", "OPEN", "MERGED"):
            self.seed(state=state)
            followup.unlink(missing_ok=True)
            r = subprocess.run([SHELL, "-c", m[1] + '\nprintf followup > "$GUARD_FOLLOWUP_MARK"\n'], cwd=self.base, env=env, text=True, capture_output=True, timeout=15)
            self.assertEqual(r.returncode, 0 if state == "MERGED" else 3, r.stdout + r.stderr)
            self.assertEqual(followup.exists(), state == "MERGED")
            self.assertFalse(self.log.exists())
            self.assertTrue(self.load()["issues"]["alice/demo#7"]["comments"])
        self.data["fail_view"] = True
        self.save()
        followup.unlink(missing_ok=True)
        r = subprocess.run([SHELL, "-c", m[1] + '\nprintf followup > "$GUARD_FOLLOWUP_MARK"\n'], cwd=self.base, env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(r.returncode, 4, r.stdout + r.stderr)
        self.assertFalse(followup.exists())

    def configure_auto_plain_merge(self):
        self.seed(state="OPEN", renewed=True)
        for name, text, exit_code in (
            ("pr-authorship.sh", '{"authorship":"mine"}', 0),
            ("merge-gate.sh", '{"met":false,"missing":["branch is BEHIND base"],"merge_state":"BEHIND","human_changes_requested":[]}', 1),
            ("clean-behind-check.sh", '{"safe_to_offer":true,"head_sha":"' + "a" * 40 + '","file_overlap":{"count":0},"ac":{"all_checked":true}}', 0),
        ):
            path = self.scripts / name
            path.write_text("#!/bin/sh\nprintf '%s\\n' '" + text + "'\nexit " + str(exit_code) + "\n")
            path.chmod(0o755)
    def test_actual_auto_plain_merge_boundary(self):
        self.configure_auto_plain_merge()
        r = self.run_script("admin-merge.sh", "--auto-plain", "--ac-verified", "--force-solo", "--repo-path", str(self.base))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("AUTO_PLAIN_MERGED", r.stdout)
        self.assertEqual(self.rows()[0]["actual_min"], 120)
        self.assert_clean()
        calls = self.data["calls"]
        self.assertFalse(any("-X" in c and c[c.index("-X") + 1] in ("PUT", "PATCH") for c in calls))

    def test_wrap_can_defer_auto_plain_bookkeeping_until_completion(self):
        self.configure_auto_plain_merge()
        invalid = self.run_script("admin-merge.sh", "--defer-bookkeeping", "--repo-path", str(self.base))
        self.assertEqual(invalid.returncode,2)
        r = self.run_script("admin-merge.sh", "--auto-plain", "--ac-verified", "--defer-bookkeeping", "--force-solo", "--repo-path", str(self.base))
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn("AUTO_PLAIN_MERGED",r.stdout)
        self.assertFalse(self.log.exists())
        issue=self.load()["issues"]["alice/demo#7"]
        self.assertTrue(issue["labels"])
        self.assertTrue(issue["comments"])


if __name__ == "__main__":
    unittest.main()
