# Trust Dialog Re-Prompting Fix

> **Always:** Check `~/.claude.json` flags when the user reports trust dialog re-prompting.
> **Ask first:** Never — diagnosis and repair are safe read/write operations on a JSON config file.
> **Never:** Delete `~/.claude.json` entirely (Claude Code recreates it with `false` defaults).

`~/.claude.json` stores three per-project trust/includes flags that start `false` in a new entry. Docs say worktrees share the main checkout's trust (live behaviour unverified; includes flags undocumented). **All three** must be `true` — setting only `hasTrustDialogAccepted` leaves the includes prompts in place.

**Repair:** `bash .claude/scripts/repair-trust-single.sh /path/to/project`, or `bash .claude/scripts/repair-trust-all.sh` for every entry. Both write atomically. The `trust-flag-repair.sh` Stop hook repairs all flags after every response; a path with no entry may prompt once before repair.

Mechanism, flag semantics, and the related double-loading fix: `.claude/reference/trust-dialog-repair.md`.
