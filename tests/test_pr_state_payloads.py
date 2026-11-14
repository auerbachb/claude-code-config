"""Exercise the actual snapshot script with private, synthetic GitHub endpoints."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("PR_STATE_PAYLOAD_SOURCE", ROOT / ".claude/scripts/pr-state.sh"))


class PrStatePayloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pr-state-payload-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        (self.scripts / "lib").mkdir()
        shutil.copy2(SOURCE, self.scripts / "pr-state.sh")
        for helper in ("check-runs-dedup.sh", "check-runs-snapshot.sh"):
            shutil.copy2(ROOT / ".claude/scripts" / helper, self.scripts / helper)
        shutil.copy2(ROOT / ".claude/scripts/lib/check_run_workflows.py",
                     self.scripts / "lib/check_run_workflows.py")
        # Copy the actual helper dependencies, without relying on the owner's HOME.
        for p in (ROOT / ".claude/scripts/lib").glob("*.jq"):
            shutil.copy2(p, self.scripts / "lib" / p.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.fixture = self.root / "fixture"
        self.fixture.mkdir()
        self.scratch = self.root / "scratch"
        self.scratch.mkdir()
        self.home = self.root / "home"
        (self.home / ".claude").mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.home), FIXTURE=str(self.fixture),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"], TMPDIR=str(self.scratch),
                        JQ_REAL=shutil.which("jq"), ARGV_LOG=str(self.root / "argv.jsonl"))
        for key in ("GH_REPO", "CLAUDE_SESSION_REPO"):
            self.env.pop(key, None)
        self.write("pr", {"number": 987654, "headRefName": "fixture", "headRefOid": "a" * 40,
                          "state": "OPEN", "url": "https://example.invalid/pr/1",
                          "mergeStateStatus": "CLEAN", "mergeable": "MERGEABLE", "reviewDecision": "APPROVED"})
        for name in ("reviews", "inline", "conversation", "statuses"):
            self.write(name, [])
        self.write("checks", [{"id": 1, "name": "fixture-ci", "status": "completed", "conclusion": "success",
                               "check_suite": {"id": 1}, "app": {"slug": "github-actions", "id": 1}}])
        self.thread_page(0, False, [])
        self.executable("gh", r"""import json,os,sys
from pathlib import Path
root=Path(os.environ['FIXTURE']);args=sys.argv[1:]
if args[:2]==['pr','view']: path=root/'pr.json'
elif args[:2]==['repo','view']:
 print('fixture/repository');sys.exit(0)
elif args[:2]==['api','graphql']:
 cursor=next((a[7:] for a in args if a.startswith('cursor=')), 'null')
 path=root/('threads-0.json' if cursor=='null' else 'threads-'+cursor+'.json')
elif args and args[0]=='api':
 endpoint=next((a for a in args[1:] if a.startswith('repos/')), '')
 if '/check-runs?' in endpoint:
  if (root/'checks-404').exists():
   print('HTTP 404 test marker',file=sys.stderr);sys.exit(1)
  checks=json.loads((root/'checks.json').read_text())
  print(json.dumps({'total_count':len(checks),'check_runs':checks}))
  sys.exit(0)
 if '/actions/runs?' in endpoint:
  print(json.dumps({'total_count':1,'workflow_runs':[{'id':1,'workflow_id':1,'run_attempt':1,
   'event':'push','head_branch':'fixture','head_sha':'a'*40,'pull_requests':[],
   'check_suite_id':1,'html_url':'https://github.com/fixture/repository/actions/runs/1',
   'status':'completed','conclusion':'success'}]}))
  sys.exit(0)
 if '/statuses?' in endpoint:name='statuses'
 elif '/reviews?' in endpoint:name='reviews'
 elif '/pulls/' in endpoint and '/comments?' in endpoint:name='inline'
 elif '/issues/' in endpoint and '/comments?' in endpoint:name='conversation'
 else:raise SystemExit('unexpected fixture endpoint')
 path=root/(name+'.json')
else:raise SystemExit('unexpected fixture command')
if (root/'fail-api').exists() and args[0]=='api':raise SystemExit(17)
sys.stdout.write(path.read_text())
""")
        self.executable("jq", r"""import json,os,sys
from pathlib import Path
scratch=[]
for arg in sys.argv[1:]:
 for parent in Path(arg).parents:
  if parent.name.startswith('pr-state-work-'):
   scratch.append(str(parent));break
sizes=[sum(p.stat().st_size for p in Path(d).iterdir() if p.is_file()) for d in set(scratch)]
with open(os.environ['ARGV_LOG'],'a') as f:f.write(json.dumps({'argv_sizes':[len(a.encode()) for a in sys.argv[1:]],'scratch':scratch,'scratch_bytes':max(sizes,default=0)})+'\n')
if max(sizes,default=0)>int(os.environ.get('SCRATCH_BYTE_LIMIT','1000000000')):
 raise SystemExit('private fixture scratch byte budget exceeded')
