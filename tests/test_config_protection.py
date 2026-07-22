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
            '.eslintrc.json',
            'path/to/.eslintrc.json',
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

    def test_coderabbit_yaml_is_deliberately_unprotected(self) -> None:
        # issue #714: .coderabbit.yaml's path_filters is a scope setting, not
        # a strictness setting — see the PROTECTED_BASENAMES comment in
        # config-protection.py for the full rationale. Widening edits (e.g.
        # meeting_insights_and_actions#55) must not be blocked.
        unprotected = ['.coderabbit.yaml', 'path/to/.coderabbit.yaml']
        for path in unprotected:
            with self.subTest(path=path):
                self.assertFalse(config_protection.is_protected_path(path))


class ConfigProtectionEditTests(unittest.TestCase):
    def test_allows_create_when_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            self.assertFalse(config_protection.should_block_edit(str(target)))

    def test_blocks_edit_when_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            self.assertTrue(config_protection.should_block_edit(str(target)))


class ConfigProtectionBashTests(unittest.TestCase):
    def test_bash_blocks_mutation_of_existing_protected_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"sed -i 's/x/y/' {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_allows_create_of_missing_protected_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            cmd = f"printf 'new' > {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertIsNone(blocked)

    def test_bash_allows_read_only_interpreter_invocations(self) -> None:
        # issue #624: merely running sed/awk/perl/python/node/ruby against a
        # protected path is not a write — only an actual write signal is.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"perl -i -pe 's/x/y/' {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_blocks_sed_in_place_edit_with_backup_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"sed -i.bak 's/x/y/' {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_blocks_explicit_write_flag_on_interpreter_script(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"python3 fixer.py --fix {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_blocks_tee_to_protected_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"tee {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_allows_read_with_trailing_stderr_merge(self) -> None:
        # issue #624: a trailing `2>&1` (duplicating stderr onto stdout, e.g.
        # to capture combined output) has no file target and must not be
        # treated as a write, even though it looks like a redirect operator.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"sed -i 's/x/y/' {target} 2>&1"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_blocks_clustered_in_place_short_flags(self) -> None:
        # CodeRabbit/CodeAnt review finding: bundled short flags (-i last in
        # the cluster) must still count as in-place edits.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sed -i 's/x/y/' {target}; echo done",
                f"echo start && sed -i 's/x/y/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_newline_is_a_command_separator(self) -> None:
        # CodeAnt review finding: a multi-line Bash payload (common for
        # Claude Code tool calls) is a sequence of commands just like
        # `;`-joined ones. Without treating newline as a boundary, an
        # in-place edit armed on one line stays armed for an unrelated -i
        # on a later, unrelated line.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"sed -i 's/x/y/' notes.txt\ngrep -i pattern {target}"
            self.assertIsNone(config_protection.bash_targets_protected(cmd))
            # A real write on a later line must still be caught.
            cmd2 = f"echo hi\nsed -i 's/x/y/' {target}"
            self.assertEqual(config_protection.bash_targets_protected(cmd2), str(target))

    def test_bash_perl_option_parsing_ends_at_first_non_switch_token(self) -> None:
        # CodeAnt review finding: unlike GNU sed (which permutes flags after
        # positional args), perl's own switch parser stops at the first
        # non-switch token (the script filename, or its first @ARGV element
        # if -e/-E supplied the code) -- everything after belongs to the
        # running script, not to perl itself. `perl checker.pl -i file`
        # never runs perl's in-place edit at all.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"perl checker.pl -i {target}"
            self.assertIsNone(config_protection.bash_targets_protected(cmd))
            # A clustered -e (e.g. -pe) still consumes the next token as its
            # own inline-code value rather than ending option parsing, so a
            # real -i appearing after it is still caught.
            cmd2 = f"perl -pe 's/x/y/' -i {target}"
            self.assertEqual(config_protection.bash_targets_protected(cmd2), str(target))

    def test_bash_write_op_does_not_leak_across_command_separators(self) -> None:
        # CodeAnt review finding: an earlier unrelated write (to a different
        # file) in a compound line must not cause a later plain read of a
        # protected file to be falsely blocked.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sed 's/a;b/c;d/' -i {target}",
                f"sed 's/a|b/c|d/' -i {target}",
                f"perl -i -pe 's/a;b/c/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_noclobber_override_redirect_not_split_into_pipe(self) -> None:
        # CodeAnt review finding: `>|` (bash's noclobber-override redirect)
        # must survive the command-separator split intact — splitting it
        # into `>` + `|` moves the redirect target into a separate pipeline
        # segment with no write signal of its own, letting the write evade
        # detection entirely.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"echo x >| {target}",
                f"echo x>|{target}",
                f"echo x >>| {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_command_substitution_parens_not_split(self) -> None:
        # CodeAnt architect-review finding: the segmenter treated every `(`
        # and `)` as a hard separator, including inside `$(...)` command
        # substitution, so the write signal (-i) and the protected path
        # ended up in different segments and the real edit evaded detection.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"sed -i $(printf 's/x/y/') {target}",
                f"sed -i $(echo $(echo 's/x/y/')) {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_subshell_grouping_parens_still_split(self) -> None:
        # A bare `(...)` subshell (not a $() substitution) is still a real
        # segment boundary — an unrelated write inside it must not leak
        # into a later unrelated read outside it.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            other = pathlib.Path(tmp) / 'notes.txt'
            other.write_text('unrelated\n', encoding='utf-8')
            cmd = f"(sed -i 's/x/y/' {other}); cat {target}"
            self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_blocks_append_both_streams_redirect(self) -> None:
        # CodeAnt review finding: `&>>` (append both stdout and stderr to a
        # file) wasn't recognized by either redirect regex at all, so a
        # write via `&>>` evaded detection entirely.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"echo x &>> {target}",
                f"echo x&>>{target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_blocks_in_place_edit_through_long_form_wrapper_flag(self) -> None:
        # CodeAnt review finding: a wrapper's long-form value flag
        # (`sudo --user root`, `nice --adjustment 10`) must be recognized
        # the same way as its short form, or the real executable after it
        # gets missed.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"grep -l sed *.txt -i {target}"
            self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_blocks_in_place_edit_through_env_prefix_and_wrapper(self) -> None:
        # A leading `VAR=value` or a thin wrapper (sudo/env/xargs/...) must
        # not hide the real sed/perl executable that follows it.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"env -i sed -i 's/x/y/' {target}"
            self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_blocks_in_place_edit_past_wrapper_value_flag(self) -> None:
        # CodeAnt review finding: a wrapper flag that takes its own
        # separate-token argument (sudo's -u, nice's -n) must not be
        # mistaken for the target executable, or the real sed/perl right
        # after it gets missed entirely.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
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
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"cat {target} 2>&1",
                f"cat {target} 1>&2",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_allows_read_only_use_with_redirect_to_unprotected_target(self) -> None:
        # issue #668: a redirect names exactly where its bytes go. Running or
        # reading a protected file while redirecting OUTPUT to an unprotected
        # target (`bash rule-lint.sh >/dev/null`) is not a write to the
        # protected file — the redirect must not arm the segment-wide write
        # flag and smear "modification" onto it via the unresolved-write
        # fallback.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            read_only_cmds = [
                f"bash {target} >/dev/null",
                f"bash {target} > /dev/null",
                f"bash {target} 2>/dev/null",
                f"bash {target} >> /tmp/lint.log",
                f"bash {target} >/dev/null 2>&1",
                f"grep -c foo {target} > /tmp/count",
                f"sed -n 'p' {target} > /tmp/out",
            ]
            for cmd in read_only_cmds:
                with self.subTest(cmd=cmd):
                    self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_allows_reported_compound_with_redirected_lint_run(self) -> None:
        # issue #668: the exact reported shape — write-ish git verbs in
        # earlier segments plus a read-only protected-script run redirected
        # to /dev/null. The git segments were always inert (segments are
        # isolated); only the redirect co-located with the protected path
        # triggered the false positive.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = (
                'git add -A && git commit --amend -m "msg" && git log --oneline -1 '
                f'&& bash {target} >/dev/null && echo "LINT_STILL_OK"'
            )
            self.assertIsNone(config_protection.bash_targets_protected(cmd))

    def test_bash_blocks_redirect_into_existing_protected_file(self) -> None:
        # issue #668 regression guard: a bare operator's target is the NEXT
        # token — consuming it must still block writes into an existing
        # protected file, in every operator form (first-time creation of a
        # missing protected file stays bootstrap-allowed, covered above).
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"echo x > {target}",
                f"printf y >> {target}",
                f"echo x >{target}",
                f"bash {target} > {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))

    def test_bash_resolved_redirect_does_not_mask_real_write_elsewhere(self) -> None:
        # issue #668: an unprotected (resolved) redirect in one segment must
        # not mask a genuine protected write in another — for both a
        # redirect-write and an in-place edit, on either side.
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.eslintrc.json'
            target.write_text('existing: true\n', encoding='utf-8')
            for cmd in [
                f"bash lint.sh >/dev/null && echo y > {target}",
                f"bash {target} >/dev/null; sed -i 's/x/y/' {target}",
            ]:
                with self.subTest(cmd=cmd):
                    self.assertEqual(config_protection.bash_targets_protected(cmd), str(target))


if __name__ == '__main__':
    unittest.main()
