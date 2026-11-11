"""Verify the process probe's native read and procfs parsing."""
import importlib.util
import os
from pathlib import Path
import sys
import unittest

source = Path(__file__).parents[1] / '.claude/scripts/lib/prompt_process_stamp.py'
spec = importlib.util.spec_from_file_location('prompt_process_stamp', source)
stamp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stamp)


class ProcessStampTests(unittest.TestCase):
    def test_proc_stat_uses_the_last_command_delimiter(self):
        record = b'42 (a command ) with parentheses) S ' + b'0 ' * 18 + b'12345 0'
        self.assertEqual(stamp.linux_start_ticks(42, record), 12345)
        with self.assertRaises(ValueError):
            stamp.linux_start_ticks(41, record)

    @unittest.skipUnless(sys.platform in ('darwin', 'linux'), 'native probe is platform specific')
    def test_native_stamp_is_stable_for_the_same_process(self):
        reader, prefix = {
            'darwin': (stamp.darwin_start, 'darwin-bsd:'),
            'linux': (stamp.linux_start, 'linux-stat:'),
        }[sys.platform]
        identity = (os.getpid(), os.getuid())
        first = reader(*identity)
        self.assertTrue(first.startswith(prefix))
        self.assertEqual(first, reader(*identity))


if __name__ == '__main__':
    unittest.main()
