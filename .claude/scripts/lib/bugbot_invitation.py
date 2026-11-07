"""Read-only, bounded current-HEAD BugBot invitation classification.

Server anchors: https://docs.github.com/en/rest/using-the-rest-api/github-event-types
and https://docs.github.com/en/rest/using-the-rest-api/issue-event-types .
No workflow timestamp or commit date is substituted for a push boundary.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile


class Unknown(Exception):
    pass


def stamp(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z', value):
        raise Unknown('timestamp_invalid')
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(timezone.utc)
    except ValueError as exc:
        raise Unknown('timestamp_invalid') from exc


def command(args):
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=out,
                                    stderr=err, start_new_session=True)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=1)
                raise Unknown('read_timeout')
            except BaseException:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=1)
                except (OSError, subprocess.SubprocessError):
                    pass
                raise
            if out.tell() > 2 * 1024 * 1024:
                raise Unknown('read_output_limit')
            out.seek(0)
            return proc.returncode, out.read().decode('utf-8')
        except (OSError, UnicodeError, subprocess.SubprocessError) as exc:
            raise Unknown('read_unavailable') from exc


def api(endpoint):
    rc, raw = command(['gh', 'api', endpoint])
    if rc:
        raise Unknown('github_read_failed')
    try:
        return json.loads(raw)
    except ValueError as exc:
        raise Unknown('github_json_invalid') from exc


def pages(endpoint, stop=None):
    rows = []
    for page in range(1, 4):
        part = api(endpoint + '?per_page=100&page=' + str(page))
        if not isinstance(part, list) or len(part) > 100 or any(not isinstance(row, dict) for row in part):
            raise Unknown('github_page_invalid')
        rows.extend(part)
        if (stop is not None and any(stop(row) for row in part)) or len(part) < 100:
            return rows
    raise Unknown('github_page_limit')


def head(args):
    pr = api('repos/' + args.repo + '/pulls/' + str(args.pr))
    if not isinstance(pr, dict):
        raise Unknown('pr_shape_invalid')
    try:
        value, ref, repository = pr['head']['sha'], pr['head']['ref'], pr['head']['repo']['full_name']
        created = stamp(pr['created_at'])
    except (KeyError, TypeError) as exc:
        raise Unknown('pr_shape_invalid') from exc
    if value != args.head or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', value):
        raise Unknown('head_changed')
    if not isinstance(ref, str) or not ref or not isinstance(repository, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise Unknown('head_repository_invalid')
    return value, ref, repository, created


def boundary(args, pr, evidence):
    if args.pushed_sha is not None or args.pushed_at is not None:
        if args.pushed_sha != pr[0] or not args.pushed_at:
            raise Unknown('captured_push_mismatch')
        since = stamp(args.pushed_at)
        evidence['boundary_source'] = 'captured_before_this_push'
        return max(since, pr[3])
    # API repository events may lag/expire. Missing or incomplete history is
    # unknown, never a reason to recycle a commit date or the rerun's clock.
    evidence['read_stage'] = 'repository_push_history'
    events = pages('repos/' + pr[2] + '/events', stop=lambda row: row.get('type') == 'PushEvent' and isinstance(row.get('payload'), dict) and row['payload'].get('ref') == 'refs/heads/' + pr[1])
    pushes = []
    for row in events:
        if row.get('type') != 'PushEvent':
            continue
        payload = row.get('payload')
        if not isinstance(payload, dict):
            raise Unknown('push_event_invalid')
        if payload.get('ref') == 'refs/heads/' + pr[1]:
            pushes.append((stamp(row.get('created_at')), payload.get('head')))
    # A force-push can revisit an old SHA. The PR history must not show a
    # newer, unbound head movement than the repository event we selected.
    evidence['read_stage'] = 'pr_head_movements'
    timeline = pages('repos/' + args.repo + '/issues/' + str(args.pr) + '/timeline')
    movements = []
    for row in timeline:
        if row.get('event') == 'head_ref_force_pushed':
            movements.append((stamp(row.get('created_at')), row.get('commit_id')))
        elif row.get('event') in ('head_ref_deleted', 'head_ref_restored'):
            movements.append((stamp(row.get('created_at')), None))
    candidates = pushes + movements
    if not candidates:
        raise Unknown('head_push_boundary_unavailable')
    newest = max(t for t, _ in candidates)
    newest_heads = {sha for t, sha in candidates if t == newest}
    evidence['latest_movement_at'] = newest.isoformat()
    if newest_heads != {pr[0]}:
        raise Unknown('head_push_boundary_mismatch')
    evidence['boundary_source'] = 'github_sha_bound_push_history'
    return max(newest, pr[3])


def classify(args, evidence):
    evidence["read_stage"] = "initial_pr_head"
    pr = head(args)
    evidence["read_stage"] = "comments"
    comments = pages('repos/' + args.repo + '/issues/' + str(args.pr) + '/comments')
    invitations = []
    for row in comments:
        body = row.get('body')
        if not isinstance(body, str):
            raise Unknown('comment_shape_invalid')
        created = stamp(row.get('created_at'))
        if re.search(r'^\s*@cursor\s+review\b', body):
            invitations.append(created)
    evidence['comment_count'] = len(comments)
    evidence['invitation_times'] = [time.isoformat() for time in invitations]
    since = None
    boundary_error = None
    # With no invitation anywhere, there is nothing to scope. An owner grant
    # still needs an exact-HEAD read below; history absence cannot invent one.
    if invitations:
        try:
            since = boundary(args, pr, evidence)
        except Unknown as exc:
            boundary_error = str(exc)
    invited = since is not None and any(time >= since for time in invitations)
    if since is not None:
        evidence['boundary'] = since.isoformat()
    if invited:
        awaited, reason, certainty = True, 'current_head_invited', 'known'
    else:
        if not args.grant_helper or not os.access(args.grant_helper, os.X_OK):
            raise Unknown('grant_reader_unavailable')
        evidence["read_stage"] = "owner_grant_check"
        rc, grant_output = command([args.grant_helper, '--check', str(args.pr), '--vendor', 'cursor',
                         '--head', pr[0], '--repo', args.repo])
        evidence['grant_check_exit'] = rc
        match = re.fullmatch(r'STATUS=([a-z_]+)\n?', grant_output)
        status = match.group(1) if match else None
        evidence['grant_status'] = status
        absent = {'no_grant', 'grant_head_mismatch', 'grant_session_mismatch',
                  'grant_used', 'grant_vendor_mismatch', 'session_unknown'}
        if rc == 0 and status == 'available':
            awaited, reason, certainty = True, 'unused_current_head_grant', 'known'
        elif rc != 1 or status not in absent:
            raise Unknown('grant_read_failed')
        elif boundary_error:
            raise Unknown(boundary_error)
        else:
            awaited, reason, certainty = False, 'not_invited_no_unused_grant', 'known'
    evidence["read_stage"] = "final_pr_head"
    if head(args) != pr:
        raise Unknown('head_context_changed')
    return dict(awaited=awaited, reason=reason, certainty=certainty)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--pr', type=int, required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--pushed-sha')
    parser.add_argument('--pushed-at')
    parser.add_argument('--grant-helper', default='')
    args = parser.parse_args()
    evidence = {'head_sha': args.head, 'repo': args.repo, 'pr': args.pr}
    result = dict(awaited=True, certainty='unknown', reason='input_invalid')
    try:
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo) or args.pr <= 0:
            raise Unknown('input_invalid')
        if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', args.head):
            raise Unknown('head_invalid')
        result = classify(args, evidence)
    except (Unknown, OSError, ValueError, TypeError, KeyError) as exc:
        result = dict(awaited=True, certainty='unknown', reason=str(exc) if isinstance(exc, Unknown) else 'read_invalid')
    evidence.update(result)
    directory = tempfile.mkdtemp(prefix='bugbot-invitation-')
    target = Path(directory) / 'evidence.json'
    with os.fdopen(os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
        json.dump(evidence, stream)
    result.update(head_sha=args.head, boundary=evidence.get('boundary'), evidence_path=str(target))
    print(json.dumps(result))


def interrupted(_signal, _frame):
    raise KeyboardInterrupt()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130)
