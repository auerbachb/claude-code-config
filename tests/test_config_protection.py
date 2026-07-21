#!/usr/bin/env python3
"""Unit tests for .claude/hooks/config-protection.py."""

import importlib.util
import pathlib
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG_PROTECTION_PATH = REPO_ROOT / ".claude" / "hooks" / "config-protection.py"

spec = importlib.util.spec_from_file_location("config_protection", CONFIG_PROTECTION_PATH)
config_protection = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(config_protection)


class ConfigProtectionPathTests(unittest.TestCase):
    def test_is_protected_basename(self) -> None:
        protected = [
            '.coderabbit.yaml',
            'path/to/.coderabbit.yaml',
            'biome.json',
            '.shellcheckrc',
        ]
        for path in protected:
            with self.subTest(path=path):
                self.assertTrue(config_protection.is_protected_path(path))

    def test_is_protected_relative(self) -> None:
        protected = [
            '.github/scripts/rule-lint.sh',
            'foo/.github/scripts/rule-lint.sh',
            '.claude/rules/.budget-soft-cap',
        ]
        for path in protected:
            with self.subTest(path=path):
                self.assertTrue(config_protection.is_protected_path(path))

    def test_ignores_unrelated_paths(self) -> None:
        ignored = ['', 'README.md', 'setup.sh', '.env', 'CLAUDE.md']
        for path in ignored:
            with self.subTest(path=path):
                self.assertFalse(config_protection.is_protected_path(path))


class ConfigProtectionEditTests(unittest.TestCase):
    def test_allows_create_when_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            self.assertFalse(config_protection.should_block_edit(str(target)))

    def test_blocks_edit_when_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            self.assertTrue(config_protection.should_block_edit(str(target)))