os.execv(os.environ['JQ_REAL'],[os.environ['JQ_REAL']]+sys.argv[1:])
""")

    def executable(self, name, body):
        p = self.bin / name
        p.write_text("#!" + sys.executable + "\n" + body)
        p.chmod(0o700)

    def write(self, name, value):
        (self.fixture / (name + ".json")).write_text(json.dumps(value))

    def thread_page(self, page, more, nodes):
        self.write("threads-" + str(page), {"data": {"repository": {"pullRequest": {"reviewThreads": {
            "nodes": nodes, "pageInfo": {"hasNextPage": more, "endCursor": str(page + 1)}
        }}}}})

    @staticmethod
    def comment(number, body):
        return {"id": number, "user": {"login": "codeant-ai[bot]", "type": "Bot", "id": 9},
                "body": body, "submitted_at": "2026-11-01T00:00:00Z", "created_at": "2026-11-01T00:00:00Z"}

    def run_snapshot(self, shell, since=False, success=True):
        before = set(self.scratch.glob("pr-state-work-987654-*"))
        cmd = [shell, str(self.scripts / "pr-state.sh"), "--pr", "987654"]
        if since:
            cmd += ["--since", "2026-10-01T00:00:00Z"]
        result = subprocess.run(cmd, env=self.env, text=True, capture_output=True, timeout=60)
        self.assertEqual(set(self.scratch.glob("pr-state-work-987654-*")), before, "scratch leaked")
        if not success:
            self.assertEqual(result.returncode, 5, result.stderr[-2000:])
            self.assertEqual(result.stdout, "")
            return None
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        out = Path(result.stdout.strip())
        self.addCleanup(out.unlink, missing_ok=True)
        self.assertTrue(out.is_file(), "only the surviving output path is published")
        data = json.loads(out.read_text())
        for line in (self.root / "argv.jsonl").read_text().splitlines():
            observed = json.loads(line)
            self.assertLess(max(observed["argv_sizes"], default=0), 65536, "endpoint data reached argv")
            for scratch in observed["scratch"]:
                self.assertEqual(Path(scratch).parent, self.scratch, "invocation scratch escaped private TMPDIR")
        return data

    def shells(self):
        return [p for p in ("/bin/bash", "/opt/homebrew/bin/bash") if Path(p).is_file()]

    def test_missing_check_endpoint_is_api_failure_not_missing_pr(self):
        (self.fixture / "checks-404").touch()
        for shell in self.shells():
            with self.subTest(shell=shell):
                self.run_snapshot(shell, success=False)

    def test_large_endpoints_and_classification(self):
        # Each body exceeds 1 MiB; the combined bundle exceeds 5 MiB. Full
        # sentinels at the end prevent a truncating implementation from passing.
        text = "x" * (1100 * 1024) + " END-OF-SYNTHETIC-BODY"
        self.write("reviews", [self.comment(11, text)])
        self.write("inline", [self.comment(12, text)])
        self.write("conversation", [self.comment(13, text)])
        self.write("statuses", [{"context": "CodeRabbit", "state": "success", "description": text,
                                 "updated_at": "2026-11-01T00:00:00Z"}])
        self.thread_page(0, True, [{"id": "first", "isResolved": True, "comments": {"nodes": [{"body": text}]}}])
        self.thread_page(1, False, [{"id": "second", "isResolved": False, "comments": {"nodes": [{"body": text}]}}])
        for shell in self.shells():
            for since in (False, True):
                with self.subTest(shell=shell, since=since):
                    d = self.run_snapshot(shell, since)
                    self.assertEqual([t["id"] for t in d["threads"]["all"]], ["first", "second"])
                    self.assertEqual([t["id"] for t in d["threads"]["unresolved"]], ["second"])
                    self.assertEqual(d["threads"]["resolved_count"], 1)
                    for endpoint in ("reviews", "inline", "conversation"):
                        self.assertEqual(d["comments"][endpoint][0]["body"], text)
                    self.assertEqual(d["bot_statuses"]["CodeRabbit"]["description"], text)
                    self.assertEqual(d["new_since_baseline"] is None, not since)
                    if since:
                        self.assertEqual(d["new_since_baseline"]["finding_count"], 3)

    def test_mostly_unresolved_history_with_bounded_scratch(self):
        # Two >1MiB pages fit within this private 4MiB capacity, including a
        # transient current page. Additional complete history copies do not.
        text = "x" * (1100 * 1024)
        for page in (0, 1):
            self.thread_page(page, page == 0, [{"id": str(page), "isResolved": False,
                                             "comments": {"nodes": [{"body": text}]}}])
        self.env["SCRATCH_BYTE_LIMIT"] = str(4 * 1024 * 1024)
        for shell in self.shells():
            with self.subTest(shell=shell):
                d = self.run_snapshot(shell)
                self.assertEqual(d["threads"]["total"], 2)
                self.assertEqual(d["threads"]["unresolved_count"], 2)
                self.assertEqual(d["threads"]["all"], d["threads"]["unresolved"])

    def test_small_schema_and_values(self):
        for shell in self.shells():
            with self.subTest(shell=shell):
                d = self.run_snapshot(shell)
                self.assertEqual(set(d), {"schema_version", "pr", "run_started_at", "since", "threads", "check_runs",
                                          "commit_statuses", "bot_statuses", "comments", "new_since_baseline", "unmarked_replies", "merge_state"})
                self.assertEqual(d["schema_version"], "1.0")
                self.assertEqual(d["threads"], {"total": 0, "resolved_count": 0, "unresolved_count": 0, "unresolved": [], "all": []})
                self.assertEqual(d["comments"], {"reviews": [], "inline": [], "conversation": []})
                self.assertEqual(d["unmarked_replies"], 0)
                self.assertEqual({run["name"] for run in d["check_runs"]["all"]},
                                 {"fixture-ci", "workflow: 1 (push)"})
                self.assertEqual(d["merge_state"], {"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED"})

    def test_failure_cleans_scratch_and_publishes_no_path(self):
        (self.fixture / "fail-api").touch()
        for shell in self.shells():
            with self.subTest(shell=shell):
                self.run_snapshot(shell, success=False)


if __name__ == "__main__":
    unittest.main()
