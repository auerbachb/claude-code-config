# Human tasks — `owner-task.sh`

One list per repo of what only the operator can do: fill in a `.env`, sign in to an account, accept an agreement, run a live test on his own profiles. The list lives on GitHub, so it follows him across threads, machines and coding apps, and any tool can read it (Issue #2538). It also records **why** each task needed a person, which is what a later effort to shrink the list works from.

Script: `.claude/scripts/owner-task.sh` (`--help` lists every flag and exit code).

## Commands

```bash
owner-task.sh add --what "Fill in STRIPE_PUBLISHABLE in .env" \
                  --why "secret-value: only the operator holds the Stripe dashboard login" \
                  --source "https://github.com/<owner>/<repo>/pull/123"   # prints ht-xxxxxxxx
owner-task.sh list                       # open tasks for this repo
owner-task.sh list --all --json          # include done; machine-readable
owner-task.sh list --json --all-repos    # every repo with a tracker or a pointer entry
owner-task.sh done ht-xxxxxxxx --proof "grep STRIPE_PUBLISHABLE .env found a value"
owner-task.sh done ht-xxxxxxxx --by operator
owner-task.sh where                      # which location holds this repo's tasks, and why (plus any earlier tracker list still reads)
```

`--repo OWNER/NAME` overrides the current checkout's repo on every command except `--all-repos`.

## Handing the operator a task

The rule is `human-queue.md` §Operator-only tasks (Issue #2561); this section is its mechanism. The operator decided it on 2026-11-19: every task a thread hands him is saved automatically, with no per-task confirmation, and each one records why a person was needed, because the long-term goal is to remove human steps.

1. **Ladder first.** A task is saved only after the thread has walked the capability ladder (`safety.md` §Capability Discovery) and established it cannot do the step itself: no CLI, MCP tool, skill or browser path finishes it. "I could but it is a deployment step" is not a reason; run it.
2. **Save in the same turn.** The turn that asks the operator to do it runs `owner-task.sh add`, then prints one receipt line:

   ```text
   human task ht-1a2b3c4d saved: Fill in STRIPE_PUBLISHABLE in .env (secret-value)
   ```

3. **Done straight away means marked done.** If he does it in the same conversation and the thread can check it, the thread marks it done with that check (below). Otherwise it simply waits on the list.
4. **Not saved (exit 3, or any other non-zero exit).** A public repo with no private bucket in the pointer file exits 3 and writes nothing; this repo is one. The thread still states the task in chat and adds one line saying it was not saved and why, for example `not saved to the human-task list: this repo is public and no private bucket is set (owner-task.sh exit 3)`. Exit 5 means the text held a secret: rewrite it naming the variable, then retry.

### Why a person: the reason list

`--why` is `"<reason>: <free text>"`. The reason is one of a fixed list, so tasks can be grouped by what blocked automation; the free text says what exactly.

| Reason | Use when |
|--------|----------|
| `sign-in` | An interactive login, 2FA prompt or OAuth consent only he can complete |
| `legal-agreement` | Terms, a contract, a team invite or any consent given in his name |
| `payment-detail` | A card, bank detail, purchase or plan change |
| `secret-value` | A value only he holds, such as a `.env` entry or an API key from a dashboard |
| `physical-device` | His phone, hardware key, a live test on his own machine or profiles |
| `judgment-call` | A decision that is his to make, not a fact a thread can look up |

`add` refuses (exit 2, nothing written) a blank `--why`, one with no `reason:` prefix, an unknown reason, and a reason with no free text after the colon. A new reason is added to `WHY_REASONS` in the script and to this table together.

### Task text

`--what` names the variable, account or page, never a secret value: `Fill in STRIPE_PUBLISHABLE in .env`, not the key. The secret check (below) refuses a value that slips through, but naming is the rule, not the check.

### Sub-agents: `OWNER_ACTION:`

A sub-agent has no operator and cannot save on his behalf from a brief it cannot verify, so it reports the step instead: one line per task, above its `EXIT_REPORT`, as `OWNER_ACTION: <reason>: <what> — <free text>` (`exit-report-format.md`). The parent saves each one with `owner-task.sh add`, `--source` naming the PR or issue, and prints the receipt. The guardrails file (`subagent-phase-guardrails.md`) says so for every phase.

### Marking done

When a later thread verifies the step was done (the `.env` key is now set, `railway whoami` prints the account), it runs `owner-task.sh done <id> --proof "<the check it ran>"`. An agent never marks a task done without a check it ran; only the operator's own completion uses `--by operator`.

## Storage format

- **Tracker issue:** one open issue per repo, label exactly `human-tasks`. Titled `Human tasks` in the repo itself, `Human tasks: <owner>/<repo>` in a bucket. Its body carries `<!-- owner-task-tracker: {"repo":"<owner>/<repo>"} -->` naming the source repo, and no `/issue-maker` footer. `add` creates it on first use.
- **One comment per task**, never a checklist in the body: a comment POST is atomic, so two concurrent `add`s both land, while a body checklist would be a read-modify-write race. If two first-use `add`s each create a tracker, both converge on the lowest-numbered one and the other closes its own duplicate.
- **Each comment** starts with a hidden one-line JSON marker, which is authoritative, followed by a readable rendering of the same fields:

  ```text
  <!-- owner-task: {"v":1,"id":"ht-1a2b3c4d","repo":"<owner>/<repo>","what":"…","why":"…","source":"…","created_at":"2026-11-19T13:00:00Z","state":"open","done_at":null,"proof":null} -->
  ```

  `-->` inside a value is written `-->` so it cannot end the comment early. `done` rewrites only that comment.

### `list --json` contract (pinned — Issues #2541 and #2542 build against it)

One JSON array; each element is exactly `{id, repo, what, why, source, created_at, state, done_at, proof}`. `state` is `open` or `done`; timestamps are ISO-8601 UTC; `done_at` and `proof` are `null` while open. `repo` is always the source repo, lowercase (GitHub repo names are case-insensitive, so every identity, pointer entries included, is compared lowercase), even when the task is stored in a bucket. An empty list prints `[]` with exit 0. A source that cannot be read (repo, tracker issues, comments, the tracker search, the pointer file) exits **4** with nothing on stdout. Changing this shape means updating those two issues first.

## Lookup order

Every command resolves locations in the same order, in one function (`resolve_write_location` for writes, `read_locations` for reads):

1. **The repo's own tracker issue.** Writes go here only when the repo is `private`. Reads always check it first.
2. **The local pointer file**, naming a private bucket repo for repos that must not hold task text.

The function is the seam for a later third location (the Desk database): a new candidate is added there, after these two, without changing any caller.

## Public repos and the pointer file

A public (or `internal`) repo never receives task text. `add` writes to a per-source-repo tracker in the private bucket the pointer names, after checking that the bucket really is private. A public repo with no pointer entry exits **3** with a one-line instruction and writes nothing; a pointer naming a non-private bucket also exits 3.

Pointer file: `~/.claude/owner-tasks-pointer.json` (override with `OWNER_TASK_POINTER_FILE`). It is per machine; whether it should be synced is open.

```json
{
  "default_bucket": "<owner>/<private-bucket>",
  "repos": { "<owner>/<public-repo>": "<owner>/<private-bucket>" }
}
```

`repos` entries win over `default_bucket`. A pointer file that exists but is empty or not one JSON object is an unreadable source (exit 4). `done` also re-checks the host before writing: a task whose tracker sits in a repo that is no longer private is refused (exit 3) rather than given proof text in public. Creating the bucket repo is the operator's call; nothing here creates a repository.

## Done with proof

- An agent marks a task done only with `--proof "<the check it ran>"`, for example `railway whoami printed the account`. Without `--proof` (a whitespace-only one counts as none) and without `--by operator`, `done` exits **6** and changes nothing.
- The operator can always mark one done: `--by operator` needs no proof (the recorded proof then reads `marked done by the operator`).
- Done is final: a second `done` on the same task reports `already done` and changes nothing.

## Secrets

`what`, `why`, `source` and `proof` pass through `hq_refuse_secret` from `desk/bin/lib/secrets.sh` before any `gh` call. A hit exits **5**, names the field and the kind of secret, never the value, and writes nothing. The library is found next to the script's real path, then in `~/.claude/skills-worktree/desk/`; when neither exists the write is refused (exit **7**) rather than sent unchecked.

## `--all-repos`

Hosts are every repo returned by `search/issues` for `label:human-tasks is:issue is:open involves:@me` (so a tracker someone else opened counts once the operator has added a task to it), plus every bucket the pointer names (the search index can lag a just-created tracker). Each open tracker in each host is read once; each task record names its own source repo. A search page GitHub marks `incomplete_results` is treated as unreadable (exit 4), as is a pointer naming an invalid bucket.
