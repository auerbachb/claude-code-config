#!/usr/bin/env python3
"""Private, bounded usage-read outcomes; stdout contains only reliability stats.

Usage: quotas-outcomes.py LEDGER RUN_JSONL NOW_EPOCH
An empty LEDGER disables persistence. No response bodies or credentials are input.
"""
# catalog: token-measurement — Persist sanitized per-account quota read outcomes with bounded retention and compute display-only reliability
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time

STATUSES = {'ok', 'logged_out', 'unreadable', 'rate_limited', 'timeout', 'parse_error'}
RETENTION = 45 * 86400
MAX_ROWS = 50000


def validate(row):
    """Return a sanitized outcome and timestamp, or None for invalid input."""
    if not isinstance(row, dict):
        return None
    if row.get('status') not in STATUSES:
        return None
    for key in ('provider', 'label', 'source', 'ts'):
        if not isinstance(row.get(key), str):
            return None
    if row['provider'] not in ('claude', 'codex', 'cursor'):
        return None
    if not re.fullmatch(r'[a-z][a-z0-9_-]{0,39}', row['source']):
        return None
    try:
        timestamp = dt.datetime.strptime(row['ts'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc).timestamp()
    except ValueError:
        return None
    error = row.get('error_class')
    if row['status'] == 'ok':
        error = None
    elif not isinstance(error, str) or not re.fullmatch(r'[a-z0-9_]{1,40}', error):
        error = 'other'
    # Explicit field selection: never carry arbitrary input fields into the ledger.
    clean = {key: row[key] for key in ('ts', 'provider', 'label', 'source', 'status')}
    clean.update(error_class=error, trigger='scheduled' if row.get('trigger') == 'scheduled' else 'manual')
    if isinstance(row.get('requested_source'), str) and re.fullmatch(r'[a-z][a-z0-9_-]{0,39}', row['requested_source']):
        clean['requested_source'] = row['requested_source']
    if row.get('terminal') is False:
        clean['terminal'] = False
    if row.get('skip_reason') == 'browser-unattended':
        clean.update(skip_reason='browser-unattended', terminal=False)
    return clean, timestamp


def read_rows(path, now, strict=False):
    """Read retained valid rows, propagating I/O failures when strict is enabled."""
    if not path:
        return []
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd, encoding='utf-8', errors='replace') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                return []
            result = []
            for line in stream:
                try:
                    valid = validate(json.loads(line))
                except (ValueError, TypeError, RecursionError):
                    continue
                if valid and now - RETENTION <= valid[1]:
                    result.append(valid)
            return result[-MAX_ROWS:]
    except FileNotFoundError:
        return []
    except OSError:
        if strict:
            raise
        return []


def reliability(rows, current, now):
    """Calculate account failure windows and chronological consecutive-failure streaks."""
    result = []
    accounts = sorted({(row['provider'], row['label']) for row, _ in current})
    for provider, label in accounts:
        # A slower run can finish after one that started later. Preserve those
        # later-start records on disk, but anchor this report to its own clock.
        attempts = sorted((item for item in rows if item[0].get('terminal', True) and item[1] <= now and
                           (item[0]['provider'], item[0]['label']) == (provider, label)),
                          key=lambda item: item[1])
        item = {'provider': provider, 'label': label}
        for days in (7, 30):
            window = [row for row, timestamp in attempts if timestamp >= now - days * 86400]
            failures = sum(row['status'] != 'ok' for row in window)
            item.update({f'attempts_{days}d': len(window), f'failures_{days}d': failures,
                         f'failure_rate_{days}d': failures / len(window) if window else None})
        streak = []
        for row, _ in reversed(attempts):
            if row['status'] == 'ok':
                break
            streak.append(row)
        item.update(streak_count=len(streak), streak_status=streak[0]['status'] if streak else None,
                    streak_since=streak[-1]['ts'] if streak else None)
        sources = []
        source_names = sorted({r.get('requested_source', r['source']) for r, _ in rows if
                               (r['provider'], r['label']) == (provider, label)})
        for source in source_names:
            history = sorted((entry for entry in rows if entry[1] <= now and
                              (entry[0]['provider'], entry[0]['label'], entry[0].get('requested_source', entry[0]['source'])) ==
                              (provider, label, source) and not entry[0].get('skip_reason')),
                             key=lambda entry: entry[1])
            failures = 0
            for record, _ in reversed(history):
                if record['status'] == 'ok':
                    break
                failures += 1
            sources.append(dict(source=source, consecutive_failures=failures,
                                last_status=history[-1][0]['status'] if history else None))
        item['sources'] = sources
        result.append(item)
    return result


def process(ledger, run, now):
    """Persist current outcomes safely and return reliability including this run."""
    current = read_rows(run, now)
    prior = read_rows(ledger, now)
    all_rows = prior + current
    if ledger and current:
        lock_fd = None
        tmp = None
        try:
            path = Path(ledger)
            path.parent.mkdir(parents=True, exist_ok=True)
            # The stable advisory lock file is never unlinked: removing a locked
            # inode would allow two writers to acquire different locks.
            lock_fd = os.open(ledger + '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
                raise OSError('nonregular lock')
            os.fchmod(lock_fd, 0o600)
            deadline = time.monotonic() + 2
            while True:
                try:
                    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise OSError('lock timeout') from None
                    time.sleep(0.05)
            if path.is_symlink() or (path.exists() and not path.is_file()):
                raise OSError('unsafe ledger destination')
            # Re-read under lock to preserve concurrent writes; stats include the
            # current run once even when a write fails.
            all_rows = read_rows(ledger, now, strict=True) + current
            fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
            with os.fdopen(fd, 'w') as stream:
                os.fchmod(stream.fileno(), 0o600)
                for row, _ in all_rows[-MAX_ROWS:]:
                    stream.write(json.dumps(row, separators=(',', ':')) + '\n')
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(tmp, ledger)
            tmp = None
        except OSError:
            # Fixed diagnostic only: OS exceptions can contain private paths.
            print('ai-quotas: could not persist read outcomes; report is unaffected', file=sys.stderr)
        finally:
            if tmp:
                os.unlink(tmp)
            if lock_fd is not None:
                os.close(lock_fd)
    return reliability(all_rows, current, now)


if __name__ == '__main__':
    print(json.dumps(process(sys.argv[1], sys.argv[2], int(sys.argv[3]))))
