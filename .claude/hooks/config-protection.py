#!/usr/bin/env python3
# Config protection — PreToolUse hook
# Blocks Write/Edit/Bash operations that would modify protected linter/review
# config files. Defense-in-depth for "Never suppress linter errors"
# (.claude/rules/cr-local-review.md) and rule-budget enforcement.
#
# Adapted from affaan-m/everything-claude-code scripts/hooks/config-protection.js
# (issue #417). ECC blocks ESLint/Prettier/Biome/etc.; we extend with repo-specific
# paths (.coderabbit.yaml, rule-lint tooling) and use Python to match env-guard.py.
#
# First-time creation of a protected basename is allowed (bootstrap path).
# Modifying an existing protected file is blocked (exit 2 + stderr message).

# Must stay importable on Python 3.9 (macOS system python3 is 3.9.6): the
# __future__ import defers annotation evaluation so the PEP 604 unions below
# stay legal on 3.9. Never use `X | Y` unions in runtime expressions here.
from __future__ import annotations

import json
import os
import re
import shlex
import sys

BLOCK_MSG = (
    "BLOCKED: Cannot modify protected config {path}. "
    "Fix the source code to satisfy linter/review rules instead of weakening config. "
    "See .claude/rules/cr-local-review.md \"Never Suppress Linter Errors\"."
)

# Basenames from ECC config-protection.js (language-agnostic linter/formatter configs)
PROTECTED_BASENAMES = frozenset({
    '.eslintrc',
    '.eslintrc.js',
    '.eslintrc.cjs',
    '.eslintrc.json',
    '.eslintrc.yml',
    '.eslintrc.yaml',
    'eslint.config.js',
    'eslint.config.mjs',
    'eslint.config.cjs',
    'eslint.config.ts',
    'eslint.config.mts',
    'eslint.config.cts',
    '.prettierrc',
    '.prettierrc.js',
    '.prettierrc.cjs',
    '.prettierrc.json',
    '.prettierrc.yml',
    '.prettierrc.yaml',
    'prettier.config.js',
    'prettier.config.cjs',
    'prettier.config.mjs',
    'biome.json',
    'biome.jsonc',
    '.ruff.toml',
    'ruff.toml',
    '.shellcheckrc',
    '.stylelintrc',
    '.stylelintrc.json',
    '.stylelintrc.yml',
    '.markdownlint.json',
    '.markdownlint.yaml',
    '.markdownlintrc',
    '.coderabbit.yaml',
})

# Repo-relative paths (any path component match) — our meta-config tooling
PROTECTED_RELATIVE_SUFFIXES = (
    '.github/scripts/rule-lint.sh',
    '.claude/rules/.budget-soft-cap',
)

DESTRUCTIVE_BINS = {
    'rm', 'mv', 'cp', 'rsync', 'install', 'dd', 'truncate', 'shred',
    'chmod', 'chown', 'tee', 'touch', 'ln',
}

# Interpreters/utilities that are routinely invoked read-only (a lint checker,
# a one-off analysis script, `sed -n`/`perl -ne` to print) — merely appearing
# in a command is not a write signal. Only their in-place-edit flag is, and
# only when they are the actual command being run (see the executable-position
# tracking in bash_targets_protected, using ENV_ASSIGNMENT_RE/COMMAND_WRAPPER_BINS
# below) — e.g. `grep sed file` searches for the literal text "sed", it never runs it.
IN_PLACE_EDIT_BINS = frozenset({'sed', 'perl'})
# Matches bare `-i`/`-i<suffix>` (dot optional — GNU sed accepts either) and
# clustered short flags with -i last (`-ni`, `-pi`, `-npi`, `-Ei` — BSD/macOS
# sed's common "extended regex + in-place" idiom), restricted to a safe
# no-argument-flag letter set so it can't match an unrelated attached-arg flag
# that happens to contain 'i' (e.g. perl's `-Ilib`, `-mstrict` — both always
# take their value as a separate token in practice, unlike this filler set).
# Also matches GNU's long form `--in-place[=SUFFIX]`.
IN_PLACE_FLAG_RE = re.compile(r'^(?:-[npsalwuzrE]*i.*|--in-place(?:=.*)?)$')

