# Portable Skill Resolution — dependency inventory and resolution contract

How a shared skill reaches its machinery from a repo that has no `.claude/`
directory. Not auto-loaded; read on demand. Canonical for the resolution
shapes, the degraded-mode warning format, and the per-dependency
classification. Issue #1189.

## The failure this prevents

The PM and orchestration skills are symlinked into `~/.claude/skills/`, so any
repo can invoke them. Almost everything that makes them behave well —
the helper scripts, the phase-agent definitions, the reference docs holding the
inline-first gate — lived in `claude-code-config` only. In a fresh repo those
paths do not resolve, and a skill that cannot read its own routing gate does not
announce the fact; it falls through to whatever still works. The observed end
state (a fresh repo, 2026-08-18) was one coding-thread chip per ready issue,
about twenty of them, with no ceiling and no queue — every inline-first default
switched off, silently.

The rule this file encodes: **a contract that cannot be reached must be
announced, never skipped.** It is the cross-repo form of the lesson in
`guardrail-needs-its-counterweight-loaded` — a gate whose limiting text is not
loaded is a silently widened gate.

## What already travels, and what does not

| Layer | Travels? | Mechanism |
|-------|----------|-----------|
| Skills | Yes | `~/.claude/skills/<name>` → skills-worktree, per-entry symlinks |
| `CLAUDE.md` | Yes | `~/.claude/CLAUDE.md` → skills-worktree, auto-loaded at user scope |
| Rules (`.claude/rules/*.md`) | Yes | `~/.claude/rules` → skills-worktree; auto-loaded in **every** project |
| Agents (`.claude/agents/*.md`) | Yes, since #1189 | `~/.claude/agents/` real dir, per-file symlinks |
| Scripts (`.claude/scripts/*.sh`) | Only via resolution | No global symlink — use `resolve_script()` |
| Reference docs (`.claude/reference/`) | Only via resolution | No global symlink — use `resolve_doc()` |

### The rules leg needs verification only

`~/.claude/rules/*.md` auto-loads globally, the same way `~/.claude/CLAUDE.md`
does. Two independent confirmations:

1. The Claude Code memory documentation states that personal rules in
   `~/.claude/rules/` apply to every project on the machine, loading at session
   launch before project rules.
2. `double-loading-fix.md` documents this repo's `claudeMdExcludes` workaround,
   which exists *because* the global copy loads everywhere — including here,
   where it collided with the project copy. Suppression in one repo is proof of
   loading in the others.

So the pipeline ceiling (`subagent-orchestration.md`), the autonomy grants, and
the safety rules already reach a fresh repo without any change. **Do not add a
fallback read for a rule file** on the theory that it might be missing; cite it
and move on. What does *not* travel is a rule's non-loaded companion in
`.claude/reference/` — that is what `resolve_doc()` is for.

### Why agents use a real directory, not a directory symlink

`~/.claude/agents/` is a real directory holding one symlink per agent file,
mirroring the **skills** leg — not a single directory symlink mirroring the
**rules** leg. The Claude Code docs are explicit that `.claude/rules/` resolves
symlinks; they are silent on symlink-following for `agents/`. The skills
topology is empirically proven on this machine (every `~/.claude/skills/<name>`
is a symlink into the worktree, and all of them load), so it is the lower-risk
shape at identical cost, with the same single-source guarantee. Setup lives in
`setup-skills-worktree.sh`; the registration caveat is in
`.claude/agents/README.md`.

## Resolution shapes

Copy these verbatim. `resolve_script()` is already in use in `/wrap`, `/fixpr`,
`/subagent`, `/monitor`, `/end`, `/pause`, and the phase agents; the ordering is fixed —
skills-worktree (canonical, pinned to `main`), then `$HOME/.claude/scripts/`
(documented install location), then repo-relative (developing the skill itself).

