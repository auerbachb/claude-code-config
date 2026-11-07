"""Bounded, read-only child observations for the existing ceiling tick.

Only the observer's private cache is written. Registry entries and runtime
tasks are never stopped, updated, or declared complete by this check.
"""
from datetime import datetime
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time


class Unknown(Exception):
    pass


def verify_private_file(descriptor):
    info = os.fstat(descriptor)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        raise Unknown('private_state_file_unsafe')


def private_read(path, limit):
    descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        verify_private_file(stream.fileno())
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise Unknown('inventory_or_cache_limit')
    return raw


def private_write(path, raw):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(raw)
    try:
        os.replace(temporary, path)  # replace an entry, never truncate its target
    finally:
        temporary.unlink(missing_ok=True)


def private_workspace(prefix, create=True):
    directory = Path(prefix + '.d')
    try:
        if create:
            directory.mkdir(mode=0o700)
    except FileExistsError:
        pass
    try:
        descriptor = os.open(str(directory), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        if not create:
            return None
        raise
    try:
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise Unknown('private_state_directory_unsafe')
    finally:
        os.close(descriptor)
    return directory


@contextmanager
def private_lock(path):
    descriptor = os.open(str(path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(descriptor, 'r+') as stream:
        verify_private_file(stream.fileno())
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def read_json(path, limit, private=False):
    if private:
        raw = private_read(path, limit)
    else:
        with open(path, 'rb') as stream:
            raw = stream.read(limit + 1)
        if len(raw) > limit:
            raise Unknown('inventory_or_cache_limit')
    return json.loads(raw)


def fingerprint_hash(parts):
    return hashlib.sha256(json.dumps(parts, ensure_ascii=False).encode()).hexdigest()


def timestamp(value):
    if not isinstance(value, str) or not value.endswith('Z'):
        raise Unknown('task_timestamp_invalid')
    return datetime.fromisoformat(value[:-1] + '+00:00').timestamp()


def observe(session, cache_path):
    now = time.time()
    source = os.environ.get('CLAUDE_SESSION_STATE_FILE', str(Path.home()/'.claude/session-state.json'))
    inventory = read_json(source, 8 * 1024 * 1024)
    repos = inventory.get('repos')
    if not isinstance(repos, dict):
        raise Unknown('inventory_shape_invalid')
    try:
        cache = read_json(cache_path, 1024 * 1024, private=True)
    except FileNotFoundError:
        cache = {}
    if not isinstance(cache, dict) or cache.get('session', session) != session:
        raise Unknown('cache_shape_invalid')
    previous = cache.get('tasks', {})
    if not isinstance(previous, dict):
        raise Unknown('cache_shape_invalid')
    try:
        threshold = float(os.environ.get('BGWORK_CHILD_STALL_S', '900'))
        if not math.isfinite(threshold) or not 0 < threshold <= 86400:
            raise ValueError()
    except ValueError:
        raise Unknown('stall_bound_invalid')
    current, notices = {}, []
    count = 0
    for repo, scoped in repos.items():
        if not isinstance(scoped, dict):
            raise Unknown('inventory_scope_invalid')
        rows = scoped.get('background_tasks', [])
        if not isinstance(rows, list):
            raise Unknown('inventory_rows_invalid')
        for row in rows:
            if not isinstance(row, dict):
                raise Unknown('inventory_row_invalid')
            if row.get('session_id') != session:
                continue
            if row.get('type') not in ('agent', 'bash', 'monitor', 'workflow'):
                raise Unknown('task_type_unknown')
            if row['type'] != 'agent':
                continue
            if (not isinstance(repo, str) or (repo != '_unknown' and not
                    re.fullmatch(r'[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}', repo))):
                raise Unknown('inventory_scope_invalid')
            status = row.get('status')
            if status in ('done', 'failed', 'stopped', 'rearming', 'rearmed', 'abandoned'):
                continue
            count += 1
            if count > 200:
                raise Unknown('child_inventory_limit')
            task = row.get('task_id')
            if not isinstance(task, str) or not task or len(task) > 256:
                raise Unknown('runtime_identity_invalid')
            generation = row.get('started_at')
            identity = json.dumps([repo, session, task, generation], sort_keys=True)
            key = hashlib.sha256(identity.encode()).hexdigest()
            old = previous.get(key, {})
            if not isinstance(old, dict):
                raise Unknown('cache_row_invalid')
            condition, fingerprint = '', []
            try:
                started = timestamp(generation)
                if started > now or repo == '_unknown' or row.get('repo_key') != repo:
                    raise Unknown('task_scope_or_clock_unknown')
                if status not in ('running', 'stopping', 'stop_failed'):
                    raise Unknown('task_status_unknown')
                paths = [row.get(name) for name in ('output_file', 'checkpoint_path') if row.get(name)]
                if not paths:
                    raise Unknown('child_artifact_missing')
                for path in paths:
                    if not isinstance(path, str) or not os.path.isabs(path):
                        raise Unknown('child_artifact_path_invalid')
                    info = os.stat(path)
                    if not stat.S_ISREG(info.st_mode) or info.st_mtime > now:
                        raise Unknown('child_artifact_type_or_clock_unknown')
                    # A successful open verifies readability without loading
                    # raw model output or mistaking an unreadable path for idle.
                    with open(path, 'rb') as stream:
                        stream.read(1)
                    fingerprint.append([path, info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns])
                fingerprint = fingerprint_hash(fingerprint)
                last = old.get('last_activity_at', now) if old.get('fingerprint') == fingerprint else now
                if type(last) not in (int, float) or not math.isfinite(last) or last > now:
                    raise Unknown('observation_clock_unknown')
                if now - last >= threshold:
                    condition = 'suspect'
            except (Unknown, OSError, ValueError, TypeError) as exc:
                condition = str(exc) if isinstance(exc, Unknown) else 'child_artifact_unreadable'
                last = now
            if not isinstance(fingerprint, str):
                fingerprint = fingerprint_hash(fingerprint)
            notice = [condition, fingerprint] if condition else None
            current[key] = dict(repo=repo, task_id=task, fingerprint=fingerprint,
                                last_activity_at=last, observed_at=now, notice=notice)
            if notice and notice != old.get('notice'):
                label = 'CHILD STALL SUSPECT' if condition == 'suspect' else 'CHILD PROGRESS UNKNOWN'
                detail = ('no changed child artifact for %ds' % (now-last)) if condition == 'suspect' else condition
                notices.append(label + ': repo=' + json.dumps(repo) + ' runtime=' + json.dumps(task)
                               + ' ' + detail + '. Investigate child evidence; parent heartbeats do not prove progress. Do not stop or respawn from this notice.')
    # Exact runtime/generation keys disappear when terminal or absent; a later
    # runtime never inherits an earlier task's inactivity or notification.
    raw_cache = json.dumps(dict(session=session, tasks=current, observed_at=now)).encode()
    if len(raw_cache) > 1024 * 1024:
        raise Unknown('cache_publish_limit')
    private_write(cache_path, raw_cache)
    for line in notices:
        print(line)


def main(session, prefix, clear=False):
    failure = None
    # A separate observer bounds local file/registry reads too, including an
    # unexpectedly hanging filesystem. Only this probe group can be killed.
    try:
        if not session or len(session) > 256:
            raise Unknown('session_identity_invalid')
        directory = private_workspace(prefix, create=not clear)
        if directory is None:
            return
        cache, failure = directory/'cache.json', directory/'unknown'
        with private_lock(directory/'lock'):
            if clear:
                for name in ('cache.json', 'unknown', 'diagnostic'):
                    (directory/name).unlink(missing_ok=True)
                return
            with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
                proc = subprocess.Popen([sys.executable, __file__, '--observe', session, str(cache)],
                                        stdout=output, stderr=errors, start_new_session=True)
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=1)
                    raise Unknown('progress_probe_timeout')
                except BaseException:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait(timeout=1)
                    except (OSError, subprocess.SubprocessError):
                        pass
                    raise
                if proc.returncode:
                    errors.seek(0)
                    detail = errors.read(4096)
                    private_write(directory/'diagnostic', detail)
                    raise Unknown('progress_probe_failed')
                if output.tell() > 256 * 1024:
                    raise Unknown('progress_output_limit')
                output.seek(0)
                sys.stdout.buffer.write(output.read())
                failure.unlink(missing_ok=True)
    except (Unknown, OSError, subprocess.SubprocessError) as exc:
        reason = str(exc) if isinstance(exc, Unknown) else 'progress_probe_unavailable'
        # Persist the error class, not exception paths or provider output.
        try:
            if failure is None:
                raise Unknown('private_state_unavailable')
            try:
                prior = private_read(failure, 4096).decode()
            except FileNotFoundError:
                prior = None
            if prior == reason:
                return
            private_write(failure, reason.encode())
        except (Unknown, OSError, UnicodeError):
            print('bgwork-ceiling: cannot persist child-progress dedup; notice may repeat', file=sys.stderr)
        print('CHILD PROGRESS UNKNOWN: ' + reason + '. Investigate registry/artifact reads; do not treat parent heartbeat as child health or stop/respawn a child.')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(2)
    if sys.argv[1] == '--observe':
        try:
            observe(sys.argv[2], Path(sys.argv[3]))
        except (Unknown, OSError, ValueError, TypeError) as exc:
            print(str(exc) if isinstance(exc, Unknown) else 'progress_observation_invalid', file=sys.stderr)
            sys.exit(1)
    elif sys.argv[1] in ('--tick', '--clear'):
        def interrupted(_signal, _frame):
            raise KeyboardInterrupt()
        signal.signal(signal.SIGTERM, interrupted)
        try:
            main(sys.argv[2], sys.argv[3], clear=sys.argv[1] == '--clear')
        except KeyboardInterrupt:
            sys.exit(130)
    else:
        sys.exit(2)