# A leading `VAR=value` env assignment, a thin wrapper (sudo/env/xargs/...), or
# one of the wrapper's own flags (`sudo -u root`, `env -i`, `nice -n 10`)
# doesn't occupy the executable slot — the real command still follows. Any
# `-`-prefixed token is treated as "still preamble" while a wrapper is pending,
# so a wrapper's own flag (e.g. env's unrelated `-i`) is never mistaken for
# sed/perl's in-place flag.
ENV_ASSIGNMENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
COMMAND_WRAPPER_BINS = frozenset({'sudo', 'env', 'nice', 'nohup', 'time', 'command', 'exec', 'xargs'})
# A handful of each wrapper's flags take the NEXT token as their own argument
# (`sudo -u root`, `nice -n 10`) rather than the target executable — without
# this, that argument gets mistaken for the executable slot and the real
# command (e.g. sed) right after it is missed entirely.
WRAPPER_VALUE_FLAGS = {
    'sudo': frozenset({'-u', '-g', '-p', '-h', '-C', '-r', '-t'}),
    'env': frozenset({'-u', '-C', '-S'}),
    'nice': frozenset({'-n'}),
    'nohup': frozenset(),
    'time': frozenset(),
    'command': frozenset(),
    'exec': frozenset({'-a'}),
    'xargs': frozenset({'-I', '-n', '-P', '-d', '-s', '-a', '-E', '-L'}),
}

# Command-separator characters: in-place-flag state and executable-position
# tracking must not leak across these, or an earlier unrelated `sed`/`perl`
# call would make a later `grep -i` (or any other unrelated `-i`) in the same
# compound line look like a write. shlex has no concept of shell metacharacters
# — `cmd1;cmd2` (no spaces at all) comes back as one glued token — so these are
# split out of every token into their own entries before the main scan runs.
# A single `&` is excluded when adjacent to `>` (`2>&1` fd-dup, `&>file`
# combined redirect) so those stay intact as one token for the redirect checks.
COMMAND_SEPARATOR_SPLIT_RE = re.compile(r'(&&|\|\||;|\||\(|\)|(?<!>)&(?!>))')
COMMAND_SEPARATOR_RE = re.compile(r'^[;&|()]+$')

# Deliberately excludes fd-duplication (`2>&1`, `1>&2`): digits on both sides of
# `>&` duplicate one existing stream onto another (e.g. merging stderr into
# stdout for capture) — there is no file target, so it is never a write. Only
# `N>`/`N>>`/`&>` (redirect to an actual filename) count as a write signal.
BARE_REDIRECT_RE = re.compile(r'^(?:\d*>{1,2}\|?|&>)$')
EMBEDDED_REDIRECT_RE = re.compile(r'(?:\d*>{1,2}\|?|&>)([^<>&].*)$')
WRITE_FLAG_TOKENS = frozenset({'--write', '--fix', '-w', '-inplace'})
COPY_MOVE_BINS = frozenset({'cp', 'mv'})


def _split_command_separators(tokens: list[str]) -> list[str]:
    expanded: list[str] = []
    for tok in tokens:
        expanded.extend(part for part in COMMAND_SEPARATOR_SPLIT_RE.split(tok) if part)
    return expanded


def normalize_path(path: str) -> str:
    if not path:
        return ''
    return path.strip().strip('"').strip("'").replace('\\', '/').rstrip('/')


def resolve_path(path: str, cwd: str | None) -> str:
    normalized = normalize_path(path)
    if not normalized:
        return ''
    if cwd and not os.path.isabs(normalized):
        return os.path.normpath(os.path.join(cwd, normalized))
    return normalized


def is_protected_basename(path: str) -> bool:
    p = normalize_path(path)
    if not p:
        return False
    basename = p.rsplit('/', 1)[-1]
    return basename in PROTECTED_BASENAMES


def is_protected_relative(path: str) -> bool:
    p = normalize_path(path)
    if not p:
        return False
    if p.startswith('./'):
        p = p[2:]
    for suffix in PROTECTED_RELATIVE_SUFFIXES:
        if p == suffix or p.endswith('/' + suffix):
            return True
    return False


def is_protected_path(path: str) -> bool:
    return is_protected_basename(path) or is_protected_relative(path)


def path_exists(path: str, cwd: str | None = None) -> bool:
    """True if something exists at path; fail closed on non-ENOENT errors."""
    resolved = resolve_path(path, cwd)
    if not resolved:
        return False
    try:
        os.lstat(resolved)
        return True
    except FileNotFoundError:
        return False
    except OSError:
        return True


def should_block_edit(path: str, cwd: str | None = None) -> bool:
    if not is_protected_path(path):
        return False
    # Allow first-time creation (bootstrap)
    return path_exists(path, cwd)