**Shutdown exception:** `/end`, `/end-resume`, `/pause`, and `/pause-resume`
are explicitly callable while cwd is an unrelated checkout. Their resolvers
omit the repo-relative candidate for both scripts and instruction documents;
an executable bit in an untrusted checkout is not authority to execute code.
They fail/degrade explicitly when neither installed candidate exists.

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
```

The reference-doc counterpart resolves readable files rather than executables,
and is used for the contracts a skill must *read* before acting:

```bash
resolve_doc() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/reference/$name" \
    "$HOME/.claude/reference/$name" \
    ".claude/reference/$name"; do
    if [[ -r "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
```

Bind what a step needs at the point it first needs it, and capture the failure
rather than swallowing it — `X=$(resolve_script foo.sh || true)` followed by an
emptiness test, never a bare `$(resolve_script foo.sh)` under `set -e`.

`$HOME/.claude/scripts/` does not exist on every machine (it does not exist on
the current one). It stays in the list because it is a documented install
location and costs one `-x` test; its absence is not a defect.

### Why the resolved path is held in `script_path`, never `path` (issue #1556)

The variable that `run_script()` holds the resolved path in is named
`script_path` deliberately — do not "tidy" it back to `path`. The Bash tool an
agent runs is the session's shell, zsh on macOS, and in zsh lowercase `path` is
a special array **tied** to the scalar `PATH`. `local path; path=/tmp/x` leaves
`typeset -aT PATH path=( /tmp/x )` — PATH is gone for the rest of that function
body, which is precisely where `"$path" "$@"` runs. Every `run_script` call then
fails with `env: bash: No such file or directory`, a message that reads like a
missing helper rather than a destroyed PATH (it was misread exactly that way
when the bug was found). The same text is harmless under bash, so no `.sh` file
in this repo is affected and none needs renaming.

Enforced by `.github/scripts/zsh-special-name-lint.sh`, which rejects
assignments to zsh-special names inside shell-fenced Markdown blocks. The other
names it covers (`cdpath`, `fpath`, `status`, `argv`, …) and their measured
failure modes are documented in that script's header.

### The RESOLVE block (canonical — reproduce verbatim)

Subagent spawn prompts cannot run a shell function defined in a skill file, so
the contract reaches them as prose, alongside SAFETY/MINDSET/SKILLS. This is the
canonical copy; `subagent-phase-guardrails.md` carries the verbatim duplicate
that the phase templates insert, and `skill-portability-lint.sh` byte-compares
the two. Edit here, never there.

```text
RESOLVE: Never invoke a bare `.claude/scripts/<name>` path — the repo you are
working in may carry no `.claude/` directory. Resolve every helper script to the
first executable of, in order:
  "$HOME/.claude/skills-worktree/.claude/scripts/<name>"
  "$HOME/.claude/scripts/<name>"
  ".claude/scripts/<name>"
Read reference docs the same way under `.claude/reference/`. If no candidate
resolves, say so in ONE visible line naming the file and the paths checked —
`ERROR: <name> not found (checked all three paths) — <capability> unavailable`
when the step cannot proceed without it, or `DEGRADED: <name> not found (checked
all three paths) — <capability> unavailable, continuing without it` when there is
a real reduced mode. Never skip a contract silently: an unreachable gate that
nobody mentions is the failure this rule exists to stop. Rules under
`.claude/rules/*.md` need no fallback — they auto-load at user scope in every
project. Full contract: .claude/reference/portable-skill-resolution.md.
```

## Degraded-mode warnings

**Never skip a contract silently.** Every unresolved dependency emits exactly
one line naming the file that was not found and the paths that were checked.
Two severities, assigned per dependency in the inventory below:

**Required** — the capability is the point of the step. Stop the dependent
action; do not proceed in a reduced mode.

```text
ERROR: <file> not found (checked ~/.claude/skills-worktree/.claude/scripts/, ~/.claude/scripts/, .claude/scripts/) — <capability> unavailable
```

**Optional** — the step has a meaningful reduced mode. Warn once, name what is
lost, continue.

```text
DEGRADED: <file> not found (checked …) — <capability> unavailable, continuing without it
```

The distinction is not stylistic. The **inline gate is required**: a `/pm` run
that cannot read it is the exact run that fans out one chip per issue, so it
must stop and say so rather than route work to twenty threads. The **claim is
optional**: an unreachable `issue-claim.sh` must be loud, but blocking every
client repo from starting work because a coordination helper is missing trades
one failure for a worse one. Warn, name it, continue unclaimed.

## Dependency inventory

Classification is one of:

- **bundled** — travels inside the skill directory; nothing to resolve.
- **fallback** — reached with `resolve_script()` / `resolve_doc()`.
- **global** — auto-loaded at user scope in every project; cite directly.
- **repo-local** — genuinely per-repo data; absence is a normal state, and the
  skill must say so rather than assume a default.

**Load-bearing contracts** (marked ★) are the ones whose silent absence changes
routing or safety behavior rather than merely reducing output quality.

### Scripts

| Script | Used by | Class | Severity | Note |
|--------|---------|-------|----------|------|
| ★ `issue-claim.sh` | pm, subagent, prompt, wave, issue-maker, start-issue, + every generated chip | fallback | optional | Repo-agnostic (`gh`-driven). Also ships inside the chip `### Constraints` bullet — see below. |
| ★ `session-state.sh` | pm, subagent, pr-monitor-and-manage | fallback | required | Repo-keyed state; see repo-scoped state below. |
| `handoff-state.sh` | subagent, phase agents | fallback | required | Already resolved before #1189. |
| `issue-dedup.sh` | issue-maker, start-issue, pm-worker | fallback | optional | Already resolved before #1189. |
| `pr-preflight.sh`, `release-sweep.sh` | pr-monitor-and-manage | fallback | optional | Already resolved before #1189. |
| `cr-plan.sh` | subagent, start-issue | fallback | optional | Absence means no CR plan poll; the issue-body merge is still required. |
| `ac-checkboxes.sh` | subagent | fallback | optional | |
| `escalate-review.sh` | subagent | fallback | required | Drives the reviewer escalation chain. |
| `local-review.sh` | pm, subagent, prompt (chip text) | fallback | optional | Missing → self-review fallback per `cr-local-review.md`. |
| `backlog-health.sh` | pm | fallback | optional | Missing → omit the staleness block, say so. |
| `merge-gate.sh`, `merge-sequence.sh` | pr-monitor-and-manage | fallback | required | Merge decisions must never run on a guessed gate. |
| `repo-root.sh` | start-issue, pr-monitor-and-manage | fallback | optional | Inline `git worktree list` fallback exists. |
| `pm-config-get.sh` | pm, wave | fallback **script**, repo-local **data** | optional | See below. |

`pm-config-get.sh` is the one split case: the *script* resolves through the
fallback list like any other, but the data it reads (`.claude/pm-config.md`) is
genuinely per-repo. A fresh repo has no PM config, and that is a normal state,
not a resolution failure — `/pm` bootstraps it. Do not emit a `DEGRADED:` line
for absent config; emit one only when the script itself cannot be found.

### Reference docs

| Doc | Used by | Class | Severity |
|-----|---------|-------|----------|
| ★ `chip-launching.md` (PM-context inline gate) | pm, wave, prompt, issue-maker, start-issue | fallback | **required** |
| `pm-output-templates.md` | pm | fallback | optional |
| `subagent-phase-guardrails.md` | subagent | fallback | required |
| `issue-claim.md` | subagent, start-issue | fallback | optional |
| `autofile-dedup.md` | issue-maker, start-issue | fallback | optional |
| `cr-rate-limits.md` | wave | fallback | optional |
| `merge-sequencing.md`, `release-cadence.md` | subagent, pr-monitor-and-manage | fallback | optional |
| `session-state-schema.json` | pm | fallback | optional |
| `too-big-recalibration-2026-07.md`, `pm-monitoring-decision.md`, `token-efficiency-audit-2026-07.md` | subagent, prompt | fallback | optional (rationale only) |

### Rules and agents

| Dependency | Used by | Class |
|------------|---------|-------|
| ★ pipeline ceiling — `subagent-orchestration.md` | pm, wave, prompt, start-issue | global |
| `monitor-mode.md`, `scheduling-reliability.md`, `issue-planning.md`, `cr-*.md`, `safety.md`, `skill-first.md`, `skill-symlinks.md` | various | global |
| `.claude/rules/.budget-soft-cap` | wave | repo-local (this repo's surface table only) |
| ★ `/subagent` Step 4 too-big criteria | pm, wave, subagent | **bundled** — the criteria are written inline in `/subagent` Step 4 and quoted in `/pm` Step 3.1, so the contract already travels. Only its rationale doc needs a fallback read. |
| `phase-a-fixer` … `researcher` | subagent, pr-monitor-and-manage | agents symlink leg (above) |

## Repo-scoped state

`session-state.sh` keys state under `.repos["<owner>/<name>"]`, auto-scoped from
`--repo`, `$CLAUDE_SESSION_REPO`, or the cwd git origin. Resolving the *script*
from the skills-worktree is therefore safe from any repo: the binary is shared,
the state is namespaced, and running it from a client repo writes to that
repo's own key in the global `~/.claude/session-state.json`.

The one genuine degradation is a cwd with **no git origin**, where the repo key
cannot be inferred and entries land in `_unknown`. That is a pre-existing
behavior the script already reports; repair with
`session-state-audit.sh --apply --reattribute`. Pass `--repo` explicitly when a
skill operates on a repo other than its cwd. `issue-claim.sh` infers the repo
the same way and behaves the same when the remote is absent.

## The chip Constraints bullet

Chip emitters copy only the **named** sections of `chip-launching.md`, so a rule
that lives only in that file's prose never reaches a generated chip
(`chip-emitters-copy-only-named-sections`). The claim instruction therefore
ships as a `### Constraints` bullet reproduced verbatim across `/pm`, `/prompt`,
`/wave`, and `/issue-maker` — and that bullet lands in a coding thread running
**in another repo**, which makes it the single highest-leverage resolution site
in the corpus. Its script path carries the candidate order inline for the same
reason: there is nowhere else for a generated chip to read it from.

## Enforcement

`.github/scripts/skill-portability-lint.sh` derives its skill surface from every
immediate directory published by `setup-skills-worktree.sh` under
`.claude/skills/`, then fails when any of those skills (including their
`references/*.md` files), a chip Constraints block, or an agent definition
invokes a helper through a bare `.claude/scripts/…` path. The shared dynamic
enumerator is also used by the regression fixture, so a newly published skill
cannot bypass either production coverage or its tests through a stale list.
`run-doc-lints.sh` auto-discovers `*-lint.sh`, so the lint needs no workflow
edit. A hand-run grep was the alternative; it rots silently, which is the
failure mode this whole file exists to close.

## References

- Issue #1189; related #613, #776, #701 (inline-first, settled in-repo), #1131
  (agent-type registration)
- `.claude/rules/skill-symlinks.md` — symlink topology and the agents leg
- `.claude/reference/skill-symlink-setup.md` — install and migration commands
- `.claude/reference/double-loading-fix.md` — evidence for the global rules load
- `.claude/reference/chip-launching.md` — the PM-context inline gate itself
