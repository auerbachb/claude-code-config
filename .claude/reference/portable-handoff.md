# Portable Handoff Artifact

The document `/pause` produces (issue #901). Recorded here so the two things that touch it — the skill that writes it and the usage-limit recorder that points at it — agree without either one owning the convention.

Not auto-loaded.

## Naming and location

```
~/.claude/handoffs/portable-handoff-{SESSION_ID}-{TIMESTAMP}.md
```

- `{SESSION_ID}` — `$CLAUDE_SESSION_ID`, or `default` when unset, with every character outside `[[:alnum:]_.-]` replaced by `_`. Same sanitizing as `bgwork-ceiling.sh`, for the same reason: the value becomes part of a filename.
- `{TIMESTAMP}` — UTC, `%Y%m%dT%H%M%SZ`. Lexicographic order matches chronological order, which is what makes "the most recent one" cheap to find.

It sits directly in `~/.claude/handoffs/`, alongside `issue-maker-{SESSION_ID}-log.json` and the `{owner}/{repo}/` subtrees — a flat sibling of the PR-scoped handoffs, not a member of them.

## Why it is not a `handoff-state.sh` file

`handoff-state.sh` owns `{owner}/{repo}/pr-{N}-handoff.json`: JSON, keyed by pull-request number, read-modify-written by three phases in sequence, and therefore locked. This artifact shares none of that. It is Markdown, keyed by session, written exactly once by one writer, and never updated — there is no second writer to race and no schema to preserve.

Routing it through `handoff-state.sh` would mean giving that script a non-numeric key space and a non-JSON payload to serve a file that needs neither. The "never inline `jq`" mandate in `handoff-files.md` is about read-modify-write on shared JSON state; it does not reach a new single-writer Markdown document.

## Write mechanism

`mktemp` **inside `~/.claude/handoffs/` itself**, write, verify, then `mv -f` into place. `chmod 644` after the move: the content is a work summary meant to be handed to another tool, not a secret.

The temp file's location is the whole point. `mv` is atomic only *within* one filesystem; across filesystems it degrades to copy-then-unlink, and a reader arriving mid-copy sees a truncated document that looks complete. `$TMPDIR` is frequently a different volume from `$HOME` — on macOS it is `/var/folders/…` — so staging there would quietly give up the guarantee this write mechanism exists to provide. Same directory, same filesystem, real rename.

The temp file is named `.portable-handoff.XXXXXX` — dot-prefixed and **without** the `.md` suffix, so it cannot match the `portable-handoff-*.md` glob the recorder reads. A crash between `mktemp` and `mv` therefore leaves an unverified draft that nothing will ever advertise as a handoff.

Verification happens on the temp file, before the `mv` — see below.

## Portability is enforced, not asserted

`.claude/scripts/portable-handoff-lint.sh` is the gate. It rejects harness paths, phase vocabulary, state-file names, skill invocations, unfilled template placeholders, and missing-or-empty required sections.

This is a script rather than a paragraph in the skill because the failure is silent: a document saying "resume at Phase B" still looks like a handoff, still writes successfully, and only fails much later, for a reader who by then has no context to repair it with. Prose that a renderer may or may not follow cannot catch that; an exit code can.

The one permitted `.claude/` form is an **absolute** path containing `/.claude/worktrees/` — the literal location of uncommitted work. The leading slash is the rule: an absolute path is an address any agent can resolve, while a repo-relative `.claude/worktrees/…` only means something inside this checkout. Full rule list: `portable-handoff-lint.sh --list-rules`.

## Who reads it

- **A human**, pasting it into another tool. Cursor's thread import is the case that prompted the format, but nothing here is coupled to it — it is plain Markdown on purpose, because a vendor import format can change and a paragraph of English cannot.
- **`usage-limit-record.sh`**, which points `resume_hint` at the most recent one when a turn dies on a usage limit. That is a filesystem lookup by modification time — no parsing, no content inspection, and emphatically no size or token accounting (`safety.md` §"Anthropic Quota & Spend Authority").
- **A future pre-emptive wind-down** (issue #835). When an approaching-limit signal finally reaches a hook, that wind-down emits this document instead of defining its own format. The trigger is the open question there; the artifact is settled here.

## Retention

Nothing prunes these. They are small, they are the record of a session that ended for a reason, and the most recent one is a live pointer for the recorder. Deleting old ones is a manual call.
