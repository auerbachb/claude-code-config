#!/usr/bin/env bash
# catalog: tests — Exercises both PM wake-publication fences with real state CAS and deterministic retirement races
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
PARK_WAKE_TEST_SHELL="${PARK_WAKE_TEST_SHELL:-$BASH}" python3 - "$ROOT" "$@" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(sys.argv[1])
SHELL = os.environ['PARK_WAKE_TEST_SHELL']
MODULES = ROOT / '.claude/skills/pm/modules'
SKILL_OVERRIDE = os.environ.get('PARK_WAKE_TEST_SKILL_SOURCE')


def park_text(cause):
    path = Path(SKILL_OVERRIDE) if SKILL_OVERRIDE else MODULES / f'day-park-{cause}.md'
    return path.read_text()
HELPER = Path(os.environ.get('PARK_WAKE_TEST_HELPER_SOURCE', ROOT / '.claude/scripts/park-wake-publish.sh'))
REAL_STATE = ROOT / '.claude/scripts/session-state.sh'
REPO = 'owner/repo'

class Publication(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='park-wake-publish-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.bin / 'bash').symlink_to(SHELL)
        installed = self.home / '.claude/scripts'
        installed.mkdir(parents=True)
        shutil.copyfile(HELPER, installed / 'park-wake-publish.sh')
        (installed / 'park-wake-publish.sh').chmod(0o700)
        self.state = self.home / '.claude/session-state.json'
        self.stop_log = self.root / 'stopped'
        self.calls = self.root / 'calls'
        self.marker = self.root / 'changed'
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        STOP_LOG=str(self.stop_log), STOP_RC='0',
                        TEST_STATE=str(self.state), TEST_REAL_STATE=str(REAL_STATE),
                        TEST_SHELL=SHELL, TEST_CALLS=str(self.calls),
                        TEST_MARKER=str(self.marker), TEST_ROOT=str(self.root),
                        TEST_MODE='none', TEST_CALL_ID='one')
        self.tool('TaskStop', '#!/usr/bin/env bash\nprintf \'%s\\n\' "$1" >> "$STOP_LOG"\nexit "$STOP_RC"\n')
        self.proxy = self.root / 'state-proxy'
        self.tool_path(self.proxy, '#!' + sys.executable + '\n' + r'''
import json, os, pathlib, subprocess, sys, time
args=sys.argv[1:]; root=pathlib.Path(os.environ['TEST_ROOT']); mode=os.environ['TEST_MODE']
with open(os.environ['TEST_CALLS'],'a') as out: out.write(json.dumps(args)+'\n')
real=os.environ['TEST_REAL_STATE']; shell=os.environ['TEST_SHELL']
if '--get-json' in args:
 if mode=='read-fail': sys.exit(6)
 if mode=='read-malformed': print('{');sys.exit(0)
 if mode=='read-empty': sys.exit(0)
 if mode=='read-multiple': print('{}\n{}');sys.exit(0)
 if mode=='verify-fail' and pathlib.Path(os.environ['TEST_MARKER']).exists(): sys.exit(6)
if '--cas' in args:
 marker=pathlib.Path(os.environ['TEST_MARKER'])
 if mode=='write-fail': sys.exit(6)
 if mode in ('synthetic-loss','verify-fail'):
  marker.touch();sys.exit(7)
 if mode=='race':
  (root/('cas-'+os.environ['TEST_CALL_ID'])).touch()
  end=time.monotonic()+10
  while not (root/'go').exists():
   if time.monotonic()>end: sys.exit(98)
   time.sleep(.02)
 if mode in ('retire','replace','metadata','occupy','replace-generation') and not marker.exists():
  marker.touch(); prefix='.repos["owner/repo"].day.'
  if mode=='retire':
   values={k:None for k in ['parked_until','limit_kind','limit_cause','park_claim_token','limit_probe_fires_remaining','limit_resume_task_id','limit_resume_generation']}
  elif mode=='replace':
   values={'parked_until':'2026-11-09T17:00:00Z','limit_kind':'rolling_window','limit_cause':'reactive','park_claim_token':None,'limit_resume_task_id':'foreign-task','limit_resume_generation':'foreign-generation'}
  elif mode=='replace-generation': values={'park_generation':'park-replacement'}
  elif mode=='metadata': values={'other_metadata':'new'}
  else: values={'limit_resume_task_id':'foreign-task','limit_resume_generation':'foreign-generation'}
  cmd=[shell,real,'--repo','owner/repo']
  for key,value in values.items():cmd+=['--set',prefix+key+'='+json.dumps(value)]
  result=subprocess.run(cmd)
  if result.returncode:sys.exit(result.returncode)
os.execv(shell,[shell,real]+args)
''')
        self.blocks = {}
        for cause, anchor in [('reactive', 'pm-day-2d6-wake-publish'), ('preemptive', 'pm-day-2d7-wake-publish')]:
            match = re.search(r'<!-- test-anchor: ' + anchor + r' -->\s*```bash\n(.*?)\n```', park_text(cause), re.S)
            self.assertIsNotNone(match, anchor)
            self.blocks[cause] = match.group(1)
        subagent=(ROOT / '.claude/reference/subagent-thread-limit-park.md').read_text()
        m=re.search(r'<!-- test-anchor: subagent-limit-wake-publish -->\s*```bash\n(.*?)\n```',subagent,re.S)
        self.assertIsNotNone(m)
        self.blocks['subagent']=m.group(1)
        shutil.copyfile(ROOT / '.claude/scripts/park-generation.sh', installed / 'park-generation.sh')
        (installed / 'park-generation.sh').chmod(0o700)
        self.seed('preemptive')

    def tool(self, name, body):
        self.tool_path(self.bin / name, body)

    def tool_path(self, path, body):
        path.write_text(body)
        path.chmod(0o700)

    def seed(self, cause):
        day = dict(active=True, parked_until='2026-11-08T17:00:00Z',
                   limit_kind='rolling_window',
                   limit_cause=cause, park_claim_token=None,
                   limit_resume_task_id=None, limit_resume_generation=None,
                   limit_probe_fires_remaining=12 if cause=='preemptive' else None,
                   other_metadata=dict(zero=0, empty='', flag=False))
        self.state.write_text(json.dumps(dict(schema_version=2,repos={REPO:dict(day=day),
                              'foreign/repo':dict(day=dict(owner='untouched'))})))
        for path in [self.stop_log,self.calls,self.marker]:
            path.unlink(missing_ok=True)

    def data(self):
        return json.loads(self.state.read_text())

    def day(self):
        return self.data()['repos'][REPO]['day']

    def set_day(self, **fields):
        d=self.data();d['repos'][REPO]['day'].update(fields);self.state.write_text(json.dumps(d))

    def stop(self, p):
        if p.poll() is None:
            try: os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError: pass
        p.communicate(timeout=5)

    def start(self, cause, task='own-task', generation='own-generation', mode='none', stop_rc=0, call_id='one', cwd=None, path=None, repo_key=REPO, unset_home=False, park_generation=''):
        env=dict(self.env,TEST_MODE=mode,STOP_RC=str(stop_rc),TEST_CALL_ID=call_id,
                 SESSION_STATE_SH=str(self.proxy),REPO_KEY=repo_key,
                 WAKE_TASK_ID=task,WAKE_GENERATION=generation,
                 LIMIT_MONITOR_TASK_ID=task,LIMIT_GENERATION=generation,PARK_GENERATION=park_generation)
        if path is not None:env['PATH']=path
        if unset_home:env.pop('HOME',None)
        p=subprocess.Popen([SHELL,'-u','-c',self.blocks[cause]],cwd=cwd or ROOT,env=env,
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        self.addCleanup(self.stop,p)
        return p

    def finish(self, p):
        out,err=p.communicate(timeout=20)
        self.assertEqual(p.returncode,0,err.decode())
        return out.decode().strip()

    def run_block(self, cause, **kwargs):
        return self.finish(self.start(cause,**kwargs))

    def stopped(self):
        return self.stop_log.read_text().splitlines() if self.stop_log.exists() else []

    def assert_foreign(self):
        self.assertEqual(self.data()['repos']['foreign/repo'],dict(day=dict(owner='untouched')))

    def test_publishes_pair_only_and_preserves_encoding_and_unknown_fields(self):
        for cause in ['reactive','preemptive']:
            with self.subTest(cause=cause):
                self.seed(cause);before=self.day()
                self.assertEqual(self.run_block(cause,task='17'),'WAKE_PUBLISH=armed')
                after=self.day();self.assertEqual(after['limit_resume_task_id'],17 if cause=='reactive' else '17')
                self.assertEqual(after['limit_resume_generation'],'own-generation')
                for key,value in before.items():
                    if key not in ['limit_resume_task_id','limit_resume_generation']:self.assertEqual(after[key],value)
                self.assertEqual(self.stopped(),[]);self.assert_foreign()
                calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
                writes=[a for a in calls if '--cas' in a]
                self.assertEqual(len(writes),1);self.assertEqual(writes[0].count('--set'),2)

    def test_reactive_publication_uses_the_receipt_numeric_boundary(self):
        for task in ['9007199254740992', '9007199254740990.9']:
            with self.subTest(task=task):
                self.seed('reactive')
                before = self.data()
                self.assertEqual(self.run_block('reactive', task=task), 'WAKE_PUBLISH=failed')
                self.assertEqual(self.data(), before)
                self.assertEqual(self.stopped(), [task])
                self.assertFalse(any('--cas' in json.loads(line) for line in self.calls.read_text().splitlines()))

        self.seed('reactive')
        self.assertEqual(self.run_block('reactive', task='9007199254740991'), 'WAKE_PUBLISH=armed')
        self.assertEqual(self.day()['limit_resume_task_id'], 9007199254740991)
        self.seed('reactive')
        self.assertEqual(self.run_block('reactive', task='"9007199254740992"'), 'WAKE_PUBLISH=armed')
        self.assertEqual(self.day()['limit_resume_task_id'], '9007199254740992')
        self.assertEqual(self.stopped(), [])

    def test_mixed_case_scope_uses_the_state_writers_canonical_key(self):
        for cause in ['reactive','preemptive']:
            self.seed(cause)
            self.assertEqual(self.run_block(cause,repo_key='Owner/Repo'),'WAKE_PUBLISH=armed')
            self.assertEqual(set(self.data()['repos']),{REPO,'foreign/repo'})
            self.assertEqual(self.day()['limit_resume_task_id'],'own-task')
            self.assert_foreign()

    def test_explicit_unknown_scope_is_preserved_without_adopting_the_checkout(self):
        for cause in ['reactive','preemptive']:
            with self.subTest(cause=cause):
                self.seed(cause);data=self.data();known=json.loads(json.dumps(data['repos'][REPO]))
                data['repos']['_unknown']=json.loads(json.dumps(known));self.state.write_text(json.dumps(data))
                self.assertEqual(self.run_block(cause,repo_key='_unknown'),'WAKE_PUBLISH=armed')
                result=self.data();self.assertEqual(result['repos'][REPO],known)
                self.assertEqual(result['repos']['_unknown']['day']['limit_resume_task_id'],'own-task')
                result['repos']['_unknown']['day'].update(limit_cause=None,parked_until=None,
                    limit_resume_task_id=None,limit_resume_generation=None)
                self.state.write_text(json.dumps(result));before=self.state.read_bytes()
                self.assertEqual(self.run_block(cause,repo_key='_unknown'),'WAKE_PUBLISH=lost')
                self.assertEqual(self.state.read_bytes(),before);self.assertEqual(self.stopped(),['own-task'])
                self.assert_foreign()

    def test_manual_only_or_unreadable_parks_cannot_publish(self):
        cases=[(dict(limit_kind='weekly'),'lost'),(dict(limit_kind='unexpected'),'failed'),
               (dict(limit_kind=None),'failed'),(dict(limit_probe_fires_remaining=0),'lost'),
               (dict(limit_probe_fires_remaining=-1),'lost'),
               (dict(limit_probe_fires_remaining='null'),'failed'),
               (dict(limit_probe_fires_remaining=1.5),'failed'),
               (dict(limit_probe_fires_remaining=9007199254740992),'failed')]
        for cause in ['reactive','preemptive']:
            for fields,outcome in cases:
                with self.subTest(cause=cause,fields=fields):
                    self.seed(cause);self.set_day(**fields);before=self.state.read_bytes()
                    self.assertEqual(self.run_block(cause),'WAKE_PUBLISH='+outcome)
                    self.assertEqual(self.state.read_bytes(),before);self.assertEqual(self.stopped(),['own-task'])

    def test_known_reset_preemptive_park_retains_the_null_bound_contract(self):
        self.seed('preemptive');self.set_day(limit_probe_fires_remaining=None)
        self.assertEqual(self.run_block('preemptive'),'WAKE_PUBLISH=armed')
        self.assertIsNone(self.day()['limit_probe_fires_remaining'])
        self.assertEqual(self.stopped(),[])

    def test_retired_after_arm_at_both_sites_writes_no_identity(self):
        for cause in ['reactive','preemptive']:
            with self.subTest(cause=cause):
                self.seed(cause)
                self.set_day(parked_until=None,limit_kind=None,limit_cause=None,park_claim_token=None,
                             limit_probe_fires_remaining=None)
                before=self.state.read_bytes();out=self.run_block(cause)
                self.assertIsNone(self.day()['limit_resume_task_id'],'wake resurrected onto retired park')
                self.assertIsNone(self.day()['limit_resume_generation'])
                self.assertEqual(self.state.read_bytes(),before)
                self.assertEqual(out,'WAKE_PUBLISH=lost');self.assertEqual(self.stopped(),['own-task'])

    def test_retirement_replacement_and_competing_wake_in_snapshot_gap(self):
        for cause in ['reactive','preemptive']:
            for mode in ['retire','replace','occupy']:
                with self.subTest(cause=cause,mode=mode):
                    self.seed(cause);self.assertEqual(self.run_block(cause,mode=mode),'WAKE_PUBLISH=lost')
                    self.assertTrue(self.marker.exists());day=self.day()
                    self.assertEqual(day['limit_resume_task_id'],None if mode=='retire' else 'foreign-task')
                    self.assertEqual(day['limit_resume_generation'],None if mode=='retire' else 'foreign-generation')
                    self.assertEqual(self.stopped(),['own-task']);self.assert_foreign()

    def test_metadata_conflict_and_unverifiable_loss_surface_failure(self):
        for cause in ['reactive','preemptive']:
            for mode in ['metadata','synthetic-loss','verify-fail']:
                with self.subTest(cause=cause,mode=mode):
                    self.seed(cause);self.assertEqual(self.run_block(cause,mode=mode),'WAKE_PUBLISH=failed')
                    self.assertIsNone(self.day()['limit_resume_task_id']);self.assertIsNone(self.day()['limit_resume_generation'])
                    self.assertEqual(self.day()['limit_cause'],cause)
                    self.assertEqual(self.day()['parked_until'],'2026-11-08T17:00:00Z')
                    if mode=='metadata':self.assertEqual(self.day()['other_metadata'],'new')
                    self.assertEqual(self.stopped(),['own-task']);self.assert_foreign()

    def test_existing_wake_and_midassembly_token_are_retained(self):
        for cause in ['reactive','preemptive']:
            for fields in [dict(limit_resume_task_id='foreign-task',limit_resume_generation='foreign-gen'),dict(park_claim_token='other-claim')]:
                with self.subTest(cause=cause,fields=fields):
                    self.seed(cause);self.set_day(**fields);before=self.state.read_bytes()
                    self.assertEqual(self.run_block(cause),'WAKE_PUBLISH=lost')
                    self.assertEqual(self.state.read_bytes(),before);self.assertEqual(self.stopped(),['own-task'])

    def test_unknown_or_half_written_identity_and_invalid_bounds_fail_closed(self):
        bad=[dict(limit_resume_task_id='foreign-task'),dict(limit_resume_generation='foreign-gen'),
             dict(limit_resume_task_id=False,limit_resume_generation='gen'),dict(park_claim_token=''),
             dict(limit_cause='null'),dict(parked_until=None),dict(parked_until='2026-02-30T17:00:00Z')]
        for cause in ['reactive','preemptive']:
            for fields in bad:
                with self.subTest(cause=cause,fields=fields):
                    self.seed(cause);self.set_day(**fields);before=self.state.read_bytes()
                    self.assertEqual(self.run_block(cause),'WAKE_PUBLISH=failed')
                    self.assertEqual(self.state.read_bytes(),before);self.assertEqual(self.stopped(),['own-task'])

    def test_read_and_write_errors_stop_only_own_wake_without_clearing_park(self):
        for cause in ['reactive','preemptive']:
            for mode in ['read-fail','read-malformed','read-empty','read-multiple','write-fail']:
                with self.subTest(cause=cause,mode=mode):
                    self.seed(cause);before=self.state.read_bytes()
                    self.assertEqual(self.run_block(cause,mode=mode),'WAKE_PUBLISH=failed')
                    self.assertEqual(self.state.read_bytes(),before);self.assertEqual(self.stopped(),['own-task'])

    def test_unsuccessful_stop_reports_stranded(self):
        for cause in ['reactive','preemptive']:
            for mode in ['retire','write-fail']:
                with self.subTest(cause=cause,mode=mode):
                    self.seed(cause);self.assertEqual(self.run_block(cause,mode=mode,stop_rc=1),'WAKE_PUBLISH=stranded')
                    self.assertEqual(self.stopped(),['own-task'])
                    self.assertIsNone(self.day()['limit_resume_task_id'])

    def test_two_publishers_have_one_winner_at_each_site(self):
        for cause in ['reactive','preemptive']:
            with self.subTest(cause=cause):
                self.seed(cause)
                for path in self.root.glob('cas-*'):path.unlink()
                (self.root/'go').unlink(missing_ok=True)
                tasks=['17','18'] if cause=='reactive' else ['own-one','own-two']
                procs=[self.start(cause,task=task,generation='gen-'+str(i),mode='race',call_id=str(i)) for i,task in enumerate(tasks)]
                try:
                    end=time.monotonic()+10
                    while len(list(self.root.glob('cas-*')))<2:
                        self.assertTrue(all(p.poll() is None for p in procs),'publisher exited before real CAS barrier')
                        self.assertLess(time.monotonic(),end,'publishers did not reach actual CAS')
                        time.sleep(.02)
                finally:(self.root/'go').touch()
                results=[self.finish(p) for p in procs]
                self.assertEqual(sorted(results),['WAKE_PUBLISH=armed','WAKE_PUBLISH=lost'])
                winner=results.index('WAKE_PUBLISH=armed');loser=1-winner
                expected=int(tasks[winner]) if cause=='reactive' else tasks[winner]
                self.assertEqual(self.day()['limit_resume_task_id'],expected)
                self.assertEqual(self.day()['limit_resume_generation'],'gen-'+str(winner))
                self.assertEqual(self.stopped(),[tasks[loser]]);self.assert_foreign()

    def test_missing_helper_and_dependency_fail_closed(self):
        for cause in ['reactive','preemptive']:
            self.seed(cause);before=self.state.read_bytes()
            installed=self.home/'.claude/scripts/park-wake-publish.sh'
            installed.rename(installed.with_suffix('.saved'))
            try:self.assertEqual(self.run_block(cause,cwd=self.root),'WAKE_PUBLISH=failed')
            finally:installed.with_suffix('.saved').rename(installed)
            self.assertEqual(self.state.read_bytes(),before);self.assertEqual(self.stopped(),['own-task'])
            self.stop_log.unlink()
            self.assertEqual(self.run_block(cause,path=str(self.bin)),'WAKE_PUBLISH=failed')
            self.assertEqual(self.state.read_bytes(),before);self.assertEqual(self.stopped(),['own-task'])

    def test_all_publishers_refuse_untrusted_checkout_and_allow_installed_locations(self):
        untrusted=self.root/'untrusted';scripts=untrusted/'.claude/scripts';scripts.mkdir(parents=True)
        sentinel=self.root/'untrusted-executed';self.env['PUBLISH_SENTINEL']=str(sentinel)
        fake=scripts/'park-wake-publish.sh';fake.write_text('#!/bin/sh\n: > "$PUBLISH_SENTINEL"\nexit 0\n');fake.chmod(0o700)
        installed=self.home/'.claude/scripts/park-wake-publish.sh';saved=installed.with_suffix('.saved')
        installed.rename(saved)
        try:
            for cause in ['reactive','preemptive','subagent']:
                self.seed('reactive' if cause=='subagent' else cause);before=self.state.read_bytes()
                expected='WAKE_PUBLISH=error rc=4' if cause=='subagent' else 'WAKE_PUBLISH=failed'
                self.assertEqual(self.run_block(cause,cwd=untrusted),expected)
                self.assertFalse(sentinel.exists());self.assertEqual(self.state.read_bytes(),before)
                self.assertEqual(self.stopped(),[] if cause=='subagent' else ['own-task'])
        finally:saved.rename(installed)
        first=self.home/'.claude/skills-worktree/.claude/scripts/park-wake-publish.sh';first.parent.mkdir(parents=True)
        for helper in [first,installed]:
            if helper==first:installed.rename(first)
            try:
                for cause in ['reactive','preemptive','subagent']:
                    self.seed('reactive' if cause=='subagent' else cause)
                    expected='WAKE_PUBLISH=ok' if cause=='subagent' else 'WAKE_PUBLISH=armed'
                    self.assertEqual(self.run_block(cause,cwd=untrusted),expected)
                    self.assertEqual(self.day()['limit_resume_task_id'],'own-task')
                    self.assertFalse(sentinel.exists());self.assertEqual(self.stopped(),[])
            finally:
                if helper==first:first.rename(installed)

    def test_published_r3_false_success_executes_checkout_helper(self):
        untrusted=self.root/'old-untrusted';scripts=untrusted/'.claude/scripts';scripts.mkdir(parents=True)
        sentinel=self.root/'old-executed';self.env['PUBLISH_SENTINEL']=str(sentinel)
        fake=scripts/'park-wake-publish.sh';fake.write_text('#!/bin/sh\n: > "$PUBLISH_SENTINEL"\nexit 0\n');fake.chmod(0o700)
        installed=self.home/'.claude/scripts/park-wake-publish.sh';installed.unlink()
        text=(ROOT/'.claude/scripts/tests/fixtures/park-wake-review3-1715.md').read_text()
        for cause,anchor in [('reactive','pm-day-2d6-wake-publish'),('preemptive','pm-day-2d7-wake-publish'),('subagent','subagent-limit-wake-publish')]:
            self.seed('reactive' if cause=='subagent' else cause);before=self.state.read_bytes();sentinel.unlink(missing_ok=True)
            m=re.search(r'<!-- test-anchor: '+anchor+r' -->\s*```bash\n(.*?)\n```',text,re.S);self.assertIsNotNone(m)
            self.blocks[cause]=m.group(1)
            self.assertEqual(self.run_block(cause,cwd=untrusted),'WAKE_PUBLISH=ok' if cause=='subagent' else 'WAKE_PUBLISH=armed')
            self.assertTrue(sentinel.exists());self.assertEqual(self.state.read_bytes(),before);self.assertEqual(self.stopped(),[])

    def test_unset_home_cannot_abort_before_stopping_the_armed_monitor(self):
        for cause in ['reactive','preemptive']:
            with self.subTest(cause=cause):
                self.seed(cause);before=self.state.read_bytes()
                self.assertEqual(self.run_block(cause,unset_home=True),'WAKE_PUBLISH=failed')
                self.assertEqual(self.stopped(),['own-task'])
                self.assertEqual(self.state.read_bytes(),before)

    def test_missing_day_is_lost_and_absent_state_is_not_created(self):
        for cause in ['reactive','preemptive']:
            self.seed(cause);self.state.unlink()
            self.assertEqual(self.run_block(cause),'WAKE_PUBLISH=lost')
            self.assertFalse(self.state.exists());self.assertEqual(self.stopped(),['own-task'])

    def test_generated_park_requires_the_original_claim_binding(self):
        for cause in ['reactive','preemptive']:
            for supplied, wanted in [('park-original','armed'),('', 'lost'),('park-older','lost')]:
                with self.subTest(cause=cause, supplied=supplied):
                    self.seed(cause);self.set_day(park_generation='park-original');before=self.data()
                    self.assertEqual(self.run_block(cause,park_generation=supplied),'WAKE_PUBLISH='+wanted)
                    self.assertEqual(self.day()['park_generation'],'park-original')
                    if wanted=='lost':
                        self.assertEqual(self.data(),before);self.assertEqual(self.stopped(),['own-task'])

    def test_generation_replaced_before_read_is_never_adopted(self):
        for cause in ['reactive','preemptive']:
            self.seed(cause);self.set_day(park_generation='park-replacement');before=self.data()
            self.assertEqual(self.run_block(cause,park_generation='park-original'),'WAKE_PUBLISH=lost')
            self.assertEqual(self.data(),before);self.assertEqual(self.stopped(),['own-task'])
            self.assertFalse(any('--cas' in json.loads(x) for x in self.calls.read_text().splitlines()))

    def test_same_metadata_generation_change_after_snapshot_is_lost(self):
        for cause in ['reactive','preemptive']:
            self.seed(cause);self.set_day(park_generation='park-original')
            self.assertEqual(self.run_block(cause,park_generation='park-original',mode='replace-generation'),'WAKE_PUBLISH=lost')
            self.assertEqual(self.day()['park_generation'],'park-replacement')
            self.assertIsNone(self.day()['limit_resume_task_id']);self.assertEqual(self.stopped(),['own-task'])

    def test_invalid_durable_generation_fails_closed(self):
        for cause in ['reactive','preemptive']:
            for value in [False,0,'','null',{},[]]:
                with self.subTest(cause=cause,value=value):
                    self.seed(cause);self.set_day(park_generation=value);before=self.data()
                    self.assertEqual(self.run_block(cause),'WAKE_PUBLISH=failed')
                    self.assertEqual(self.data(),before);self.assertEqual(self.stopped(),['own-task'])

    def test_real_claim_completion_and_publication_keep_one_generation(self):
        for cause in ['reactive','preemptive']:
            self.seed(cause);self.set_day(parked_until=None,limit_cause=None,limit_probe_fires_remaining=None)
            def fence(anchor):
                match=re.search(r'<!-- test-anchor: '+re.escape(anchor)+r' -->\s*```bash\n(.*?)\n```',park_text(cause),re.S)
                self.assertIsNotNone(match,anchor);return match.group(1)
            code=fence('pm-day-2d6-park-claim' if cause=='reactive' else 'pm-day-2d7-park-claim')
            if cause=='preemptive':code+='\n'+fence('pm-day-2d7-park-record')
            code+='\n'+self.blocks[cause]
            env=dict(self.env,SESSION_STATE_SH=str(self.proxy),REPO_KEY=REPO,NEW_HITS='1',
                     PARKED_UNTIL='2026-12-01T23:00:00Z',LIMIT_KIND='rolling_window',
                     HORIZON_RESET_EPOCH=str(int(time.time())+3600),PROBE_CADENCE_MIN='30',
                     PROBE_MAX_FIRES='12',PARK_RESET_KNOWN='true',WAKE_TASK_ID='own-task',
                     WAKE_GENERATION='own-generation',LIMIT_MONITOR_TASK_ID='own-task',
                     LIMIT_GENERATION='own-generation')
            p=subprocess.run([SHELL,'-c',code],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
            self.assertEqual(p.returncode,0,p.stderr);self.assertIn('WAKE_PUBLISH=armed',p.stdout)
            generation=re.search(r'^PARK_GENERATION=(parkgen-[0-9a-f]{32})$',p.stdout,re.M)
            self.assertIsNotNone(generation,p.stdout);self.assertEqual(self.day()['park_generation'],generation[1])
            self.assertIsNone(self.day()['park_claim_token']);self.assertEqual(self.day()['limit_resume_task_id'],'own-task')

unittest.main(argv=[sys.argv[0]]+sys.argv[2:])
PY