def _scan_command_segment(tokens: list[str], cwd: str | None) -> str | None:
    """Scan one separator-free command segment for a write targeting a
    protected path. Every piece of state here is local to this single
    segment — nothing from an earlier or later `;`/`&&`/`|`-separated
    segment on the same line can leak in, in either direction."""
    has_write_op = False
    protected_targets: list[str] = []
    last_copy_move: str | None = None
    copy_move_protected: list[str] = []
    seen_in_place_capable_bin = False
    expect_command_name = True
    current_wrapper: str | None = None
    expect_wrapper_flag_value = False

    protected_in_cmd: list[str] = []

    for tok in tokens:
        if BARE_REDIRECT_RE.match(tok):
            has_write_op = True
            continue
        redirect_m = EMBEDDED_REDIRECT_RE.search(tok)
        if redirect_m:
            has_write_op = True
            target = redirect_m.group(1)
            if is_protected_path(target):
                protected_targets.append(normalize_path(target))
            continue
        base = tok.rsplit('/', 1)[-1]
        if tok in WRITE_FLAG_TOKENS:
            has_write_op = True
        if expect_command_name:
            if expect_wrapper_flag_value:
                # This token is a wrapper flag's own argument (e.g. the "root"
                # in `sudo -u root`), not the target executable.
                expect_wrapper_flag_value = False
            elif ENV_ASSIGNMENT_RE.match(tok):
                pass
            elif base in COMMAND_WRAPPER_BINS:
                current_wrapper = base
            elif tok.startswith('-'):
                if current_wrapper and tok in WRAPPER_VALUE_FLAGS.get(current_wrapper, ()):
                    expect_wrapper_flag_value = True
            else:
                if base in IN_PLACE_EDIT_BINS:
                    seen_in_place_capable_bin = True
                expect_command_name = False
                current_wrapper = None
        elif seen_in_place_capable_bin and IN_PLACE_FLAG_RE.match(tok):
            has_write_op = True
        if base in COPY_MOVE_BINS:
            has_write_op = True
            last_copy_move = base
            copy_move_protected = []
            continue
        if base in DESTRUCTIVE_BINS:
            has_write_op = True
            last_copy_move = None
            continue
        if is_protected_path(tok):
            normalized = normalize_path(tok)
            protected_in_cmd.append(normalized)
            if last_copy_move in COPY_MOVE_BINS:
                copy_move_protected.append(normalized)
            elif has_write_op:
                protected_targets.append(normalized)

    if last_copy_move in COPY_MOVE_BINS and copy_move_protected:
        protected_targets.append(copy_move_protected[-1])

    if has_write_op and not protected_targets and protected_in_cmd:
        protected_targets = list(dict.fromkeys(protected_in_cmd))

    if not has_write_op:
        return None

    for target in protected_targets:
        if should_block_edit(target, cwd):
            return target
    return None


def bash_targets_protected(cmd: str, cwd: str | None = None) -> str | None:
    if not cmd:
        return None
    try:
        tokens = shlex.split(cmd, posix=True)
    except ValueError:
        tokens = cmd.split()
    tokens = _split_command_separators(tokens)

    segment: list[str] = []
    for tok in tokens:
        if COMMAND_SEPARATOR_RE.match(tok):
            if segment:
                blocked = _scan_command_segment(segment, cwd)
                if blocked:
                    return blocked
                segment = []
            continue
        segment.append(tok)
    if segment:
        return _scan_command_segment(segment, cwd)
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    tool_name = payload.get('tool_name') or payload.get('toolName') or ''
    tool_input = payload.get('tool_input') or payload.get('toolInput') or {}
    if not isinstance(tool_input, dict):
        return 0

    cwd = tool_input.get('cwd') or payload.get('cwd') or os.getcwd()

    if tool_name in ('Write', 'Edit', 'MultiEdit', 'NotebookEdit'):
        path = tool_input.get('file_path') or tool_input.get('notebook_path') or ''
        if should_block_edit(path, cwd):
            sys.stderr.write(BLOCK_MSG.format(path=path) + '\n')
            return 2
    elif tool_name == 'Bash':
        cmd = tool_input.get('command') or ''
        blocked_path = bash_targets_protected(cmd, cwd)
        if blocked_path:
            sys.stderr.write(
                BLOCK_MSG.format(path=blocked_path)
                + f' (tool=Bash, command would modify protected config).'
                + '\n'
            )
            return 2

    return 0


if __name__ == '__main__':
    sys.exit(main())
