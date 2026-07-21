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

# Unlike GNU sed (which uses getopt_long and freely permutes flags after
# positional args), perl's own switch parser stops at the first token that
# isn't a recognized switch — that token is either the script filename or,
# if -e/-E already supplied the code, the first @ARGV element — and every
# token after it is data for the running script, not another perl switch.
# `perl checker.pl -i file` never runs sed/perl's -i at all: "checker.pl"
# already ended perl's own option parsing. A cluster ending in a bare e/E
# (`-pe`, `-npe`) also consumes the next token as -e's inline-code value,
# same as bare `-e`/`-E`, so that token doesn't end the option-parsing
# phase either.
PERL_VALUE_FLAG_RE = re.compile(r'^-[npsalwuzrE]*[eE]$')

# A leading `VAR=value` env assignment, a thin wrapper (sudo/env/xargs/...), or
# one of the wrapper's own flags (`sudo -u root`, `env -i`, `nice -n 10`)
# doesn't occupy the executable slot — the real command still follows. Any
# `-`-prefixed token is treated as "still preamble" while a wrapper is pending,
# so a wrapper's own flag (e.g. env's unrelated `-i`) is never mistaken for
# sed/perl's in-place flag.
ENV_ASSIGNMENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
COMMAND_WRAPPER_BINS = frozenset({'sudo', 'env', 'nice', 'nohup', 'time', 'command', 'exec', 'xargs'})
# A handful of each wrapper's flags take the NEXT token as their own argument
# (`sudo -u root`, `sudo --user root`, `nice -n 10`) rather than the target
# executable — without this, that argument gets mistaken for the executable
# slot and the real command (e.g. sed) right after it is missed entirely.
# Long forms only need listing for the space-separated case (`--user root`)
# — the `--user=root` equals-attached form is already one whole token, so it
# can't split flag from value across two tokens in the first place.
WRAPPER_VALUE_FLAGS = {
    'sudo': frozenset({
        '-u', '-g', '-p', '-h', '-C', '-r', '-t',
        '--user', '--group', '--prompt', '--host', '--close-from', '--role', '--type',
    }),
    'env': frozenset({'-u', '-C', '-S', '--unset', '--chdir', '--split-string'}),
    'nice': frozenset({'-n', '--adjustment'}),
    'nohup': frozenset(),
    'time': frozenset(),
    'command': frozenset(),
    'exec': frozenset({'-a', '--as'}),
    'xargs': frozenset({
        '-I', '-n', '-P', '-d', '-s', '-a', '-E', '-L',
        '--replace', '--max-args', '--max-procs', '--delimiter', '--max-chars',
        '--arg-file', '--eof', '--max-lines',
    }),
}

# Deliberately excludes fd-duplication (`2>&1`, `1>&2`): digits on both sides of
# `>&` duplicate one existing stream onto another (e.g. merging stderr into
# stdout for capture) — there is no file target, so it is never a write. Only
# `N>`/`N>>`/`&>`/`&>>` (redirect to an actual filename — `&>>` appends both
# stdout and stderr) name a file target. A redirect is a RESOLVED write: it
# says exactly where its bytes go (the embedded form carries the target in
# its own token; a bare operator's target is the next token). Only a
# protected target blocks — an unprotected one (`>/dev/null`, `2>err.log`)
# contributes nothing, and in particular must not arm the segment-wide
# write flag, which would smear "modification" onto a protected path that
# is merely executed/read in the same segment (issue #668:
# `bash .github/scripts/rule-lint.sh >/dev/null`). The segment-wide flag is
# reserved for UNRESOLVED write signals whose file targets are implicit:
# destructive bins, sed/perl -i, --fix-style flags, cp/mv.
BARE_REDIRECT_RE = re.compile(r'^(?:\d*>{1,2}\|?|&>{1,2})$')
EMBEDDED_REDIRECT_RE = re.compile(r'(?:\d*>{1,2}\|?|&>{1,2})([^<>&].*)$')
WRITE_FLAG_TOKENS = frozenset({'--write', '--fix', '-w', '-inplace'})
COPY_MOVE_BINS = frozenset({'cp', 'mv'})


