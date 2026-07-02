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

import json
import os
import re
import shlex
import sys
from pathlib import Path

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
    'chmod', 'chown', 'tee', 'sed', 'awk', 'perl', 'python', 'python3',
    'ruby', 'node', 'touch', 'ln',
}

BARE_REDIRECT_RE = re.compile(r'^(?:\d*>{1,2}|&>|\d*>&\d*)$')
EMBEDDED_REDIRECT_RE = re.compile(r'(?:\d*>{1,2}|&>)([^<>&].*)$')


def normalize_path(path: str) -> str:
    if not path:
        return ''
    return path.strip().strip('"').strip("'").replace('\\', '/')


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


def path_exists(path: str) -> bool:
    """True if something exists at path; fail closed on non-ENOENT errors."""
    normalized = normalize_path(path)
    if not normalized:
        return False
    try:
        os.lstat(normalized)
        return True
    except FileNotFoundError:
        return False
    except OSError:
        return True


def should_block_edit(path: str) -> bool:
    if not is_protected_path(path):
        return False
    # Allow first-time creation (bootstrap)
    return path_exists(path)


def bash_targets_protected(cmd: str) -> str | None:
    if not cmd:
        return None
    try:
        tokens = shlex.split(cmd, posix=True)
    except ValueError:
        tokens = cmd.split()

    has_write_op = False
    protected_targets: list[str] = []

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
        if base in DESTRUCTIVE_BINS:
            has_write_op = True
            continue
        if is_protected_path(tok):
            protected_targets.append(normalize_path(tok))

    if not has_write_op:
        return None

    for target in protected_targets:
        if should_block_edit(target):
            return target
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

    if tool_name in ('Write', 'Edit', 'MultiEdit', 'NotebookEdit'):
        path = tool_input.get('file_path') or tool_input.get('notebook_path') or ''
        if should_block_edit(path):
            sys.stderr.write(BLOCK_MSG.format(path=path) + '\n')
            return 2
    elif tool_name == 'Bash':
        cmd = tool_input.get('command') or ''
        blocked_path = bash_targets_protected(cmd)
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