class ConfigProtectionBashTests(unittest.TestCase):
    def test_bash_blocks_mutation_of_existing_protected_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"sed -i 's/x/y/' {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_allows_create_of_missing_protected_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            cmd = f"printf 'new' > {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertIsNone(blocked)

    def test_bash_allows_read_only_interpreter_invocations(self) -> None:
        # issue #624: merely running sed/awk/perl/python/node/ruby against a
        # protected path is not a write — only an actual write signal is.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            read_only_cmds = [
                f"sed -n '1,5p' {target}",
                f"awk '{{print}}' {target}",
                f"perl -ne 'print' {target}",
                f"python3 read_only_checker.py {target}",
                f"python read_only_checker.py {target}",
                f"node lint.js {target}",
                f"ruby check.rb {target}",
                f"python3 -i {target}",  # -i here is python's interactive flag, not in-place
            ]
            for cmd in read_only_cmds:
                with self.subTest(cmd=cmd):
                    self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_blocks_perl_in_place_edit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"perl -i -pe 's/x/y/' {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_blocks_sed_in_place_edit_with_backup_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"sed -i.bak 's/x/y/' {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_blocks_explicit_write_flag_on_interpreter_script(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"python3 fixer.py --fix {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_blocks_tee_to_protected_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"tee {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_allows_read_with_trailing_stderr_merge(self) -> None:
        # issue #624: a trailing `2>&1` (duplicating stderr onto stdout, e.g.
        # to capture combined output) has no file target and must not be
        # treated as a write, even though it looks like a redirect operator.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            read_only_cmds = [
                f"cat {target} 2>&1",
                f"bash {target} 2>&1",
                f"cat {target} 1>&2",
            ]
            for cmd in read_only_cmds:
                with self.subTest(cmd=cmd):
                    self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_blocks_write_with_trailing_stderr_merge(self) -> None:
        # A real write (redirect to a named file) must still be caught even
        # when followed by an unrelated fd-duplication token.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"sed -i 's/x/y/' {target} 2>&1"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_blocks_clustered_in_place_short_flags(self) -> None:
        # CodeRabbit/CodeAnt review finding: bundled short flags (-i last in
        # the cluster) must still count as in-place edits.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sed -ni 's/x/y/p' {target}",
                f"perl -npi -e 's/x/y/' {target}",
                f"perl -pi -e 's/x/y/' {target}",
                # CodeAnt review finding: BSD/macOS sed's common "extended
                # regex + in-place" idiom, capital E.
                f"sed -Ei '' 's/x/y/' {target}",
                f"sed -Ei.bak 's/x/y/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_blocks_gnu_long_form_in_place(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sed --in-place 's/x/y/' {target}",
                f"sed --in-place=.bak 's/x/y/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_allows_unrelated_attached_arg_flags_containing_i(self) -> None:
        # perl's -I<dir> and -m<module> take an attached argument that can
        # itself contain the letter 'i' — must not be mistaken for -i.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"perl -Ilib checker.pl {target}",
                f"perl -mstrict checker.pl {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_in_place_state_does_not_leak_across_command_separators(self) -> None:
        # CodeRabbit/CodeAnt review finding: an earlier unrelated sed/perl call
        # must not make a later unrelated `-i` (e.g. grep's case-insensitive
        # flag) in the same compound line look like a write. Covers both the
        # spaced and glued-to-the-prior-word separator styles.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            read_only_cmds = [
                f"sed -n 'p' notes.txt; grep -i pattern {target}",
                f"sed -n 'p' notes.txt ; grep -i pattern {target}",
                f"sed -n 'p' notes.txt && grep -i pattern {target}",
                f"sed -n 'p' notes.txt | grep -i pattern {target}",
                # Fully glued, no spaces at all around the separator — shlex
                # returns these as one token, unlike the space-padded forms
                # above, so they exercise a different code path.
                f"sed -n 'p' notes.txt&&grep -i pattern {target}",
                f"sed -n 'p' notes.txt&& grep -i pattern {target}",
                f"sed -n 'p' notes.txt |grep -i pattern {target}",
            ]
            for cmd in read_only_cmds:
                with self.subTest(cmd=cmd):
                    self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_blocks_real_write_around_command_separators(self) -> None:
        # A genuine sed/perl -i must still be caught next to a separator.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sed -i 's/x/y/' {target}; echo done",
                f"echo start && sed -i 's/x/y/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_write_op_does_not_leak_across_command_separators(self) -> None:
        # CodeAnt review finding: an earlier unrelated write (to a different
        # file) in a compound line must not cause a later plain read of a
        # protected file to be falsely blocked.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            other = pathlib.Path(tmp) / 'notes.txt'
            other.write_text('unrelated\n', encoding='utf-8')
            read_only_cmds = [
                f"sed -i 's/x/y/' {other}; cat {target}",
                f"sed -i 's/x/y/' {other} && cat {target}",
                f"sed -i 's/x/y/' {other} | cat {target}",
                # cp/mv target-tracking must also stay scoped to its own
                # segment, not leak into a later unrelated read.
                f"cp a b; cat {target}",
            ]
            for cmd in read_only_cmds:
                with self.subTest(cmd=cmd):
                    self.assertIsNone(config_protection.bash_targets_protected(cmd))
            # The real write must still be caught wherever it lands.
            for cmd in [
                f"cat {other}; sed -i 's/x/y/' {target}",
                f"echo ok && sed -i 's/x/y/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_quoted_separator_chars_do_not_split_the_command(self) -> None:
        # CodeAnt review finding: splitting on separator characters AFTER
        # shlex.split() loses quote context, so a sed/perl script's own `;`
        # or `|` (substitution-chaining syntax, not a shell separator) got
        # fake-split into disconnected fragments — silently missing a real
        # in-place edit where -i (via GNU flag permutation) landed in a
        # different fragment than the sed/perl executable it belongs to.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sed 's/a;b/c;d/' -i {target}",
                f"sed 's/a|b/c|d/' -i {target}",
                f"perl -i -pe 's/a;b/c/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_blocks_in_place_edit_through_long_form_wrapper_flag(self) -> None:
        # CodeAnt review finding: a wrapper's long-form value flag
        # (`sudo --user root`, `nice --adjustment 10`) must be recognized
        # the same way as its short form, or the real executable after it
        # gets missed.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sudo --user root sed -i 's/x/y/' {target}",
                f"nice --adjustment 10 sed -i 's/x/y/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_allows_in_place_bin_name_as_plain_argument(self) -> None:
        # CodeRabbit/CodeAnt review finding: `sed`/`perl` must only arm
        # in-place detection when they are the executable, not when their
        # name merely appears as another command's argument (e.g. a grep
        # search pattern) — otherwise an unrelated `-i` later in the same
        # single command gets misread as a write.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"grep -l sed *.txt -i {target}"
            self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_blocks_in_place_edit_through_env_prefix_and_wrapper(self) -> None:
        # A leading `VAR=value` or a thin wrapper (sudo/env/xargs/...) must
        # not hide the real sed/perl executable that follows it.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sudo sed -i 's/x/y/' {target}",
                f"env sed -i 's/x/y/' {target}",
                f"FOO=bar sed -i 's/x/y/' {target}",
                f"FOO=bar BAZ=qux sed -i 's/x/y/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_blocks_in_place_edit_past_wrapper_own_bare_flag(self) -> None:
        # CodeAnt review finding: a wrapper's own bare flag (no separate-token
        # argument) — e.g. env's unrelated -i — must not be mistaken for
        # sed/perl's in-place flag, and must not swallow the real executable.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"env -i sed -i 's/x/y/' {target}"
            self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_blocks_in_place_edit_past_wrapper_value_flag(self) -> None:
        # CodeAnt review finding: a wrapper flag that takes its own
        # separate-token argument (sudo's -u, nice's -n) must not be
        # mistaken for the target executable, or the real sed/perl right
        # after it gets missed entirely.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sudo -u root sed -i 's/x/y/' {target}",
                f"nice -n 10 sed -i 's/x/y/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_fd_duplication_not_split_into_separators(self) -> None:
        # `2>&1`/`1>&2` must survive the command-separator split intact —
        # splitting on the embedded `&` would otherwise turn `2>&1` into
        # `2>` (a real redirect operator) + `&` + `1`, reblocking reads.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"cat {target} 2>&1",
                f"cat {target} 1>&2",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertIsNone(config_protection.bash_targets_protected(cmd))


if __name__ == '__main__':
    unittest.main()
