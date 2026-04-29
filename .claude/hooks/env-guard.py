#!/usr/bin/env python3
# .env file protection — PreToolUse hook
# Blocks Write/Edit/Bash operations that would modify .env files.
# Defense-in-depth enforcement of the rule in .claude/rules/safety.md.
#
# Matches basenames: .env, .env.local, .env.production, .env.test, .env.ci, etc.
# Does NOT match: environment.ts, env-config.json, rails_env, my.env.backup.
#
# Allow-list: basenames matching `.env.<suffix>` where <suffix> (case-insensitive)
# is in TEMPLATE_SUFFIXES (example, sample, template) are treated as
# committed-to-repo templates and are NOT blocked. Everything else defaults to
# deny — including bare `.env` and any unrecognized suffix.
#
# Hook protocol: reads tool-invocation JSON from stdin. Exit code 2 with a
# message on stderr blocks the tool call and surfaces the reason to the agent.
#
# Scope and limitations
# ---------------------
# `bash_targets_env` is a best-effort static token analyzer. It is NOT a
# sandbox and can be bypassed by constructs it cannot see statically:
#   - Variable expansion:        `F=.env; rm "$F"`
#   - Indirect execution:        `eval "rm .env"`, `bash -c "rm .env"`
#   - Here-documents/scripts:    `bash script.sh` where script.sh removes .env
#   - Parameter expansion tricks: `rm .en${X:-v}`
# This hook is defense-in-depth alongside the behavioral rules in
# `.claude/rules/safety.md`, not a foolproof security guarantee. The relevant
# logic lives in `is_env_path`, `bash_targets_env`, and `DESTRUCTIVE_BINS`.

import json
import re
import shlex
import sys

BLOCK_MSG = (
    "BLOCKED: Cannot modify .env files. These contain secrets that cannot be "
    "recovered. See .claude/rules/safety.md."
)

# Basename is `.env` or `.env.<suffix>` (letters/digits/underscore/hyphen).
# Anchored to a path boundary so `environment.ts`, `env-config.json`,
# `rails_env`, and `my.env.bak` do NOT match.
ENV_BASENAME_RE = re.compile(r'(?:^|/)\.env(?:\.[A-Za-z0-9_-]+)?$')

# Allow-list of suffixes that identify non-secret template/example files.
TEMPLATE_SUFFIXES = frozenset({'example', 'sample', 'template'})

# Bash binaries that can mutate files. We only block a Bash command if one of
# these appears AND the command also references a .env path. Non-mutating reads
# like `cat .env` or `grep X .env` are not blocked by the hook — using the Read
# tool is still the preferred path for auditing secrets.
DESTRUCTIVE_BINS = {
    'rm', 'mv', 'cp', 'rsync', 'install', 'dd', 'truncate', 'shred',
    'chmod', 'chown', 'tee', 'sed', 'awk', 'perl', 'python', 'python3',
    'ruby', 'node', 'touch', 'ln',
}

# Write-redirect operators we treat as mutation: `>`, `>>`, `2>`, `&>`, `>&N`.
# Input redirect `<` is a read and is not treated as mutation.
BARE_REDIRECT_RE = re.compile(r'^(?:\d*>{1,2}|&>|\d*>&\d*)$')
EMBEDDED_REDIRECT_RE = re.compile(r'(?:\d*>{1,2}|&>)([^<>&].*)$')


def is_env_path(path: str) -> bool:
    if not path:
        return False
    p = path.strip().strip('"').strip("'").rstrip('/')
    if not ENV_BASENAME_RE.search(p):
        return False
    basename = p.rsplit('/', 1)[-1]
    if '.' in basename[1:]:
        suffix = basename.rsplit('.', 1)[-1].lower()
        if suffix in TEMPLATE_SUFFIXES:
            return False
    return True


def bash_targets_env(cmd: str) -> bool:
    if not cmd:
        return False
    try:
        tokens = shlex.split(cmd, posix=True)
    except ValueError:
        tokens = cmd.split()

    has_env_token = False
    has_write_op = False

    for tok in tokens:
        # Bare write-redirect operator: `>`, `>>`, `2>`, `&>`, `>&N`.
        if BARE_REDIRECT_RE.match(tok):
            has_write_op = True
            continue
        # Embedded redirect anywhere in the token: `>.env`, `foo>>.env.prod`.
        # Using search (not match) catches the second form too.
        redirect_m = EMBEDDED_REDIRECT_RE.search(tok)
        if redirect_m:
            has_write_op = True
            target = redirect_m.group(1)
            if is_env_path(target):
                has_env_token = True
            continue
        # Destructive binary (match on basename so `/bin/rm` still counts).
        base = tok.rsplit('/', 1)[-1]
        if base in DESTRUCTIVE_BINS:
            has_write_op = True
            continue
        # Plain token that looks like a blocked .env path.
        if is_env_path(tok):
            has_env_token = True

    return has_env_token and has_write_op


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    tool_name = payload.get('tool_name') or payload.get('toolName') or ''
    tool_input = payload.get('tool_input') or payload.get('toolInput') or {}
    if not isinstance(tool_input, dict):
        return 0

    blocked = False
    reason = ''

    if tool_name in ('Write', 'Edit', 'MultiEdit', 'NotebookEdit'):
        path = tool_input.get('file_path') or tool_input.get('notebook_path') or ''
        if is_env_path(path):
            blocked = True
            reason = f"{BLOCK_MSG} (tool={tool_name}, path={path})"
    elif tool_name == 'Bash':
        cmd = tool_input.get('command') or ''
        if bash_targets_env(cmd):
            blocked = True
            reason = (
                f"{BLOCK_MSG} (tool=Bash, command would modify a .env path). "
                "If you need to read a .env file, use the Read tool."
            )

    if blocked:
        sys.stderr.write(reason + "\n")
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
