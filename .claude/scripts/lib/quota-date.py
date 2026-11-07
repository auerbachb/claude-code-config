"""Bounded date operations for quota tools. No version/banner classification."""
import os
import re
import signal
import subprocess
import sys
import tempfile

TIMEOUT = 2
FORMATS = {
    '+%s': r'-?[0-9]+',
    '+%Y-%m': r'[0-9]{4}-[0-9]{2}',
    '+%Y-%m-%d': r'[0-9]{4}-[0-9]{2}-[0-9]{2}',
    '+%Y-%m-%dT%H:%M:%SZ': r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z',
    '+%a': r'(Mon|Tue|Wed|Thu|Fri|Sat|Sun)',
    '+%a %b %-d %-I:%M %p %Z': r'(Mon|Tue|Wed|Thu|Fri|Sat|Sun) [A-Z][a-z]{2} [0-9]{1,2} [0-9]{1,2}:[0-9]{2} (AM|PM) (EST|EDT)',
    '+%a %-I:%M %p': r'(Mon|Tue|Wed|Thu|Fri|Sat|Sun) [0-9]{1,2}:[0-9]{2} (AM|PM)',
    '+%b %-d %-I:%M %p ET': r'[A-Z][a-z]{2} [0-9]{1,2} [0-9]{1,2}:[0-9]{2} (AM|PM) ET',
}


class Unavailable(Exception):
    pass


def run(args, zone='UTC', cwd=None):
    env = dict(os.environ, LC_ALL='C', TZ=zone)
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            proc = subprocess.Popen(['date', *args], stdout=out, stderr=err,
                                    stdin=subprocess.DEVNULL, env=env, cwd=cwd,
                                    start_new_session=True)
            try:
                proc.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=1)
                raise Unavailable('date timed out')
            if out.tell() > 4096:
                raise Unavailable('date output too large')
            out.seek(0)
            raw = out.read().decode('utf-8')
        except (OSError, UnicodeError, subprocess.SubprocessError) as exc:
            raise Unavailable('date unavailable') from exc
    # Exactly one value, optional single trailing newline. Partial/diagnostic
    # output cannot turn a failed operation into a successful timestamp.
    return proc.returncode, raw[:-1] if raw.endswith('\n') else raw


def exact(args, wanted, zone='UTC', cwd=None):
    rc, value = run(args, zone, cwd)
    return rc == 0 and value == wanted


def detect():
    try:
        if (exact(['-u', '-d', '2000-01-02T03:04:05Z', '+%s'], '946782245')
                and exact(['-d', '@946782245', '+%Y-%m-%d %a %H:%M %Z'],
                          '2000-01-01 Sat 22:04 EST', 'America/New_York')
                and exact(['-u', '-d', '2000-02-29 12:00:00', '+%Y-%m-%d'], '2000-02-29')):
            return 'gnu'
    except Unavailable:
        return 'unavailable'
    try:
        # Never execute -r until BSD-only -j/-f is verified. A private empty
        # cwd also prevents a numeric-named file from qualifying a GNU tool.
        with tempfile.TemporaryDirectory(prefix='quota-date-probe-') as empty:
            if (exact(['-u', '-j', '-f', '%Y-%m-%dT%H:%M:%SZ',
                       '2000-01-02T03:04:05Z', '+%s'], '946782245', cwd=empty)
                    and exact(['-r', '946782245', '+%Y-%m-%d %a %H:%M %Z'],
                              '2000-01-01 Sat 22:04 EST', 'America/New_York', empty)
                    and exact(['-u', '-j', '-f', '%Y-%m-%d %H:%M:%S',
                               '2000-02-29 12:00:00', '+%Y-%m-%d'], '2000-02-29', cwd=empty)):
                return 'bsd'
    except Unavailable:
        pass
    return 'unavailable'


def format_epoch(dialect, epoch, fmt, zone):
    if fmt not in FORMATS or zone not in ('UTC', 'America/New_York'):
        raise Unavailable('unsupported format')
    if epoch == 'now':
        args = [fmt]
    elif re.fullmatch(r'-?[0-9]+', epoch):
        args = ['-d', '@' + epoch, fmt] if dialect == 'gnu' else ['-r', epoch, fmt]
    else:
        raise Unavailable('invalid epoch')
    rc, value = run(args, zone)
    if rc or not re.fullmatch(FORMATS[fmt], value):
        raise Unavailable('date formatting failed')
    return value


def parse_iso(dialect, iso):
    if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})', iso):
        return None
    iso = re.sub(r'\.[0-9]+', '', iso)
    if dialect == 'gnu':
        args = ['-u', '-d', iso, '+%s']
    elif iso.endswith('Z'):
        args = ['-u', '-j', '-f', '%Y-%m-%dT%H:%M:%SZ', iso, '+%s']
    else:
        iso = re.sub(r'([+-][0-9]{2}):([0-9]{2})$', r'\1\2', iso)
        args = ['-u', '-j', '-f', '%Y-%m-%dT%H:%M:%S%z', iso, '+%s']
    rc, value = run(args)
    if rc or not re.fullmatch(r'-?[0-9]+', value):
        return None
    return value


def calendar(dialect, day):
    if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', day):
        return None
    args = (['-u', '-d', day + ' 12:00:00', '+%Y-%m-%d'] if dialect == 'gnu'
            else ['-u', '-j', '-f', '%Y-%m-%d %H:%M:%S', day + ' 12:00:00', '+%Y-%m-%d'])
    rc, value = run(args)
    if rc:
        return None
    if not re.fullmatch(FORMATS['+%Y-%m-%d'], value):
        raise Unavailable('date validation unavailable')
    return value if value == day else None


def main():
    try:
        if sys.argv[1:] == ['detect']:
            print(detect())
            return 0
        operation, dialect, *args = sys.argv[1:]
        if dialect not in ('gnu', 'bsd'):
            raise Unavailable('date dialect unavailable')
        if operation == 'format' and len(args) == 3:
            value = format_epoch(dialect, *args)
        elif operation == 'iso' and len(args) == 1:
            value = parse_iso(dialect, args[0])
        elif operation == 'calendar' and len(args) == 1:
            value = calendar(dialect, args[0])
        else:
            raise Unavailable('invalid date operation')
        if value is None:
            return 3
        print(value)
        return 0
    except (Unavailable, ValueError, IndexError):
        return 4


if __name__ == '__main__':
    sys.exit(main())