def _split_into_command_segments(cmd: str) -> list[str]:
    """Split a raw shell command string into command segments at unquoted,
    unsubstituted `;`/`&&`/`||`/`|`/`&`/newline boundaries, tracking quote
    and `$(...)`/backtick command-substitution state char-by-char. A
    multi-line Bash payload (a common shape for Claude Code tool calls) is
    a sequence of commands exactly like `;`-joined ones — without this, an
    in-place edit armed on one line stays armed for an unrelated `-i` on a
    later line. A backslash immediately before a newline is a real bash
    line continuation (join two physical lines into one logical line) and
    is already preserved verbatim by the backslash-escape handling below,
    so it does not split.

    This must run on the RAW string, before shlex.split() — shlex strips
    quotes, so a post-tokenization regex split can't tell a real shell
    separator from a literal one inside a quoted argument (e.g. a sed/perl
    script's own `s/a;b/c;d/` substitution syntax) or inside a `$(...)`
    command substitution. Splitting the wrong character there breaks one
    logical command into fragments that individually don't show both "sed
    is the executable" and "-i is present" (or "the write signal" and "the
    protected path" for a substitution's parens), silently missing a real
    write. `$(...)` nesting is tracked by depth so a nested substitution
    (`$(echo $(date))`) stays opaque all the way to its matching `)`; a
    backtick region is treated like a quote (no nesting — matches bash's
    own rule that backticks can't nest without escaping). A bare `(`/`)`
    outside any substitution (e.g. `(cmd1; cmd2)` subshell grouping) is
    still a segment boundary — only substitution-owned parens are protected.
    A single `&` is skipped when adjacent to `>` (`2>&1` fd-dup, `&>`/`&>>`
    combined redirect), and a `|` immediately after `>` is skipped too
    (`>|`/`>>|`, bash's noclobber-override redirect) — both stay intact as
    one token for the redirect checks instead of being split apart.
    """
    segments: list[str] = []
    current: list[str] = []
    quote: str | None = None
    subst_depth = 0
    i = 0
    n = len(cmd)
    while i < n:
        ch = cmd[i]
        if quote:
            current.append(ch)
            if ch == quote:
                quote = None
            elif quote == '"' and ch == '\\' and i + 1 < n:
                current.append(cmd[i + 1])
                i += 1
            i += 1
            continue
        if ch in ('"', "'", '`'):
            quote = ch
            current.append(ch)
            i += 1
            continue
        if ch == '\\' and i + 1 < n:
            current.append(ch)
            current.append(cmd[i + 1])
            i += 2
            continue
        if ch == '$' and i + 1 < n and cmd[i + 1] == '(':
            subst_depth += 1
            current.append(ch)
            current.append('(')
            i += 2
            continue
        if subst_depth > 0:
            if ch == '(':
                subst_depth += 1
            elif ch == ')':
                subst_depth -= 1
            current.append(ch)
            i += 1
            continue
        if cmd[i:i + 2] in ('&&', '||'):
            segments.append(''.join(current))
            current = []
            i += 2
            continue
        if ch in (';', '|', '&', '(', ')', '\n'):
            if ch == '&':
                prev_ch = cmd[i - 1] if i > 0 else ''
                next_ch = cmd[i + 1] if i + 1 < n else ''
                if prev_ch == '>' or next_ch == '>':
                    current.append(ch)
                    i += 1
                    continue
            if ch == '|':
                prev_ch = cmd[i - 1] if i > 0 else ''
                if prev_ch == '>':
                    current.append(ch)
                    i += 1
                    continue
            segments.append(''.join(current))
            current = []
            i += 1
            continue
        current.append(ch)
        i += 1
    segments.append(''.join(current))
    return segments


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
    segment on the same line can leak in, in either direction.

    `has_write_op` tracks only UNRESOLVED write signals — writes whose file
    target is implicit (destructive bins, sed/perl in-place flags,
    --fix-style flags, cp/mv) — so while one is armed, any protected path
    in the segment is suspect. Redirects are RESOLVED writes: each names
    its own file target (the next token for a bare operator, the attached
    text for the embedded form), so a protected target blocks directly and
    an unprotected one contributes nothing at all (issue #668)."""
    has_write_op = False
    protected_targets: list[str] = []
    last_copy_move: str | None = None
    copy_move_protected: list[str] = []
    seen_in_place_capable_bin = False
    in_place_bin_kind: str | None = None  # None | 'sed' | 'perl'
    expect_perl_flag_value = False
    expect_command_name = True
    current_wrapper: str | None = None
    expect_wrapper_flag_value = False
    expect_redirect_target = False

    protected_in_cmd: list[str] = []

    for tok in tokens:
        if expect_redirect_target:
            # This token is the preceding bare redirect operator's file
            # target. A protected target is a direct write into it; any
            # other target fully accounts for the redirect's bytes, so it
            # must not taint the rest of the segment.
            expect_redirect_target = False
            if is_protected_path(tok):
                protected_targets.append(normalize_path(tok))
            continue
        if BARE_REDIRECT_RE.match(tok):
            expect_redirect_target = True
            continue
        redirect_m = EMBEDDED_REDIRECT_RE.search(tok)
        if redirect_m:
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
                    in_place_bin_kind = base
                expect_command_name = False
                current_wrapper = None
        elif in_place_bin_kind == 'perl':
            if expect_perl_flag_value:
                expect_perl_flag_value = False
            elif tok.startswith('-'):
                if IN_PLACE_FLAG_RE.match(tok):
                    has_write_op = True
                if PERL_VALUE_FLAG_RE.match(tok):
                    expect_perl_flag_value = True
            else:
                # First non-switch token: perl's own option parsing has
                # ended (this is the script filename, or perl's first
                # @ARGV element if -e/-E supplied the code) — everything
                # after is data for the running script, not another switch.
                seen_in_place_capable_bin = False
                in_place_bin_kind = None
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

    # Unresolved-write fallback: a write signal with no identified target
    # makes every protected path mentioned in the segment suspect. Resolved
    # redirects never arm has_write_op, so they cannot trigger this.
    if has_write_op and not protected_targets and protected_in_cmd:
        protected_targets = list(dict.fromkeys(protected_in_cmd))

    # protected_targets alone (a redirect into a protected file) must still
    # block even when no unresolved write signal is armed.
    if not has_write_op and not protected_targets:
        return None

    for target in protected_targets:
        if should_block_edit(target, cwd):
            return target
    return None


def bash_targets_protected(cmd: str, cwd: str | None = None) -> str | None:
    if not cmd:
        return None
    for segment_str in _split_into_command_segments(cmd):
        segment_str = segment_str.strip()
        if not segment_str:
            continue
        try:
            tokens = shlex.split(segment_str, posix=True)
        except ValueError:
            tokens = segment_str.split()
        if not tokens:
            continue
        blocked = _scan_command_segment(tokens, cwd)
        if blocked:
            return blocked
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
