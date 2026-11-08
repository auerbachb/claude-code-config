#!/usr/bin/env python3
"""Assess and reconcile one explicitly verified, merged PR's issue completion."""
import argparse
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

REPO = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*\Z')
SHA = re.compile(r'[0-9a-f]{40}\Z')
QUERY = '''query($owner:String!,$name:String!,$number:Int!){
 viewer{login} repository(owner:$owner,name:$name){nameWithOwner defaultBranchRef{name}
 pullRequest(number:$number){number state mergedAt headRefOid baseRefName url author{login}
 mergeCommit{oid} closingIssuesReferences(first:100){pageInfo{hasNextPage}
 nodes{__typename number state closedAt url repository{nameWithOwner}}}}}}'''
ISSUE_QUERY = '''query($owner:String!,$name:String!,$number:Int!){
 repository(owner:$owner,name:$name){nameWithOwner issueOrPullRequest(number:$number){
 __typename ... on Issue{number state closedAt updatedAt url repository{nameWithOwner}
 timelineItems(last:1,itemTypes:[REOPENED_EVENT]){nodes{... on ReopenedEvent{createdAt}}}}}}}'''


class CompletionError(Exception):
    """A fixed, recoverable failure with no fabricated successful completion."""
    def __init__(self, reason, code=4):
        super().__init__(reason)
        self.code = code


