# Authorship Guard — Enforcement Surface (issue #733)

Expanded detail for the authorship rule in `.claude/rules/safety.md` §Authorship. The binding rule is there; this file carries the enforcement mechanics.

## Why a guard and not just a rule

Prose rules degrade. A skill's instructions get summarized, a context window compacts, a subagent inherits a snapshot that predates the rule. The authorship constraint protects other people's PRs from writes that notify humans and spend the *author's* reviewer budgets, so it cannot depend on any one prose surface surviving intact.

The guard therefore lives in the shared scripts every automated flow already funnels through. A flow that forgot the rule still hits the gate.

## `pr-authorship.sh` — the gate

```bash
.claude/scripts/pr-authorship.sh <pr> [--repo owner/repo] [--json]
```

| Exit | Meaning | Required behavior |
|------|---------|-------------------|
| `0` | Mine — authenticated user authored the PR | The only exit that authorizes a write |
| `1` | Not yours | Refuse the write, naming this guard in the refusal |
| `3` | PR not found | Refuse; surface the lookup failure |
| `4` | Undetermined (gh error, empty author) | **Fail closed** — treat exactly as `1` |

Exit `4` is the important one. A `gh` outage, a rate limit, or a malformed response must never read as permission. Authorship is established affirmatively or not at all.

Authorship is resolved against `gh api user --jq .login`; PR discovery scopes with `--author "@me"` so foreign PRs are usually never enumerated in the first place.

## Fail-safes in the shared scripts

Three scripts refuse non-author PRs on their own, independent of the calling skill's prose:

- **`polling-state-gate.sh --ensure-session`** — blocks *enrolment*. A PR that cannot be enrolled cannot be babysat, polled, or picked up by a monitor loop, which cuts off the largest class of accidental writes at the source.
- **`admin-merge.sh`** — blocks the branch-protection-bypass merge path.
- **`merge-gate.sh`** — blocks a **confirmed** foreign author, and emits an `authorship` field in its JSON so read-only callers such as `/status` can still *display* collaborator PRs while separating them from actionable rows.

The asymmetry is deliberate: `merge-gate.sh` blocks only on a confirmed-foreign author because it is also the read path for status displays, where an undetermined author should degrade to "shown but not actionable" rather than vanishing from the table.

## `--allow-nonauthor`

All three scripts accept `--allow-nonauthor`. It exists solely to implement the chat override described in `safety.md` — the user naming one specific PR in conversation.

A skill may pass it only for that named PR, only in that session, and the tool must state in its output that it is operating under an override. It is never a config default, never inferred from context, and never carried forward to the next PR.

### Persisted per-PR override (issue #1266)

`polling-state-gate.sh` is the one place the override outlives the invocation that supplied it, and only for the PR it named.

`--ensure-session` records the decision as the boolean `.prs["<N>"].allow_nonauthor` in `session-state.json`, inside the same atomic write as `root_repo`/`head_sha`/`owner_repo`. Its default poll-cycle mode reads that field back and forwards `--allow-nonauthor` to `merge-gate.sh` when it is `true`. An explicit flag on a cycle invocation still works on its own, so state written before this field existed behaves as it did before.

This exists because the per-cycle contract in `cr-github-review.md` is `polling-state-gate.sh <PR_NUMBER>` with no extra flags. The flag is supplied once, at enrolment. Without read-back, `merge-gate.sh`'s own independent authorship check re-added the blocker on every later tick, so a PR enrolled under the override could never reach "met" — the override bought enrolment and nothing else. The contract itself is unchanged: callers still pass no flags on a cycle tick.

#### What the persisted field does not authorize

It reaches exactly one check: `merge-gate.sh`'s, via the poll-cycle invocation above. `merge-gate.sh` **reports**; it does not write. The two gates that do guard writes are untouched:

- **`--ensure-session`** re-reads `--allow-nonauthor` from its own invocation and never from state, so enrolling a foreign PR still requires the user to name it again.
- **`admin-merge.sh`** keeps its own independent check, so no merge is authorized by this field.

The persisted value therefore suppresses one blocker line for a PR the user already named in chat in order to enrol it. It cannot enrol a new PR, and it cannot merge one.

#### Properties that keep it narrow

- **Scoped to one PR.** The field lives under that PR's entry in that repo's scope. It is never read for another PR or another repo.
- **Rewritten on every enrolment.** `--ensure-session` writes `false` when the flag is absent, so re-enrolling without the override clears a stale `true` rather than leaving the bypass latched on.
- **Affirmative only.** Only the literal boolean `true` grants the bypass; absent, `false`, `null`, and anything else mean not overridden. The field is typed `boolean` in `session-state-schema.json`'s `_field_types.pr_nested`, so `session-state.sh` rejects a wrong-typed write (exit 4) instead of storing a value that might later be read as permission — a stringly-typed `"true"` can never be stored and then compared as if it were the boolean.
- **Announced on every use.** `safety.md` requires a tool acting under the override to say so. Poll-cycle mode prints a notice to **stderr** naming the PR and which source enabled the bypass — the persisted decision or this invocation's flag. It goes to stderr because `merge-gate.sh`'s stdout is the JSON its callers parse.

`merge-gate.sh`'s `authorship` field still reports the truth (`not_mine`) under an override — the override suppresses the *block*, never the *finding*.

## What counts as a write

Merge, rebase, force-push, close, comment, trigger a review (`@coderabbitai` / `@cursor` / `@greptileai`), resolve a thread, enroll in babysit/polling.

Review triggers deserve emphasis because they look passive: they spend the PR author's reviewer budgets and send notifications to real people. Triggering a review on someone else's PR is a write.

## Relationship to repo scoping

This is the author-dimension analog of the invoking-repo scope (issue #687, `.claude/reference/state-file-contracts.md`). Repo scoping asks *where* the PR lives; the authorship guard asks *whose* it is. A PR must clear both to be writable.
