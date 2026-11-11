#!/usr/bin/env bash
# catalog: tests — Tests real babysit bookkeeping and cadence fences against supersession and owned rollback
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BABYSIT_TEST_SHELL="${BABYSIT_TEST_SHELL:-$BASH}" python3 - "$ROOT" "$@" <<'PY'
import copy,json,os,re,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(sys.argv[1]);SHELL=os.environ['BABYSIT_TEST_SHELL'];REPO='auerbachb/claude-code-config';PR='123'
SKILL=Path(os.environ.get('BABYSIT_TEST_SKILL_SOURCE',ROOT/'.claude/skills/babysit-pr/SKILL.md'))
def fence(name):
    return subprocess.check_output([SHELL,'-c','source "$1"; extract_skill_bash "$2" "$3"','--',str(ROOT/'.claude/scripts/tests/lib/skill-bash.sh'),str(SKILL),name],text=True).rstrip('\n')
PERSIST=fence('babysit-pr-t5-persist')
# Old-source controls run just the persist case, whose old fence is annotated
# privately. Resolve the additional fences only in cases that execute them.
def cadence(name):return fence('babysit-pr-t5-cadence-'+name)
def terminal(name):return fence('babysit-pr-terminal-owner-'+name)
class Persist(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='babysit-cas-');self.addCleanup(self.tmp.cleanup);self.home=Path(self.tmp.name);(self.home/'.claude').mkdir();self.state=self.home/'.claude/session-state.json'
        self.watch=dict(active=True,stop_requested=False,cadence_transition=False,monitor_generation='old',monitor_task_id='old-task',cadence_effective_minutes=5,tick_count=1,blocker_streak=1,conflict_streak=1,horizon_status='critical',horizon_held_since='2026-11-01T00:00:00Z',last_tick_at='2026-11-01T00:00:00Z',unknown={'keep':False})
        self.entry=dict(babysit=self.watch,digest='sha256:before',digest_streak=1,last_cron_action={'type':'original'})
        self.state.write_text(json.dumps({'repos':{REPO:{'prs':{PR:self.entry}},'foreign/repo':{'sentinel':False}}}));self.initial=self.state.read_bytes()
        self.helper=self.home/'state-wrapper.sh';self.helper.write_text('''#!/usr/bin/env bash
set -u
get=false; cas=false; value=""
for arg in "$@"; do
  [[ "$arg" != --get-json ]] || get=true
  [[ "$arg" != --cas ]] || cas=true
  case "$arg" in *.babysit=*) value="${arg#*=}" ;; esac
done
if [[ "$get" == true && "${READ_FAIL:-false}" == true ]]; then exit 6; fi
if [[ "$cas" == true && "${CAS_FAIL:-false}" == true ]]; then exit 6; fi
mutate() { "$REAL_STATE" --repo "$TEST_REPO" --set ".prs[\\"$TEST_PR\\"].babysit=$(cat "$RACE_JSON")"; }
if [[ "$cas" == true && "${RACE_MODE:-}" == before-cas ]]; then
  count=0
  [[ ! -f "$RACE_COUNT" ]] || read -r count < "$RACE_COUNT"
  count=$((count + 1)); printf '%s\n' "$count" > "$RACE_COUNT"
  if [[ "$count" -eq "${RACE_CAS_NTH:-1}" ]] && mkdir "$RACE_ONCE" 2>/dev/null; then mutate || exit 1; fi
fi
if [[ "$get" == true && "${RACE_MODE:-}" == after-get ]] && mkdir "$RACE_ONCE" 2>/dev/null; then
  out=$("$REAL_STATE" "$@") || exit "$?"
  mutate || exit 1
  printf '%s\\n' "$out"
  exit 0
fi
if [[ "$cas" == true && "${AFTER_COMMIT_FAIL:-false}" == true ]] && printf '%s' "$value" | jq -e '.monitor_generation == "new" and .stop_requested == false' >/dev/null 2>&1; then
  "$REAL_STATE" "$@" || exit "$?"
  exit 5
fi
exec "$REAL_STATE" "$@"
''');self.helper.chmod(0o700)
        self.env=os.environ.copy();self.env.update(HOME=str(self.home),SESSION_STATE_SH=str(self.helper),REAL_STATE=str(ROOT/'.claude/scripts/session-state.sh'),TEST_REPO=REPO,TEST_PR=PR,PR=PR,BABYSIT_INTERNAL_TICK='true',TICK_GENERATION='old',MONITOR_GENERATION='old',DIGEST='sha256:after',STREAK='3',BLOCKER_STREAK='4',CONFLICT_STREAK_NEW='5',NEW_TICK_COUNT='2',HORIZON_STATUS='critical',EFFECTIVE_MIN='10',PREV_EFFECTIVE_MIN='5',NEW_MONITOR_TASK_ID='replacement-task',NEW_MONITOR_GENERATION='new')
    def current(self):return json.loads(self.state.read_text())['repos'][REPO]['prs'][PR]
    def run_block(self,block,extra=None):
        env=self.env.copy();env.update(extra or {});return subprocess.run([SHELL,'-u','-c',block],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
    def mutate_command(self,watch):
        path=self.home/'foreign.json';path.write_text(json.dumps(watch));return '"$REAL_STATE" --repo "$TEST_REPO" --set ".prs[\\"$PR\\"].babysit=$(cat '+str(path)+')"\n'
    def foreign(self):
        v=copy.deepcopy(self.watch);v.update(monitor_generation='foreign',monitor_task_id='foreign-task',tick_count=777,last_tick_at='2026-11-07T00:00:00Z');return v
    def race(self,mode):
        path=self.home/'race.json';path.write_text(json.dumps(self.foreign()));return dict(RACE_MODE=mode,RACE_JSON=str(path),RACE_ONCE=str(self.home/'once'),RACE_COUNT=str(self.home/'count'))
    def assert_foreign_bucket(self):self.assertEqual(json.loads(self.state.read_text())['repos']['foreign/repo'],{'sentinel':False})
    def test_review_deadline_is_published_with_its_task(self):
        gate = {"head_sha": "current", "no_review_override": {
            "reason": "window_running", "eligible_at": "2026-11-11T07:00:00Z"}}
        env = dict(HEAD_SHA="current", GATE_JSON=json.dumps(gate),
                   CLASS="waiting-on-bots", EFFECTIVE_MIN="5")
        decision = fence("babysit-pr-t5-rearm-decision")
        check = '\nprintf "REARM=%s\\n" "$REARM"\n'
        code = PERSIST + "\n" + decision + check + cadence("guard") + "\n" + cadence("publish")
        result = self.run_block(code, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("REARM=true", result.stdout)
        watch = self.current()["babysit"]
        epoch = watch["armed_review_deadline"]
        self.assertEqual(watch["review_wait"], {"head_sha": "current", "eligible_at_epoch": epoch})
        self.assertEqual(epoch, 1794380400)
        self.assertEqual(watch["classification"], "waiting-on-bots")
        self.assertEqual(watch["monitor_generation"], "new")
        self.assertEqual(watch["monitor_task_id"], "replacement-task")
        self.assertEqual(self.current()["last_cron_action"], {"type": "original"})

        env["TICK_GENERATION"] = "new"
        result = self.run_block(PERSIST + "\n" + decision + check, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("REARM=false", result.stdout)
        self.assertEqual(self.current()["babysit"]["armed_review_deadline"], epoch)

        env["HEAD_SHA"] = "replaced"
        result = self.run_block(PERSIST + "\n" + decision + check, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("REARM=false", result.stdout)
        self.assertIsNone(self.current()["babysit"]["review_wait"])

    def test_pending_wait_outlasts_both_streak_limits(self):
        check = ('\nprintf "result=%s:%s\\n" "$BLOCKER_STREAK" "$BACKOFF_STOP_REASON"\n')
        code = (fence("babysit-pr-t5-blocker-streak") + "\n"
                + fence("babysit-pr-t6-backoff-termination") + check)
        env = dict(T0_SNAPSHOT='{"blocker_streak":9,"max_blocker_ticks":6}',
                   PREV_DIGEST="sha256:after", STREAK="12")
        for kind, suppressed, expected in [
                ("waiting-on-bots", "false", "0:"),
                ("has-recoverable-blockers", "false", "10:blocker-tick-cap"),
                ("merge-ready", "true", "10:blocker-tick-cap"),
                ("conflicting", "false", "0:stable-frozen")]:
            with self.subTest(kind=kind, suppressed=suppressed):
                result = self.run_block(code, dict(env, CLASS=kind, DISPATCH_SUPPRESSED=suppressed))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"result={expected}")

    def test_monitor_emits_one_shortened_or_immediate_deadline_tick(self):
        clock = r"""
now=1000
calls=0
date() { printf '%s\n' "$now"; }
sleep() {
  (( calls < 3 )) || return 1
  calls=$((calls + 1))
  now=$((now + $1))
  printf 'sleep=%s\n' "$1"
}
"""
        for deadline, expected in [(0, [300, 300, 300]), (1100, [100, 300, 300]),
                                   (999, [0, 300, 300]), (1450, [300, 150, 300])]:
            with self.subTest(deadline=deadline):
                result = self.run_block(clock + fence("babysit-pr-monitor-loop"), {
                    "MONITOR_REVIEW_DEADLINE": str(deadline), "MONITOR_CADENCE": "5"})
                self.assertEqual(result.returncode, 0, result.stderr)
                waits = [int(line.split("=")[1]) for line in result.stdout.splitlines()
                         if line.startswith("sleep=")]
                self.assertEqual(waits, expected)
                self.assertEqual(result.stdout.count(
                    "/babysit-pr 123 --tick --monitor-generation old --cadence 5m"), 3)

    def test_old_tick_after_t0_cannot_persist(self):
        f=self.foreign();setup=self.run_block(self.mutate_command(f));self.assertEqual(setup.returncode,0,setup.stderr);self.assertEqual(self.current()['babysit'],f);before=self.state.read_bytes();p=self.run_block(PERSIST+'\necho REACHED_T6');self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('REACHED_T6',p.stdout);self.assertEqual(self.state.read_bytes(),before,'old tick overwrote replacement bookkeeping')
    def test_snapshot_to_cas_supersession_is_atomic(self):
        for mode in ['after-get','before-cas']:
            with self.subTest(mode=mode):
                self.state.write_bytes(self.initial);counter=self.home/'count';counter.unlink() if counter.exists() else None;marker=self.home/'once';marker.rmdir() if marker.exists() else None
                p=self.run_block(PERSIST+'\necho REACHED_T6',self.race(mode));self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('REACHED_T6',p.stdout);self.assertEqual(self.current()['babysit'],self.foreign());self.assertEqual(self.current()['digest'],'sha256:before');self.assert_foreign_bucket()
    def test_json_encoded_generation_and_new_critical_stamp(self):
        weird='old"\\generation';v=self.current();v['babysit']['monitor_generation']=weird;v['babysit']['horizon_held_since']=None
        data=json.loads(self.state.read_text());data['repos'][REPO]['prs'][PR]=v;self.state.write_text(json.dumps(data))
        p=self.run_block(PERSIST,dict(TICK_GENERATION=weird));self.assertEqual(p.returncode,0,p.stderr);v=self.current()['babysit'];self.assertEqual(v['monitor_generation'],weird);self.assertEqual(v['horizon_held_since'],v['last_tick_at']);self.assertTrue(v['horizon_held_since'])
    def test_stopped_or_malformed_watcher_never_refreshes_bookkeeping(self):
        for watcher,expected in [(dict(self.watch,stop_requested=True),0),(['malformed'],1)]:
            with self.subTest(watcher=watcher):
                data=json.loads(self.initial);data['repos'][REPO]['prs'][PR]['babysit']=watcher;self.state.write_text(json.dumps(data));before=self.state.read_bytes();p=self.run_block(PERSIST+'\necho REACHED_T6');self.assertEqual(p.returncode,expected,p.stderr);self.assertNotIn('REACHED_T6',p.stdout);self.assertEqual(self.state.read_bytes(),before)
    def test_cadence_snapshot_to_guard_cas_loses_without_stopping(self):
        env=self.race('before-cas');env['RACE_CAS_NTH']='2';p=self.run_block(PERSIST+'\n'+cadence('guard')+'\necho STOPPED_TASK',env);self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('STOPPED_TASK',p.stdout);self.assertEqual(self.current()['babysit'],self.foreign())
    def test_current_tick_preserves_unknown_fields_and_critical_stamp(self):
        p=self.run_block(PERSIST);self.assertEqual(p.returncode,0,p.stderr);v=self.current();self.assertEqual(v['digest'],'sha256:after');self.assertEqual(v['digest_streak'],3);self.assertEqual([v['babysit'][x] for x in ['tick_count','blocker_streak','conflict_streak']],[2,4,5]);self.assertEqual(v['babysit']['horizon_held_since'],self.watch['horizon_held_since']);self.assertEqual(v['babysit']['unknown'],{'keep':False});self.assertNotEqual(v['babysit']['last_tick_at'],self.watch['last_tick_at']);self.assert_foreign_bucket()
    def test_immediate_arm_uses_published_arm_generation(self):
        p=self.run_block(PERSIST,dict(BABYSIT_INTERNAL_TICK='false',TICK_GENERATION='foreign'));self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.current()['babysit']['tick_count'],2)
    def test_missing_authorization_and_io_failures_do_not_write(self):
        for env in [dict(TICK_GENERATION=''),dict(READ_FAIL='true'),dict(CAS_FAIL='true')]:
            with self.subTest(env=env):
                before=self.state.read_bytes();p=self.run_block(PERSIST,env);self.assertEqual(p.returncode,1,p.stderr);self.assertEqual(self.state.read_bytes(),before)
    def test_noncritical_clears_only_its_held_stamp(self):
        p=self.run_block(PERSIST,dict(HORIZON_STATUS='clear'));self.assertEqual(p.returncode,0,p.stderr);self.assertIsNone(self.current()['babysit']['horizon_held_since'])
    def test_cadence_guard_never_adopts_a_replacement(self):
        code=PERSIST+'\n'+self.mutate_command(self.foreign())+cadence('guard')+'\necho STOPPED_FOREIGN';p=self.run_block(code);self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('STOPPED_FOREIGN',p.stdout);self.assertEqual(self.current()['babysit'],self.foreign());self.assertEqual(self.current()['last_cron_action'],{'type':'original'})
    def test_missing_identity_sets_owned_stop_guard_without_arming(self):
        data=json.loads(self.initial);data['repos'][REPO]['prs'][PR]['babysit']['monitor_task_id']=None;self.state.write_text(json.dumps(data))
        p=self.run_block(PERSIST+'\n'+cadence('guard')+'\necho ARMED_TASK');self.assertEqual(p.returncode,1,p.stderr);self.assertNotIn('ARMED_TASK',p.stdout);v=self.current()['babysit'];self.assertTrue(v['active']);self.assertTrue(v['stop_requested']);self.assertIsNone(v['monitor_task_id']);self.assertEqual(v['monitor_generation'],'old');self.assertEqual(v['cadence_effective_minutes'],5)
    def test_cadence_publish_retains_metadata_and_commits_action(self):
        code=PERSIST+'\n'+cadence('guard')+'\nprintf "STOP=%s\\n" "$CADENCE_TASK_ID"\n'+cadence('publish');p=self.run_block(code);self.assertEqual(p.returncode,0,p.stderr);self.assertIn('STOP=old-task',p.stdout);self.assertIn('CADENCE_PUBLISH=armed',p.stdout);v=self.current();self.assertEqual(v['babysit']['monitor_task_id'],'replacement-task');self.assertEqual(v['babysit']['monitor_generation'],'new');self.assertEqual(v['babysit']['cadence_effective_minutes'],10);self.assertFalse(v['babysit']['stop_requested']);self.assertFalse(v['babysit']['cadence_transition']);self.assertEqual(v['babysit']['unknown'],{'keep':False});self.assertEqual(v['last_cron_action']['interval'],'10m')
    def test_publication_loss_and_rollback_retain_foreign_watcher(self):
        code=PERSIST+'\n'+cadence('guard')+'\n'+self.mutate_command(self.foreign())+cadence('publish')+'\nREPLACEMENT_STOP_SUCCEEDED=true\n'+cadence('rollback');p=self.run_block(code);self.assertEqual(p.returncode,1,p.stderr);self.assertIn('CADENCE_PUBLISH=lost',p.stdout);self.assertEqual(self.current()['babysit'],self.foreign());self.assertEqual(self.current()['last_cron_action'],{'type':'original'})
    def test_arm_failure_owned_cleanup_clears_only_its_watcher(self):
        code=PERSIST+'\n'+cadence('guard')+'\nREPLACEMENT_STOP_SUCCEEDED=true\n'+cadence('rollback');p=self.run_block(code);self.assertEqual(p.returncode,1,p.stderr);v=self.current()['babysit'];self.assertFalse(v['active']);self.assertIsNone(v['monitor_task_id']);self.assertIsNone(v['monitor_generation']);self.assertEqual(v['unknown'],{'keep':False})
    def test_unknown_publication_after_commit_is_reconciled_by_owned_cleanup(self):
        code=PERSIST+'\n'+cadence('guard')+'\n'+cadence('publish')+'\nREPLACEMENT_STOP_SUCCEEDED=true\n'+cadence('rollback');p=self.run_block(code,dict(AFTER_COMMIT_FAIL='true'));self.assertEqual(p.returncode,1,p.stderr);self.assertIn('CADENCE_PUBLISH=failed rc=5',p.stdout);self.assertFalse(self.current()['babysit']['active']);self.assertIsNone(self.current()['babysit']['monitor_task_id']);self.assertEqual(self.current()['last_cron_action']['type'],'delete','rollback left a false widen acknowledgement');self.assertEqual(self.current()['last_cron_action']['interval'],'paused')
    def test_unstoppable_owned_replacement_is_retained_with_stop_guard(self):
        code=PERSIST+'\n'+cadence('guard')+'\n'+cadence('publish')+'\nREPLACEMENT_STOP_SUCCEEDED=false\n'+cadence('rollback');p=self.run_block(code,dict(AFTER_COMMIT_FAIL='true'));self.assertEqual(p.returncode,1,p.stderr);v=self.current()['babysit'];self.assertTrue(v['active']);self.assertTrue(v['stop_requested']);self.assertEqual(v['monitor_task_id'],'replacement-task');self.assertEqual(v['monitor_generation'],'new')
    def set_watch(self,watch):
        data=json.loads(self.initial);data['repos'][REPO]['prs'][PR]['babysit']=watch;self.state.write_text(json.dumps(data))
    def test_tick_gate_discards_cadence_transition_in_both_modes(self):
        for internal in ['true','false']:
            with self.subTest(internal=internal):
                self.set_watch(dict(self.watch,cadence_transition=True));before=self.state.read_bytes();p=self.run_block(fence('babysit-pr-t0-owner-gate')+'\necho REACHED_T5',dict(BABYSIT_INTERNAL_TICK=internal));self.assertEqual(p.returncode,0,p.stderr);self.assertIn('TICK_GATE=cadence-transition',p.stdout);self.assertNotIn('REACHED_T5',p.stdout);self.assertEqual(self.state.read_bytes(),before)
    def test_tick_gate_keeps_user_stop_distinct(self):
        self.set_watch(dict(self.watch,stop_requested=True));before=self.state.read_bytes();p=self.run_block(fence('babysit-pr-t0-owner-gate')+'\necho REACHED_T5');self.assertEqual(p.returncode,0,p.stderr);self.assertIn('TICK_GATE=user-stop',p.stdout);self.assertNotIn('REACHED_T5',p.stdout);self.assertEqual(self.state.read_bytes(),before)
    def test_tick_gate_rejects_foreign_generation_in_immediate_arm_mode(self):
        self.set_watch(self.foreign());before=self.state.read_bytes();p=self.run_block(fence('babysit-pr-t0-owner-gate')+'\necho REACHED_T5',dict(BABYSIT_INTERNAL_TICK='false'));self.assertEqual(p.returncode,0,p.stderr);self.assertIn('TICK_GATE=lost',p.stdout);self.assertNotIn('REACHED_T5',p.stdout);self.assertEqual(self.state.read_bytes(),before)
    def test_terminal_old_tick_never_touches_a_replacement(self):
        self.set_watch(self.foreign());before=self.state.read_bytes();p=self.run_block(terminal('guard')+'\nprintf "STOP=%s\\n" "$TERMINAL_TASK_ID"');self.assertEqual(self.state.read_bytes(),before,'old terminal tick touched foreign watcher');self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('STOP=',p.stdout)
    def test_terminal_guard_cas_loss_exposes_no_foreign_task(self):
        p=self.run_block(terminal('guard')+'\nprintf "STOP=%s\\n" "$TERMINAL_TASK_ID"',self.race('before-cas'));self.assertEqual(p.returncode,0,p.stderr);self.assertIn('TERMINAL_GUARD=lost',p.stdout);self.assertNotIn('STOP=',p.stdout);self.assertEqual(self.current()['babysit'],self.foreign())
    def test_terminal_cleanup_after_rearm_retains_the_new_watcher(self):
        code=terminal('guard')+'\nprintf "STOP=%s\\n" "$TERMINAL_TASK_ID"\n'+self.mutate_command(self.foreign())+'TERMINAL_STOP_SUCCEEDED=true\n'+terminal('cleanup');p=self.run_block(code);self.assertEqual(p.returncode,1,p.stderr);self.assertIn('STOP=old-task',p.stdout);self.assertEqual(self.current()['babysit'],self.foreign());self.assertEqual(self.current()['last_cron_action'],{'type':'original'})
    def test_terminal_cleanup_is_owned_and_records_delete(self):
        code=terminal('guard')+'\nprintf "STOP=%s\\n" "$TERMINAL_TASK_ID"\nTERMINAL_STOP_SUCCEEDED=true\n'+terminal('cleanup');p=self.run_block(code);self.assertEqual(p.returncode,0,p.stderr);self.assertIn('STOP=old-task',p.stdout);self.assertIn('TERMINAL_CLEANUP=cleared',p.stdout);v=self.current();self.assertFalse(v['babysit']['active']);self.assertIsNone(v['babysit']['monitor_task_id']);self.assertIsNone(v['babysit']['monitor_generation']);self.assertFalse(v['babysit']['cadence_transition']);self.assertEqual(v['last_cron_action']['type'],'delete');self.assert_foreign_bucket()
    def test_failed_terminal_stop_retains_guard_and_original_action(self):
        code=terminal('guard')+'\nTERMINAL_STOP_SUCCEEDED=false\n'+terminal('cleanup');p=self.run_block(code);self.assertEqual(p.returncode,1,p.stderr);v=self.current();self.assertTrue(v['babysit']['active']);self.assertTrue(v['babysit']['stop_requested']);self.assertEqual(v['babysit']['monitor_task_id'],'old-task');self.assertEqual(v['last_cron_action'],{'type':'original'})
    def test_terminal_transition_is_held_not_a_user_stop(self):
        self.set_watch(dict(self.watch,cadence_transition=True));before=self.state.read_bytes();p=self.run_block(terminal('guard')+'\nprintf "STOP=%s\\n" "$TERMINAL_TASK_ID"');self.assertEqual(p.returncode,0,p.stderr);self.assertIn('TERMINAL_GUARD=cadence-transition',p.stdout);self.assertNotIn('STOP=',p.stdout);self.assertEqual(self.state.read_bytes(),before)
    def test_missing_identity_even_at_unchanged_cadence_cannot_refresh(self):
        self.set_watch(dict(self.watch,monitor_task_id=None));p=self.run_block(PERSIST+'\nif [[ "$EFFECTIVE_MIN" == "$PREV_EFFECTIVE_MIN" ]]; then echo HEALTHY_RETAIN; fi',dict(EFFECTIVE_MIN='5'));self.assertEqual(p.returncode,1,p.stderr);self.assertNotIn('HEALTHY_RETAIN',p.stdout);v=self.current();self.assertTrue(v['babysit']['stop_requested'],'unchanged cadence retained a watcher without identity');self.assertFalse(v['babysit']['cadence_transition']);self.assertEqual(v['babysit']['last_tick_at'],self.watch['last_tick_at']);self.assertEqual(v['digest'],'sha256:before')
if __name__=='__main__':unittest.main(argv=[sys.argv[0],*sys.argv[2:]],verbosity=2)
PY
