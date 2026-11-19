"""Read one same-user process stamp. A failure must never prove exit."""
import ctypes
import os
import re
import sys
from pathlib import Path


# Public macOS SDK definitions in <sys/proc_info.h> and <sys/param.h>.
PROC_PIDTBSDINFO = 3
MAXCOMLEN = 16


class DarwinBSDInfo(ctypes.Structure):
    _fields_ = [
        ('flags', ctypes.c_uint32),
        ('status', ctypes.c_uint32),
        ('xstatus', ctypes.c_uint32),
        ('pid', ctypes.c_uint32),
        ('ppid', ctypes.c_uint32),
        ('uid', ctypes.c_uint32),
        ('gid', ctypes.c_uint32),
        ('ruid', ctypes.c_uint32),
        ('rgid', ctypes.c_uint32),
        ('svuid', ctypes.c_uint32),
        ('svgid', ctypes.c_uint32),
        ('reserved', ctypes.c_uint32),
        ('comm', ctypes.c_char * MAXCOMLEN),
        ('name', ctypes.c_char * (2 * MAXCOMLEN)),
        ('nfiles', ctypes.c_uint32),
        ('pgid', ctypes.c_uint32),
        ('pjobc', ctypes.c_uint32),
        ('tdev', ctypes.c_uint32),
        ('tpgid', ctypes.c_uint32),
        ('nice', ctypes.c_int32),
        ('start_seconds', ctypes.c_uint64),
        ('start_microseconds', ctypes.c_uint64),
    ]


def darwin_start(pid, uid):
    query = ctypes.CDLL('/usr/lib/libproc.dylib').proc_pidinfo
    query.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
    query.restype = ctypes.c_int
    info = DarwinBSDInfo()
    returned = query(pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info))
    if returned != ctypes.sizeof(info) or info.pid != pid or info.uid != uid:
        raise ValueError('unknown process')
    if info.start_seconds == 0 or info.start_microseconds >= 1_000_000:
        raise ValueError('unknown start time')
    return f'darwin-bsd:{info.start_seconds}:{info.start_microseconds:06d}'


def linux_start_ticks(pid, raw):
    if len(raw) > 8192:
        raise ValueError('unexpected stat size')
    before, separator, after = raw.rpartition(b') ')
    if not separator or not before.startswith(f'{pid} ('.encode()):
        raise ValueError('unexpected stat identity')
    # The suffix starts at field 3; field 22 contains the start ticks.
    fields = after.split()
    if len(fields) <= 19 or not fields[19].isdigit() or int(fields[19]) <= 0:
        raise ValueError('unknown start time')
    return int(fields[19])


def linux_start(pid, uid):
    directory = os.open(f'/proc/{pid}', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if os.fstat(directory).st_uid != uid:
            raise ValueError('unknown process owner')
        descriptor = os.open('stat', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        with os.fdopen(descriptor, 'rb') as stat_file:
            ticks = linux_start_ticks(pid, stat_file.read(8193))
    finally:
        os.close(directory)
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    if not re.fullmatch(r'[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}', boot):
        raise ValueError('unknown boot')
    return f'linux-stat:{boot}:{ticks}'


if __name__ == '__main__':
    try:
        pid = int(sys.argv[1])
        if not 0 < pid < 2**31:
            raise ValueError('invalid PID')
        reader = {'darwin': darwin_start, 'linux': linux_start}[sys.platform]
        print(reader(pid, os.getuid()))
    except (IndexError, OSError, ValueError, KeyError, AttributeError):
        sys.exit(1)