def gh(args):
    """Keep diagnostics private and never turn an API error into absent work."""
    try:
        proc = subprocess.run(['gh', 'api', '--hostname', 'github.com'] + args[1:], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CompletionError('github_unavailable') from exc
    if proc.returncode:
        raise CompletionError('github_request_failed')
    if len(proc.stdout) > 1024 * 1024:
        raise CompletionError('github_response_limit')
    try:
        value = json.loads(proc.stdout)
    except (TypeError, ValueError) as exc:
        raise CompletionError('github_response_invalid') from exc
    if not isinstance(value, dict) or value.get('errors'):
        raise CompletionError('github_response_invalid')
    return value


def graphql(query, repo, number):
    owner, name = repo.split('/')
    return gh(['api', 'graphql', '-f', 'query=' + query, '-f', 'owner=' + owner,
               '-f', 'name=' + name, '-F', 'number=' + str(number)])['data']


def private_directory(path):
    """Reject aliases and unsafe existing state, including ancestor components."""
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            pass
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise CompletionError('unsafe_completion_directory', 6)
        if current == path and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise CompletionError('unsafe_completion_directory', 6)


def save(path, report):
    """Atomic bounded receipts contain public identities and fixed status only."""
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix='.completion-', dir=path.parent)
        with os.fdopen(fd, 'w') as stream:
            json.dump(report, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary and os.path.lexists(temporary):
            os.unlink(temporary)


@contextlib.contextmanager
def locked(path):
    fd = os.open(str(path) + '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, 'a') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
            raise CompletionError('unsafe_completion_lock', 6)
        deadline = time.monotonic() + 4
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise CompletionError('completion_lock_busy', 6)
                time.sleep(.02)
        yield


def issue(repo, number):
    data = graphql(ISSUE_QUERY, repo, number)['repository']
    node = data['issueOrPullRequest']
    if (data['nameWithOwner'].lower() != repo.lower() or not isinstance(node, dict)
            or node.get('__typename') != 'Issue' or node.get('number') != number
            or node.get('repository', {}).get('nameWithOwner', '').lower() != repo.lower()
            or node.get('state') not in ('OPEN', 'CLOSED')
            or not isinstance(node.get('updatedAt'), str) or not node['updatedAt']):
        raise CompletionError('issue_identity_unverified', 3)
    return node


def reopened_after_merge(node, merged_at):
    events = node.get('timelineItems', {}).get('nodes')
    if not isinstance(events, list):
        raise CompletionError('reopen_history_unverified', 3)
    try:
        merged = datetime.datetime.fromisoformat(merged_at.replace('Z', '+00:00'))
        return any(datetime.datetime.fromisoformat(event['createdAt'].replace('Z', '+00:00')) >= merged for event in events)
    except (ValueError, TypeError, KeyError):
        raise CompletionError('reopen_history_unverified', 3)


def check_race_hold(args, report):
    """Every disposition honors the PR-scoped guard, including read-only audits."""
    try:
        fd = os.open(args.race_hold, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o077 or info.st_size > 65536):
            raise CompletionError('unsafe_completion_hold', 6)
        try:
            raw = stream.read(65537)
            if len(raw) > 65536:
                raise CompletionError('unsafe_completion_hold', 6)
            hold = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            raise CompletionError('unsafe_completion_hold', 6)
    expected = dict(owner_repo=args.repo, pr=args.pr, merge_sha=report['merge_sha'], head_sha=report['head_sha'])
    if (not isinstance(hold, dict) or set(hold) != set(expected) | {'issue', 'phase'}
            or type(hold.get('pr')) is not int or any(hold.get(k) != v for k, v in expected.items())
            or type(hold.get('issue')) is not int or hold['issue'] <= 0
            or hold.get('phase') not in ('closure_inflight', 'reopen_detected')):
        raise CompletionError('unsafe_completion_hold', 6)
    report['reopen_race_hold'] = hold
    if hold['phase'] == 'reopen_detected':
        raise CompletionError('concurrent_reopen_detected', 1)
    current = issue(args.repo, hold['issue'])
    if reopened_after_merge(current, report['merged_at']):
        hold['phase'] = 'reopen_detected'
        save(args.race_hold, hold)
        raise CompletionError('concurrent_reopen_detected', 1)
    if current['state'] == 'CLOSED':
        args.race_hold.unlink()
        report.pop('reopen_race_hold', None)
    elif args.complete_issue != hold['issue']:
        raise CompletionError('closure_visibility_pending', 1)


def assess(args, report):
    data = graphql(QUERY, args.repo, args.pr)
    repository = data['repository']
    pr = repository['pullRequest']
    if (repository['nameWithOwner'].lower() != args.repo.lower() or not isinstance(pr, dict)
            or pr.get('number') != args.pr or pr.get('state') != 'MERGED'
            or not pr.get('mergedAt') or not SHA.fullmatch((pr.get('mergeCommit') or {}).get('oid', ''))):
        raise CompletionError('merged_pr_unverified', 3)
    report.update(merge_sha=pr['mergeCommit']['oid'], head_sha=pr['headRefOid'], merged_at=pr['mergedAt'])
    if pr.get('baseRefName') != (repository.get('defaultBranchRef') or {}).get('name'):
        raise CompletionError('non_default_merge_target', 3)
    check_race_hold(args, report)
    links = pr['closingIssuesReferences']
    if links['pageInfo']['hasNextPage']:
        raise CompletionError('closing_reference_limit', 3)
    candidates = []
    for linked in links['nodes']:
        owner_repo = linked.get('repository', {}).get('nameWithOwner', '')
        if (linked.get('__typename') != 'Issue' or type(linked.get('number')) is not int
                or not REPO.fullmatch(owner_repo) or linked.get('state') not in ('OPEN', 'CLOSED')):
            raise CompletionError('closing_reference_invalid', 3)
        candidates.append(dict(owner_repo=owner_repo, issue=linked['number'],
                               state=linked['state'], disposition='foreign_retained' if owner_repo.lower() != args.repo.lower()
                               else 'closed' if linked['state'] == 'CLOSED' else 'scope_verification_required'))
    report['issues'] = candidates
    if args.retain_issue:
        if (args.complete_issue is not None or args.no_issue_verified
                or args.expected_merge != report['merge_sha']
                or (pr.get('author') or {}).get('login', '').lower() != data['viewer']['login'].lower()):
            raise CompletionError('retained_scope_unverified', 3)
        retained = {}
        for assertion in args.retain_issue:
            match = re.fullmatch(r'([1-9][0-9]*)=(partial_scope|owner_decision|reopened)', assertion)
            if not match or match[1] in retained:
                raise CompletionError('retained_scope_unverified', 3)
            number = int(match[1])
            target = next((x for x in candidates if x['owner_repo'].lower() == args.repo.lower() and x['issue'] == number), None)
            if target is None:
                if not args.association_verified:
                    raise CompletionError('issue_association_unverified', 3)
                target = dict(owner_repo=args.repo, issue=number)
                candidates.append(target)
            current = issue(args.repo, number)
            target.update(state=current['state'], disposition='closed' if current['state'] == 'CLOSED' else 'retained')
            retained[str(number)] = dict(owner_repo=args.repo, issue=number, reason=match[2])
        report['retained_scope'] = retained
        report['outcome'] = 'retained' if all(x['disposition'] in ('closed', 'retained') for x in candidates) else 'pending'
        return 0 if report['outcome'] == 'retained' else 1
    if args.no_issue_verified:
        if candidates or args.complete_issue is not None or args.association_verified or args.expected_merge != report["merge_sha"]:
            raise CompletionError("no_issue_scope_unverified", 3)
        report.update(outcome="verified", no_associated_issues=True)
        return 0
    if args.complete_issue is None:
        report['outcome'] = 'pending' if not candidates or any(x['disposition'] != 'closed' for x in candidates) else 'verified'
        return 1 if report['outcome'] == 'pending' else 0
    if not args.scope_verified or not args.expected_merge or args.expected_merge != report['merge_sha']:
        raise CompletionError('scope_or_merge_verification_required', 3)
    if (pr.get('author') or {}).get('login', '').lower() != data['viewer']['login'].lower():
        raise CompletionError('pr_authorship_unverified', 3)
    target = next((x for x in candidates if x['owner_repo'].lower() == args.repo.lower() and x['issue'] == args.complete_issue), None)
    if target is None:
        # A task issue omitted from PR trailers must be bound explicitly after
        # full-scope/source verification; never infer from titles or prose.
        if not args.association_verified:
            raise CompletionError('issue_association_unverified', 3)
        target = dict(owner_repo=args.repo, issue=args.complete_issue, disposition='scope_verification_required')
        candidates.append(target)
    current = issue(args.repo, args.complete_issue)
    reopened = reopened_after_merge(current, pr['mergedAt'])
    if current['state'] == 'OPEN' and reopened:
        raise CompletionError('issue_reopened_after_merge', 3)
    target['state'] = current['state']
    if current['state'] == 'CLOSED':
        target['disposition'] = 'closed'
        report['outcome'] = 'verified' if all(x['disposition'] == 'closed' for x in candidates) else 'pending'
        return 0 if report['outcome'] == 'verified' else 1
    # Durable intent precedes the write; an interrupted request is retryable.
    target['disposition'] = 'closure_pending'
    report['outcome'] = 'pending'
    save(args.receipt, report)
    # GitHub offers no conditional issue-state write. Recheck immediately
    # before the request, and never call a changed preflight verified.
    preflight = issue(args.repo, args.complete_issue)
    if preflight['state'] == 'CLOSED':
        target.update(state='CLOSED', disposition='closed')
        report['outcome'] = 'verified' if all(x['disposition'] == 'closed' for x in candidates) else 'pending'
        return 0 if report['outcome'] == 'verified' else 1
    if preflight.get('updatedAt') != current.get('updatedAt') or preflight.get('timelineItems') != current.get('timelineItems'):
        raise CompletionError('issue_changed_before_close', 3)
    # Arm before the external write: process/disk failure after the write must
    # not erase the need to recheck reopen history on any later assessment.
    hold = dict(owner_repo=args.repo, pr=args.pr, merge_sha=report['merge_sha'],
                head_sha=report['head_sha'], issue=args.complete_issue, phase='closure_inflight')
    save(args.race_hold, hold)
    gh(['api', '--method', 'PATCH', 'repos/' + args.repo + '/issues/' + str(args.complete_issue),
        '-f', 'state=closed', '-f', 'state_reason=completed'])
    after = issue(args.repo, args.complete_issue)
    target['state'] = after['state']
    if after.get('timelineItems') != preflight.get('timelineItems'):
        hold['phase'] = 'reopen_detected'
        report['reopen_race_hold'] = hold
        save(args.race_hold, hold)
        raise CompletionError('concurrent_reopen_detected', 1)
    if after['state'] != 'CLOSED':
        raise CompletionError('closure_visibility_pending', 1)
    args.race_hold.unlink()
    target['disposition'] = 'closed'
    report['outcome'] = 'verified' if all(x['disposition'] == 'closed' for x in candidates) else 'pending'
    return 0 if report['outcome'] == 'verified' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--pr', required=True, type=int)
    parser.add_argument('--complete-issue', type=int)
    parser.add_argument('--expected-merge')
    parser.add_argument('--scope-verified', action='store_true')
    parser.add_argument('--association-verified', action='store_true')
    parser.add_argument('--no-issue-verified', action='store_true')
    parser.add_argument('--retain-issue', action='append', default=[], metavar='NUMBER=REASON')
    args = parser.parse_args()
    if (not REPO.fullmatch(args.repo) or args.pr <= 0 or args.repo.split('/')[1] in ('.', '..')
            or (args.complete_issue is not None and args.complete_issue <= 0)
            or (args.expected_merge and not SHA.fullmatch(args.expected_merge))):
        parser.error('invalid repository, issue, PR or merge identity')
    directory = Path.home().resolve() / '.claude' / 'issue-completion' / 'github.com' / args.repo
    suffix = '.issue-' + str(args.complete_issue) if args.complete_issue else '.assessment'
    args.receipt = directory / ('pr-' + str(args.pr) + suffix + '.json')
    args.race_hold = directory / ('pr-' + str(args.pr) + '.race-hold.json')
    report = dict(schema_version='1.0', owner_host='github.com', owner_repo=args.repo, pr=args.pr, outcome='pending',
                  recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), issues=[],
                  scope_verified=bool(args.scope_verified), association_verified=bool(args.association_verified),
                  expected_merge=args.expected_merge)
    code = 4
    try:
        private_directory(directory)
        # Serialize assessment/retention/close modes before their receipt locks.
        with locked(directory / ('pr-' + str(args.pr))), locked(args.receipt):
            try:
                code = assess(args, report)
            except CompletionError as exc:
                report['error_class'] = str(exc)
                code = exc.code
            except (KeyError, TypeError, AttributeError, ValueError):
                report['error_class'] = 'github_response_invalid'
                code = 4
            save(args.receipt, report)
    except (OSError, CompletionError) as exc:
        report.update(outcome='pending', error_class=str(exc) if isinstance(exc, CompletionError) else 'completion_receipt_failed')
        code = exc.code if isinstance(exc, CompletionError) else 6
    report['receipt_path'] = str(args.receipt)
    print(json.dumps(report, sort_keys=True))
    return code


if __name__ == '__main__':
    sys.exit(main())
