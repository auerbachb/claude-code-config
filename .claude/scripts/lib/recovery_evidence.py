"""Private raw recovery captures and typed verdicts; no gate authorization.

Raw files survive malformed JSON and child-shell exit. State writers retain
the returned handles; this helper never changes a merge/review gate or state.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile


LIMIT = 8 * 1024 * 1024


def capture_bytes(path):
    if not stat.S_ISREG(path.stat().st_mode):
        raise ValueError('capture_not_regular')
    with open(path, 'rb') as stream:
        raw = stream.read(LIMIT + 1)
    return raw


def text(path):
    raw = capture_bytes(path)
    if len(raw) > LIMIT:
        raise ValueError('capture_parse_limit')
    return raw.decode('utf-8')


def classify(kind, raw, code, fetch_code):
    try:
        value = json.loads(raw)
    except (ValueError, RecursionError):
        value = None
        shape = 'empty_output' if not raw.strip() else 'malformed_output'
    else:
        shape = 'valid'
        if not isinstance(value, dict):
            shape = 'invalid_shape'
        elif kind == 'gate':
            if (type(value.get('met')) is not bool or not isinstance(value.get('missing'), list)
                    or any(not isinstance(item, str) for item in value['missing'])
                    or not isinstance(value.get('head_sha'), str) or not value['head_sha']):
                shape = 'invalid_shape'
        elif (any(not isinstance(value.get(key), list) for key in ('bots_pending', 'ci_pending', 'ci_failing'))
              or type(value.get('new_findings')) is not int or value['new_findings'] < 0
              or type(value.get('head_moved')) is not bool):
            shape = 'invalid_shape'
    parsed = value if shape == 'valid' else None
    if code == -1 or (kind == 'wait' and fetch_code == -1):
        return parsed, 'execution_status_unknown', True
    if kind == 'gate' and code == 3:
        return parsed, 'not_open', False
    if code not in ((0, 1) if kind == 'gate' else (0,)) or (kind == 'wait' and fetch_code != 0):
        return parsed, 'execution_error', True
    if shape != 'valid':
        return None, shape, True
    if kind == 'gate':
        if ((code == 0) != value['met']) or (value['met'] and value['missing']):
            return parsed, 'exit_verdict_mismatch', True
        return parsed, 'valid_pass' if value['met'] else 'valid_blocked', not value['met']
    failed = bool(value['ci_failing'] or value['new_findings'] or value['head_moved'])
    pending = failed or bool(value['bots_pending'] or value['ci_pending'])
    return parsed, 'valid_pending' if pending else 'valid_clean', failed


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('new', 'check', 'record', 'show'))
    parser.add_argument('--repo', required=True)
    parser.add_argument('--pr', type=int, required=True)
    parser.add_argument('--kind', choices=('gate', 'wait'), required=True)
    parser.add_argument('--directory')
    parser.add_argument('--exit-code', type=int, default=-1)
    parser.add_argument('--fetch-exit-code', type=int, default=-1)
    parser.add_argument('--head', default='')
    parser.add_argument('--baseline', default='')
    parser.add_argument('--bundle', default='')
    parser.add_argument('--raw', choices=('stdout', 'stderr', 'bundle', 'audit', 'fetch.stdout', 'fetch.stderr'))
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo) or args.pr <= 0:
        raise ValueError('target_scope_invalid')
    if any(part in ('.', '..') for part in args.repo.split('/')):
        raise ValueError('target_scope_invalid')
    args.repo = args.repo.lower()
    base = Path.home()/'.claude/logs/recovery-evidence'/args.repo/('pr-'+str(args.pr))
    now = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    if args.mode == 'new':
        base.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory = Path(tempfile.mkdtemp(prefix=args.kind+'-', dir=base))
        (directory/'meta.json').write_text(json.dumps(dict(repo=args.repo, pr=args.pr, kind=args.kind, created_at=now)))
        for name in ('stdout', 'stderr', 'audit', 'fetch.stdout', 'fetch.stderr'):
            (directory/name).touch(mode=0o600)
        print(directory)
        return
    directory = Path(args.directory or '').resolve(strict=True)
    if directory.parent != base.resolve(strict=True) or not directory.name.startswith(args.kind+'-'):
        raise ValueError('capture_scope_mismatch')
    meta = json.loads(text(directory/'meta.json'))
    if any(meta.get(key) != getattr(args, key) for key in ('repo', 'pr', 'kind')):
        raise ValueError('capture_scope_mismatch')
    if args.mode == 'check':
        return
    if args.mode == 'show':
        if args.raw:
            # Explicit raw access is separate from the small default status.
            path = directory/args.raw
            if not stat.S_ISREG(path.stat().st_mode):
                raise ValueError('capture_not_regular')
            with open(path, 'rb') as stream:
                shutil.copyfileobj(stream, sys.stdout.buffer)
        else:
            record = json.loads(text(directory/'record.json'))
            print(json.dumps({key: record.get(key) for key in
                              ('classification', 'exit_code', 'fetch_exit_code', 'head_sha', 'observed_at',
                               'capture_dir', 'raw_stdout_path', 'raw_stderr_path', 'retained_bundle_path')}))
        return
    if not -1 <= args.exit_code <= 255 or not -1 <= args.fetch_exit_code <= 255:
        raise ValueError('execution_status_invalid')
    raw_bytes = capture_bytes(directory/'stdout')
    parse_error = 'output_parse_limit' if len(raw_bytes) > LIMIT else None
    try:
        raw = raw_bytes.decode('utf-8') if not parse_error else ''
    except UnicodeError:
        raw, parse_error = '', 'invalid_encoding'
    # Verify captures before issuing an index; parsing never consumes/removes
    # the raw files, including stderr from an execution that failed.
    if not stat.S_ISREG((directory/'stderr').stat().st_mode):
        raise ValueError('capture_not_regular')
    parsed, classification, failure = classify(args.kind, raw, args.exit_code, args.fetch_exit_code)
    if parse_error:
        parsed, classification, failure = None, parse_error, True
    if args.kind == 'wait' and (not args.head or not args.baseline):
        classification, failure = 'snapshot_context_unknown', True
    record = dict(kind=args.kind, repo=args.repo, pr=args.pr, head_sha=args.head,
                  baseline=args.baseline, observed_at=now, capture_dir=str(directory),
                  capture_id=directory.name, exit_code=args.exit_code, fetch_exit_code=args.fetch_exit_code,
                  classification=classification, failure=failure,
                  raw_stdout_path=str(directory/'stdout'), raw_stderr_path=str(directory/'stderr'))
    if args.kind == 'gate':
        record.update(cycles=text(directory/'audit'), last_gate=parsed)
        if not record['head_sha'] and parsed:
            record['head_sha'] = parsed.get('head_sha', '')
    else:
        record.update(verdict=parsed, bundle_path=args.bundle,
                      fetch_stdout_path=str(directory/'fetch.stdout'), fetch_stderr_path=str(directory/'fetch.stderr'))
        if args.bundle:
            # Retain the actual raw bundle separately from its ephemeral
            # original handle; failed copies cannot publish a usable index.
            try:
                contents = capture_bytes(Path(args.bundle))
                if len(contents) > LIMIT:
                    raise ValueError('bundle_copy_limit')
                (directory/'bundle').write_bytes(contents)
                record['retained_bundle_path'] = str(directory/'bundle')
            except (OSError, ValueError):
                record.update(classification='bundle_unavailable', failure=True,
                              bundle_capture_error='bundle_missing_unreadable_or_over_limit')
    target = directory/'record.json'
    with tempfile.NamedTemporaryFile(mode='w', dir=directory, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(record, stream)
    os.replace(temporary, target)
    print(json.dumps(record))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError):
        print('recovery-evidence: capture unavailable, invalid or outside verified target scope; no verdict saved', file=sys.stderr)
        sys.exit(1)
