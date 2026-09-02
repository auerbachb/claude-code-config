---
name: go-on
description: Use when stopped work should be picked back up, whatever stopped it — `/pause`, `/end`, a token-exhaustion handoff, a session that died (crash, compaction, sign-out), or a stalled review/merge workflow. Universal resume — classifies the stoppage from the evidence. Invoke as `/go-on [--resume-refill] [--again]`.
triggers:
  - go-on
  - resume
  - pick up where we left off
  - continue the interrupted work
  - what was I doing
argument-hint: "[--resume-refill] [--again] (refill stays paused without --resume-refill)"
---

Resume the work, whatever stopped it. Step 0 classifies the stoppage from recorded evidence and routes; Steps 0b–10 are the interrupted-review-workflow lane it routes to.

## Portable helper resolution (workflow lane)

Resolve every lifecycle helper **before entering Steps 0b–10**, not before Step 0: classification needs only the stop-state helpers resolved in 0.2, and a resume that just routes to `/pause-resume` must not be blocked by a missing merge-gate helper it will never call. Inside the workflow lane a missing helper blocks rather than guessing which completed state is safe.

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
PR_AUTHORSHIP_SH=$(resolve_script pr-authorship.sh || true)
DIFF_SURVIVAL_SH=$(resolve_script diff-survival-check.sh || true)
REVIEWER_OF_SH=$(resolve_script reviewer-of.sh || true)
PR_STATE_SH=$(resolve_script pr-state.sh || true)
REPLY_THREAD_SH=$(resolve_script reply-thread.sh || true)
RESOLVE_REVIEW_THREADS_SH=$(resolve_script resolve-review-threads.sh || true)
MERGE_GATE_SH=$(resolve_script merge-gate.sh || true)
CLEAN_BEHIND_SH=$(resolve_script clean-behind-check.sh || true)
AC_CHECKBOXES_SH=$(resolve_script ac-checkboxes.sh || true)
[[ -n "$PR_AUTHORSHIP_SH" ]] || { echo "ERROR: pr-authorship.sh not found (checked all three paths) — resume authorship gate unavailable" >&2; exit 1; }
[[ -n "$DIFF_SURVIVAL_SH" ]] || { echo "ERROR: diff-survival-check.sh not found (checked all three paths) — rebase survival gate unavailable" >&2; exit 1; }
[[ -n "$REVIEWER_OF_SH" ]] || { echo "ERROR: reviewer-of.sh not found (checked all three paths) — reviewer routing unavailable" >&2; exit 1; }
[[ -n "$PR_STATE_SH" ]] || { echo "ERROR: pr-state.sh not found (checked all three paths) — PR state unavailable" >&2; exit 1; }
[[ -n "$REPLY_THREAD_SH" ]] || { echo "ERROR: reply-thread.sh not found (checked all three paths) — review replies unavailable" >&2; exit 1; }
[[ -n "$RESOLVE_REVIEW_THREADS_SH" ]] || { echo "ERROR: resolve-review-threads.sh not found (checked all three paths) — thread resolution unavailable" >&2; exit 1; }
[[ -n "$MERGE_GATE_SH" ]] || { echo "ERROR: merge-gate.sh not found (checked all three paths) — merge gate unavailable" >&2; exit 1; }
[[ -n "$CLEAN_BEHIND_SH" ]] || { echo "ERROR: clean-behind-check.sh not found (checked all three paths) — clean-BEHIND verification unavailable" >&2; exit 1; }
[[ -n "$AC_CHECKBOXES_SH" ]] || { echo "ERROR: ac-checkboxes.sh not found (checked all three paths) — acceptance verification unavailable" >&2; exit 1; }
```

Walk through the full review lifecycle checklist in order. At each step, check if it's already been completed. Stop at the first incomplete step and execute it, then continue to the next step. Keep going until the workflow is complete or a blocking condition is hit.

**Output a status line at each step** so the user can follow along:
- `[DONE]` — step already completed, moving on
- `[ACTION]` — step incomplete, executing now
- `[BLOCKED]` — step cannot proceed, reporting why
- `[SKIP]` — step not applicable

---

## Step 0: Classify the stoppage (universal resume)

Every stoppage leaves evidence. Read it, decide which class this is, and continue from the right place — the user never names the stoppage class. `/pause-resume` and `/end-resume` keep working and still own their restores; this step **routes into them** rather than reimplementing them (the "delegation, not reimplementation" rule in `/pause-resume` §Safety).

Evidence sources, the precedence table, the newest-wins tie-break, and the degradation contract: `.claude/reference/universal-resume.md`.

### 0.1 Parse arguments

- `--resume-refill` — forwarded **verbatim** to the delegated resume command. `/go-on` never writes `refill.paused` itself. Without the flag the refill pause stands on every lane and is reported, and on a lane with no planned-stop record the flag is reported as having had no effect (naming the command that clears it) — never acted on directly.
- `--again` — ignore the resume receipt in 0.5 and re-evaluate from scratch.

### 0.2 Resolve the stop-state helpers

These read cross-session stop records, so they resolve from installed locations **only** — no current-checkout fallback, matching `/pause-resume` and `/end-resume` Step 0. `/go-on` may be invoked from an unrelated or untrusted checkout, whose executable bit is not a trust signal.

```bash
resolve_installed() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_installed session-state.sh) || SESSION_STATE_SH=""
EXECUTION_PAUSE_SH=$(resolve_installed execution-pause.sh) || EXECUTION_PAUSE_SH=""
TASK_REGISTRY_SH=$(resolve_installed background-task-registry.sh) || TASK_REGISTRY_SH=""
HANDOFF_STATE_SH=$(resolve_installed handoff-state.sh) || HANDOFF_STATE_SH=""

SESSION_ID="${CLAUDE_SESSION_ID:-default}"
REPO_KEY=""
if [[ -n "$SESSION_STATE_SH" ]]; then
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
  # `_unknown` is the reserved no-repo-context bucket, not this repo's key —
  # probing it would read another checkout's leftovers as our own evidence.
  [[ "$REPO_KEY" == "_unknown" ]] && REPO_KEY=""
fi
```

**An unresolved helper never reads as "no evidence".** Print `DEGRADED: <name> not found (checked both installed paths) — <class> detection unavailable, continuing without it` — both, not three, because the checkout candidate is deliberately excluded above — and carry that gap into the verdict: a class that could not be probed is *unknown*, not *absent*. With `session-state.sh` unresolved, only the on-disk marker and handoff-note globs remain; if those are also empty the verdict is **unclassifiable** (0.4), never "nothing to resume".

### 0.3 Probe the evidence

Run every probe — classification needs the full picture, not the first hit.

**A — planned-stop gate** (repo-scoped, outlives the session that armed it; the authority for newest-wins):

```bash
GATE_JSON='{}'
GATE_STATE=unreadable            # unreadable | absent | present — never default to absent
if [[ -z "$SESSION_STATE_SH" || -z "$REPO_KEY" ]]; then
  GATE_STATE=unreadable          # helper or repo identity missing: cannot rule the class out
else
  PAUSES=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].execution_pauses" 2>/dev/null)
  READ_RC=$?
  if (( READ_RC == 3 )); then
    GATE_STATE=absent            # exit 3 is "no state file" — genuinely nothing recorded
  elif (( READ_RC != 0 )); then
    GATE_STATE=unreadable        # 4/5/anything else: a read that failed, not an empty map
  elif GATE_JSON=$(jq -ce '
      if type != "object" and type != "null" then error("not a map") else . end
      | (. // {}) | to_entries
      | map(select(.value.active == true and (.value.cleared_at // null) == null))
      # An active record must be self-describing: a known command and a UTC Z
      # stamp. Anything else is unorderable evidence, not an absent gate.
      | if any(.value.command != "end" and .value.command != "pause")
             or any((.value.at // "") | test("^[0-9]{4}(-[0-9]{2}){2}T([0-9]{2}:){2}[0-9]{2}Z$") | not)
        then error("invalid active gate record") else . end
      | sort_by(.value.at) | last
      | if . == null then {}
        else {class: .value.command, at: .value.at, session: .key} end
    ' <<<"${PAUSES:-null}"); then
    # `jq -e` exits 1 only on a `null`/`false` result; every success path here
    # emits an object, so exit 0 means "read and validated", not "non-empty".
    if [[ "$GATE_JSON" == '{}' ]]; then GATE_STATE=absent; else GATE_STATE=present; fi
  else
    GATE_JSON='{}'; GATE_STATE=unreadable   # malformed map or invalid active record
  fi
fi
GATE_CLASS=$(jq -r '.class // ""' <<<"$GATE_JSON")   # end | pause | "" (absent/unreadable)
GATE_AT=$(jq -r '.at // ""' <<<"$GATE_JSON")
```

`GATE_STATE=unreadable` is **unclassifiable evidence, not an absent gate** — it blocks ranks 2, 3, and 4 outright (0.4). Resuming an `unplanned` or `token_exhaustion` lane while a planned stop may be armed is the exact mistake the ladder exists to prevent: the gate would block every successor launch, and the parked board would go unread. Rank 2 is barred for the same reason as ranks 3 and 4 and on the same evidence — continuing a recorded phase is a resume like any other, and a token-exhaustion handoff is not evidence that no `pause` or `end` gate is armed. Only `GATE_STATE=absent` — an unambiguous "no record" — lets the ladder fall through.

Also read this session's own gate — it decides whether new launches are blocked right now. The helper prints `active` | `inactive` and exits 0; an unresolved helper or a failed call is `unreadable`, which feeds the unclassifiable rule in 0.4, never `inactive`:

```bash
GATE_LIVE=unreadable
if [[ -n "$EXECUTION_PAUSE_SH" ]]; then
  GATE_LIVE=$("$EXECUTION_PAUSE_SH" --status --session "$SESSION_ID" 2>/dev/null) || GATE_LIVE=unreadable
  [[ "$GATE_LIVE" == active || "$GATE_LIVE" == inactive ]] || GATE_LIVE=unreadable
fi
```

**B — parked `/pause` record:** `.repos["$REPO_KEY"].pause` (legacy pre-#1310 `.suspend`), classified as pause evidence when `active == true`; its timestamp is `paused_at` (legacy `suspended_at`). If the state read fails, the existence of any `~/.claude/handoffs/pause-*.md` or `suspend-*.md` is a pause **candidate** — `/pause-resume` Step 1 owns marker selection and fails closed with `No parked session found` when the marker belongs to another repo, so a false candidate costs a no-op, never a wrong restore.

**C — `/end` record:** the canonical note for this repo, `~/.claude/handoffs/portable-handoff-<owner>-<repo>-*.md` with the repo key lowercased and `/` replaced by `-`, **excluding** `*-checkpoint.md` (those are automatic checkpoints, which stop nothing — probe E). Corroborating: `refill == {paused: true, reason: "full_stop"}`, which both `/end` and `/pause` write and which therefore never discriminates between them on its own.

**D — token-exhaustion handoff:** any `.repos["$REPO_KEY"].prs[*]` entry with `handoff_reason == "token_exhaustion"` (schema: `session-state-schema.json` `_token_exhaustion_example`), carrying `phase`, `needs`, `head_sha`, and `remaining_work`. Corroborate against the scoped handoff file (`"$HANDOFF_STATE_SH" --owner-repo <owner>/<repo> --get <N>`).

**E — unplanned interruption** (crash, compaction, sign-out — no planned-stop record at all): any of a registry entry still `running`/`stopping`/`stop_failed` (`"$TASK_REGISTRY_SH" --list --live`), a `.repos["$REPO_KEY"].prs` entry, a scoped handoff file for this branch's PR, a `*-checkpoint.md` note for this repo, an in-progress rebase, or a feature branch with uncommitted/unpushed work or an open PR.

### 0.4 Precedence — first match wins

| Rank | Class | Fires on | Resume action |
|---|---|---|---|
| 1 | `pause` / `end` | A `present`; or A `absent` with exactly one of B / C | Delegate: `/pause-resume [--resume-refill]` or `/end-resume [--resume-refill]` |
| 2 | `token_exhaustion` | D, **and** every planned-stop probe readable | Continue the recorded phase (0.6) |
| 3 | `unplanned` | E only, **and** every planned-stop probe readable | Steps 0b–10 below |
| 4 | `none` | nothing, and every probe readable | Report `nothing to resume`; change no state |

**Explicit parked state outranks generic stall detection.** A readable planned-stop record wins over in-flight-looking branch state every time: rank 3 is reached only when ranks 1–2 found nothing. A planned stop also outranks rank 2 because its gates are armed, and only `/pause-resume` / `/end-resume` may clear them (`phase-protocols.md` §"Launch gate before every successor").

**`pause` vs `end` — newest wins, decided by probe A.** Each activation writes `command` + `at` in the same UTC `Z` format, so the newest active entry names the class. Corroborating records (B, C) settle it only when A is missing or unreadable, and cannot order two classes against each other — their timestamps are not comparable (one ISO string, one file mtime).

**Unclassifiable → report, never guess** (`[BLOCKED]`, no state change, no launch). Print what was found, then offer the resolution paths as a menu (`ask-menu.md`; prose fallback when headless). The cases:
- `GATE_STATE=unreadable` — the planned-stop record could not be read or carries an active entry with an unknown `command` or a non-UTC-`Z` `at`. A `pause` or `end` may be armed, so ranks 2, 3, and 4 are all barred — including rank 2 even when a token-exhaustion handoff (D) is present and readable.
- B and C both present, A `absent` or unreadable — two planned stops that cannot be ordered. Options: `/pause-resume`, `/end-resume`.
- This session's gate is `active` — or `GATE_LIVE=unreadable` — and no class is readable from A, B, or C.
- A probe could not be *read* (0.2) and its class cannot be ruled out.
- A `pause` record says `active: true` but `/pause-resume` reports no state and no marker.
- More than one token-exhaustion entry (D) and none matches the current branch's PR — name every PR found.

### 0.5 Resume receipt — never resume the same stoppage twice

Read `.repos["$REPO_KEY"].resume` before dispatching. Build the evidence digest `class|record_at|pr|head_sha|branch`. If it equals the receipt's `evidence_digest` and `--again` was not passed:

```
[DONE] nothing to resume — the <class> stoppage recorded at <record_at> was already
       resumed at <receipt .at> via <receipt .dispatched_to>. Re-run with --again
       to force a pass.
```

`<receipt .at>` is the receipt's `at` field — when the previous resume ran, not when the stoppage was recorded. Arm nothing, launch nothing, write nothing. After a **successful** dispatch (ranks 1–3 only), write the receipt in one call:

```bash
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].resume=$RESUME_JSON"
```

`RESUME_JSON` is `{class, evidence_digest, at, session_id, dispatched_to}`, where `at` is now. Rank 4 writes nothing at all — "nothing to resume" is a read-only verdict.

### 0.6 Dispatch

**Never duplicate a live task or Monitor.** Before any lane, list live registry entries (`"$TASK_REGISTRY_SH" --list --live`) and read `.prs["<N>"].babysit.active`. Work already covered by a live identity is reported, not relaunched; the delegated commands take the locked `stopped -> rearming` claim that makes concurrent resumes single-writer.

An unresolved `background-task-registry.sh` or a failed listing is an **unreadable inventory, never an empty one** (the same rule `/pause` Step 0 applies): say the live-task check could not run, and do not launch anything in the `unplanned` or `token_exhaustion` lanes on the assumption nothing is running. Delegation to `/pause-resume` / `/end-resume` still proceeds — their own claims are locked, so they cannot double-launch on a blind check.

- **`pause` / `end`** — invoke `/pause-resume` or `/end-resume`, forwarding `--resume-refill` when given. They clear the execution gate, re-arm stopped work, and own the refill decision. Report their outcome; do not re-run their steps here.
- **`token_exhaustion`** — read the entry's `phase`, `head_sha`, and `remaining_work`, then continue that phase: enter Steps 0b–10 at the step its `needs` names (`continue_polling` → Step 6, unpushed fixes → Step 1b). The parent's replacement-subagent path (`phase-protocols.md`) is unchanged and still preferred when a parent orchestrator is live — say so rather than racing it.
- **`unplanned`** — continue to Step 0b. This is the original `/go-on` behavior, unchanged.
- **Monitors and artifact watches that died with the session are not re-armed here.** They belong to their owning skills' recovery paths (`/babysit-pr`, `/pr-monitor-and-manage-wake`, `/pm day resume`, `monitor-mode.md` §PM Monitoring Recovery) — the same ones `/pause-resume` Step 5 delegates to. Name what was found and which command owns it.

---

## Step 0b: Identify context

Reached only from Step 0's `unplanned` or `token_exhaustion` dispatch — the interrupted-review-workflow lane.

```bash
BRANCH=$(git branch --show-current)
echo "Branch: $BRANCH"
```

If on `main`, stop: `nothing to resume — on main, no interrupted workflow for this checkout` (rank 4; change no state).

Check if a PR exists:
```bash
gh pr view --json number,title,headRefName,state 2>/dev/null
```

Determine the {owner}/{repo} from git remote:
```bash
gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"'
```

> **Authorship guard (issue #733, `safety.md`).** `/go-on` resumes a write workflow (push, review triggers, thread resolution, merge). Confirm you authored the PR before resuming any write step:
> ```bash
> PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null)
> [ -n "$PR_NUM" ] && "$PR_AUTHORSHIP_SH" "$PR_NUM"   # exit 0 = yours
> ```
> Not yours (exit 1) or undetermined (exit 4) → `[BLOCKED]`: "PR #$PR_NUM is not yours — the authorship guard blocks automated writes; name it explicitly to override." Proceed only under an explicit per-PR user override (say you are operating under it). Read-only status inspection is fine.

---

## Step 1: Check for an inherited rebase / conflict resolution (issue #757)

**Run this before Step 1b and before any commit or push.** The incident that motivated this guard was exactly a resumed session: an interrupted rebase left a resolution with no conflict markers that was nonetheless byte-identical to main — the whole fix the PR existed to deliver had been silently dropped, and every other gate (clean status, green CI, review) passed it.

```bash
GUARD="$DIFF_SURVIVAL_SH"
REBASE_IN_PROGRESS=0
{ [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; } && REBASE_IN_PROGRESS=1
SNAPSHOT_PRESENT=$("$GUARD" status --json | jq -r '.present')
```

- **Neither** a rebase in progress nor a snapshot on disk → `[SKIP]` — no inherited resolution to verify. Go to Step 1b.
- **Otherwise** (mid-rebase, or a snapshot left by a just-completed rebase) → `[ACTION]`:

  ```bash
  "$GUARD" snapshot --if-absent   # mid-rebase this reconstructs from orig-head, not the half-replayed HEAD
  "$GUARD" verify; GUARD_RC=$?
  ```

  - `0` — `[DONE]` diff survived the resolution; continue. (`deferred` also exits 0: commits are still queued for replay — finish the rebase, then re-run before pushing.)
  - `1` — `[BLOCKED]` the branch's entire diff vanished. Report the guard's output verbatim, including its one legitimate case (main independently landed the identical change → **close the PR**, never force-push an empty branch). Do not commit, push, or "fix" anything.
  - `2` — `[BLOCKED]` name the files that lost their changes and stop. This is an **unresolved conflict**, not a resumable state — re-resolve those files (whitespace-only survival still counts as lost), then re-run.
  - `4` — two shapes, both stop-and-report:
    - `unresolved_conflicts` → `[ACTION]` finish the resolution (optionally via `/merge-conflict`), then re-run `verify` before continuing.
    - `unverifiable` → `[BLOCKED]` the snapshot's baseline commit *is* the commit being checked, so it proves nothing. This is what a **just-completed** rebase with no snapshot looks like: a baseline cannot be reconstructed after the fact (`--if-absent` only reconstructs from `orig-head` while the rebase is still in progress). Say plainly that the resolution **cannot be verified**, and let the user decide — never report it as clean.
  - `5` — no snapshot could be established at all → `[BLOCKED]`: same handling as `unverifiable`. Never proceed silently on an unverifiable resolution.

  The guard never repairs; `git rebase --abort` or resetting to `ORIG_HEAD` stays the user's call. After a verified push completes, `"$GUARD" clear` retires the snapshot.

---

## Step 1b: Check for uncommitted changes

```bash
git status --porcelain
```

- If there are uncommitted changes: `[ACTION]` — Stage and commit changes. Ask the user for a commit message if the changes are ambiguous, otherwise use a descriptive message based on the diff.
- If clean: `[DONE]` — No uncommitted changes.

---

## Step 2: Run local CR review

Find the `coderabbit` CLI:
```bash
CR_BIN=$(which coderabbit 2>/dev/null || echo ~/.local/bin/coderabbit)
test -x "$CR_BIN" && echo "Found: $CR_BIN" || echo "Not found"
```

If available, run the local review loop:
```bash
$CR_BIN review --agent
```

- If findings are returned: `[ACTION]` — Fix all valid findings. Run `$CR_BIN review --agent` again after fixing.
- **Exit on 1 clean pass** (no findings returned) — `[DONE]` Local CR review passed.
- **Max 5 total iterations.** If you hit 5 runs without a clean pass, stop and report: `[BLOCKED]` — CR review not converging after 5 iterations.
- If CR CLI is not available or errors out: `[SKIP]` — CR CLI unavailable, performing self-review instead:
  ```bash
  BASE=$(gh pr view --json baseRefName --jq '.baseRefName' 2>/dev/null || echo main)
  git diff "$BASE"...HEAD
  ```
- **After the local review loop completes**, classify and print coverage: `[COVERAGE] <level> — <reason>` (per `cr-local-review.md` "Coverage classification": `both | cr-only | codeant-only | none`). This flow reaches at most `cr-only` or `none`. For `none`, the line is mandatory before any push.

---

## Step 3: Push to remote

First refresh remote refs and check if the remote branch exists:
```bash
git fetch origin "$BRANCH" --quiet 2>/dev/null || true
git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1
```

- If the remote branch **does not exist**: `[ACTION]` — Pushing new branch:
  ```bash
  git push -u origin $BRANCH
  ```
- If the remote branch **exists**, check for unpushed commits:
  ```bash
  UNPUSHED=$(git log --oneline origin/$BRANCH..$BRANCH | wc -l | tr -d ' ')
  ```
  - If `UNPUSHED > 0`: `[ACTION]` — Pushing $UNPUSHED commits.
    ```bash
    git push origin $BRANCH
    ```
  - If `UNPUSHED == 0`: `[DONE]` — Branch is up to date with remote.

---

## Step 4: Ensure PR exists

```bash
PR_JSON=$(gh pr view --json number,title,body,state 2>/dev/null)
PR_NUM=$(printf '%s' "$PR_JSON" | jq -r '.number // empty')
```

Pipe with `printf '%s'`, never `echo` — zsh's builtin `echo` interprets the escape sequences in the PR body and corrupts the JSON, so `jq` errors and `PR_NUM` comes back empty, which reads as "no PR exists" (issue #574).

- If a PR exists and is open: `[DONE]` — PR #$PR_NUM exists. Additionally, always update the `**Local review coverage:**` line in the PR body: if coverage is `both`, remove any existing label (clearing stale degraded markers from prior runs); if coverage is degraded, replace the line if present or append it if missing. Fetch the PR body, apply the change, then `gh pr edit "$PR_NUM" --body "$UPDATED_BODY"`.
- If no PR exists: `[ACTION]` — Create one.
  - Look for an issue number from the branch name (pattern: `issue-N-*`):
    ```bash
    ISSUE_NUM=$(echo "$BRANCH" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+')
    ```
  - If `ISSUE_NUM` is empty (branch doesn't follow `issue-N-*` pattern): create the PR without a `Closes #N` footer. Note to user: "No linked issue detected from branch name."
  - If `ISSUE_NUM` is set: read the issue body for context:
    ```bash
    gh issue view $ISSUE_NUM --json title,body 2>/dev/null
    ```
  - Create the PR with a proper body (including `Closes #N` if issue was found) and a Test plan section. Include a `**Local review coverage:** <level>` labeled line when coverage is anything other than `both` (mandatory for `none` and single-CLI cases). After creation, capture the PR number:
    ```bash
    PR_NUM=$(gh pr view --json number --jq '.number')
    ```
- If the PR is merged: `[DONE]` — PR is already merged. Nothing to continue.
- If the PR is closed but not merged: `[BLOCKED]` — PR was closed without merging. It may need to be reopened or a new PR created.

---

## Step 5: Determine reviewer ownership

Resolve reviewer ownership via the shared helper (reads `.prs["<N>"].reviewer` from `~/.claude/session-state.json` first, falls back to a paginated live-history scan on all three comment endpoints):

```bash
REVIEWER=$("$REVIEWER_OF_SH" "$PR_NUM")
REVIEWER_EXIT=$?
```

Branch on exit code:
- `0` → `$REVIEWER` is one of `cr` / `bugbot` / `greptile`. Use it for Step 6.
- `1` → `unknown` printed; no bot has reviewed yet. Treat as **CR** (the default primary reviewer) and proceed to Step 6 to wait for the first review.
- `2` → `[BLOCKED]` — script/gh error; surface stderr.
- `3` → `[BLOCKED]` — PR #$PR_NUM not found (closed, merged, or invalid).
- `5` → `[BLOCKED]` — `~/.claude/session-state.json` is malformed, wrong shape, or the helper hit a runtime failure (e.g. a racing read between the validation guard and the jq lookup). Surface the helper's stderr, stop polling, and repair or remove the state file before retrying `/go-on`. Do **not** fall through to a live-history scan — sticky reviewer assignments live in session-state, and bypassing them risks mis-routing an already-escalated PR back to CR.

Output: `Reviewer: CR` / `Reviewer: BugBot` / `Reviewer: Greptile`.

---

## Step 6: Check for review response

> **pr-state.sh first (NON-NEGOTIABLE):** Before calling `gh api .../pulls/{N}/reviews`, `pulls/{N}/comments`, or `issues/{N}/comments` directly, call `pr-state.sh --pr N` first and read the cached JSON bundle. The inline `gh api` calls below are legacy check-run and rate-limit spot-checks retained because they target commit-level endpoints (`/commits/{SHA}/check-runs`, `/commits/{SHA}/statuses`) not covered by `pr-state.sh`. For review, inline comment, and conversation endpoint lookups, use `pr-state.sh` exclusively.

### If PR is on CR:

Check the commit status for CodeRabbit:
```bash
SHA=$(gh pr view $PR_NUM --json commits --jq '.commits[-1].oid')
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "CodeRabbit") | {status: .status, conclusion: .conclusion, title: .output.title}'
```

Also check the statuses endpoint as fallback:
```bash
gh api "repos/{owner}/{repo}/commits/$SHA/statuses" \
  --jq '.[] | select(.context | test("CodeRabbit"; "i")) | {state: .state, description: .description}'
```

**Rate limit detection:** If check-run shows `conclusion: "failure"` with title containing "rate limit" (case-insensitive), OR status shows `description` containing "rate limit" — CodeRabbit reports this status as non-blocking `state: "success"`, so do not gate on `state`:
- `[ACTION]` — CR is rate-limited. Check BugBot (second-tier reviewer) before falling through to Greptile — BugBot auto-triggers on every push, so it may already have responded while CR was blocked:
  ```bash
  gh api "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" \
    --jq '[.[] | select(.user.login == "cursor[bot]" and .commit_id == "'"$SHA"'")]'
  ```
  - BugBot has posted on `$SHA` → PR is now on **BugBot** (sticky). Persist and go to the BugBot section:
    ```bash
    "$REVIEWER_OF_SH" "$PR_NUM" --sticky bugbot
    ```
  - BugBot has NOT posted AND <10 min since push → `[ACTION]` — Waiting up to 10 min for BugBot's auto-review. Poll every 60 s.
  - BugBot has NOT posted AND ≥10 min since push → BugBot timed out. Fall through to Greptile:
    ```bash
    gh pr comment "$PR_NUM" --body "@greptileai"
    "$REVIEWER_OF_SH" "$PR_NUM" --sticky greptile
    ```
    Go to the Greptile section below.

**Review completion:** If check-run shows `status: "completed"` with `conclusion: "success"`:
- CR has finished reviewing. Check for findings (Step 7).

**Review pending:** If no completion signal and no rate-limit signal:
- `[ACTION]` — CR review is still pending. Polling every 60 seconds (12-minute timeout). A clean CR check-run completion short-circuits the timeout wait — but the merge gate still requires an explicit `APPROVED` review on the current HEAD SHA (per `cr-merge-gate.md` Step 1); completion alone does not satisfy it.
- Poll all 3 endpoints each cycle for new comments from `coderabbitai[bot]`.
- Check for rate-limit signals on every poll cycle. Rate-limit signals override the timeout — escalate immediately regardless of elapsed minutes.
- After 12 minutes with no review content and no rate-limit signal: `[ACTION]` — CR timed out. Check BugBot (same query as rate-limit path above). If BugBot has posted a review, persist `--sticky bugbot` and go to the BugBot section. If BugBot has also timed out (≥10 min since push), fall through to Greptile.

### If PR is on BugBot:

BugBot (`cursor[bot]`) is the second-tier free reviewer. Auto-triggers on every push; merge gate requires **1 clean BugBot review** on the current HEAD SHA (BugBot's completion signals are reliable).

Check for BugBot reviews on the current HEAD:
```bash
gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]" and .commit_id == "'"$SHA"'")]'
gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUM/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]")]'
gh api --paginate "repos/{owner}/{repo}/issues/$PR_NUM/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "cursor[bot]")]'
```

Also check the BugBot check-run for the completion signal:
```bash
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "Cursor Bugbot") | {status, conclusion}'
```

- BugBot has posted findings on `$SHA` → `[DONE]` — BugBot review received. Process findings (Step 7). After fixes are pushed, BugBot auto-reviews the new push; return to this section on the new SHA.
- BugBot has posted a clean review (check-run `completed` with no finding comments) on `$SHA` → `[DONE]` — merge gate met (1 clean pass is sufficient for the BugBot path). Proceed to merge verification.
- No BugBot response AND <10 min since push → `[ACTION]` — Polling for BugBot (10-min timeout from push). Poll every 60 s.
- No BugBot response AND ≥10 min since push → BugBot timed out. Fall through to Greptile immediately (after the Greptile budget gate). Do NOT extend the wait by triggering a manual `@cursor review` retry — the 10-min window from push is the hard timeout.
- Stay on BugBot — do not switch back to CR. Ignore late CR reviews. Only escalate to Greptile if BugBot also fails.

### If PR is on Greptile:

Check for Greptile comments:
```bash
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api --paginate "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
gh api --paginate "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "greptile-apps[bot]")]'
```

- If Greptile has posted findings: `[DONE]` — Greptile review received. Process findings (Step 7).
- If no Greptile response: `[ACTION]` — Polling for Greptile (10-minute timeout). Polling cadence stays 60 s; exit immediately when the review lands, do not keep polling to 10 min.
  - If no response after 10 minutes: `[BLOCKED]` — Greptile timed out. Performing self-review as fallback. Note: self-review does NOT satisfy merge gate.

---

## Step 7: Check for unresolved findings

Fetch unresolved review threads (first 100 — sufficient for most PRs; if a PR has >100 threads, paginate using `pageInfo.endCursor`):
```bash
gh api graphql -f query='query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {N}) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
            nodes {
              body
              author { login }
              createdAt
            }
          }
        }
      }
    }
  }
}'
```

Count unresolved threads from reviewers:
- Filter for threads where any comment is from `coderabbitai[bot]`, `greptile-apps[bot]`, or `cursor[bot]`
- Only count threads where `isResolved == false`

Also check for issue-level review comments that may not have threads. Use the shared `pr-state.sh` helper — it fetches all three endpoints in one call, filters to `coderabbitai[bot]` / `greptile-apps[bot]` / `cursor[bot]` (BugBot), and pre-classifies each comment with `classification.class` (`finding` vs `acknowledgment`). The classifier only runs when `--since <iso>` is passed — pass the PR's `createdAt` to include every bot comment on the PR. The helper writes the JSON bundle to a tempfile and prints its **path** on stdout — capture the path, then read with `jq < "$BUNDLE"`:

```bash
PR_CREATED=$(gh pr view "$PR_NUM" --json createdAt --jq '.createdAt')
BUNDLE=$("$PR_STATE_SH" --pr "$PR_NUM" --since "$PR_CREATED")
jq '.new_since_baseline.conversation | map(select(.classification.class == "finding"))' < "$BUNDLE"
```

- If there are unresolved findings: `[ACTION]` — Processing N unresolved findings.
  1. Read each finding carefully
  2. Verify against actual code before fixing
  3. Fix ALL valid findings in a single commit
  4. Push once
  5. Reply to every thread confirming the fix. Use the shared helper — it tries the inline `/replies` endpoint first, falls back to a PR-level comment on 404, and applies reviewer-specific `@mention` rules (prepends `@coderabbitai` for CR; strips `@cursor`/`@greptileai` for BugBot/Greptile):

     ```bash
     # $REVIEWER: cr | bugbot | greptile (determined from the finding's author)
     "$REPLY_THREAD_SH" <comment_id> --reviewer "$REVIEWER" \
       --body "Fixed in \`$SHA\`: <what changed>" --pr N
     ```

     Exit code `0` means the reply posted (by either the inline endpoint or the PR-level fallback); the fallback path also emits a note to stderr. Non-zero means a genuine failure to post. See `reply-thread.sh --help` for the full contract, including PR-number-unresolvable-without-`--pr` or both-endpoints-404 (exit 3) and inline-404-then-fallback-non-404 (exit 4).

  6. Resolve all bot threads with the shared helper (paginated, filtered to `coderabbitai`/`cursor`/`greptile-apps`, falls back to `minimizeComment` on failure):

     ```bash
     "$RESOLVE_REVIEW_THREADS_SH" "$PR_NUM"
     ```

     Exit 1 means at least one thread failed both mutations — surface to the user and stop. Do not proceed with a non-zero exit.

  7. After fixing, go back to **Step 6** to wait for the next review.
- If no unresolved findings: `[DONE]` — No unresolved findings.

---

## Step 8: Check merge gate

Run the shared merge-gate verifier (implements CR 1 explicit APPROVED on current HEAD / BugBot 1-clean / Greptile severity + CI + BEHIND checks):

```bash
GATE_JSON=$("$MERGE_GATE_SH" "$PR_NUM")
GATE_EXIT=$?
```

Branch on the exit code:

- `0` → `[DONE]` — Merge gate satisfied. Proceed to Step 9 (AC verification).
- `1` → `[ACTION]` — Gate not met. Parse `missing` from the JSON output and act accordingly:
  - CR path with **"need 1 explicit CR APPROVED review on HEAD"**: if the current SHA is still within the 12-minute CR polling window, return to **Step 6** and keep polling — do NOT re-trigger yet. Only after the 12-minute timeout, and only within the 2-trigger-per-hour budget, post `@coderabbitai full review` once and return to **Step 6**.
  - CR path with **"CR approval on HEAD ... retracted by later CHANGES_REQUESTED"**: CR retracted approval. Return to **Step 7** to process the findings. Re-trigger only after fixes are pushed (the new SHA invalidates prior reviews regardless).
  - CR path with **"CodeRabbit check-run not green on HEAD"** or **"latest CR review on HEAD requests changes"**: CR has findings; return to **Step 7** to process them.
  - BugBot path with **"no BugBot review on HEAD"**: BugBot hasn't reviewed the current HEAD yet; return to **Step 6** to poll for the review.
  - BugBot path with **"latest BugBot review on HEAD has findings"**: return to **Step 7** to process findings.
  - Greptile path with **"unresolved Greptile thread(s)"**: return to **Step 7** to process; if P0 remains after fix, re-trigger `@greptileai` (subject to the 3-review cap per `.claude/rules/greptile.md`).
  - **"branch is BEHIND base"**: **probe before prescribing anything** (issue #1564). A *verified clean* `BEHIND` is an auto-merge, not a rebase — canonical in `.claude/rules/cr-merge-gate.md` Step 1d and `CLAUDE.md` "PR MERGE AUTHORIZATION" (issue #754), and encoded the same way in `.claude/agents/phase-c-merger.md` (issue #1563) and `fixpr/SKILL.md` Step 6. Rebasing a clean `BEHIND` moves HEAD, discarding the bot approval that had already satisfied the rest of the gate and restarting CI — the treadmill the carve-out exists to avoid.

    ```bash
    # `|| CB_EXIT=$?`, not a bare assignment: exit 1 is the EXPECTED pre-tick
    # result here, and under `set -e` a bare assignment would abort the block
    # before the status was ever captured.
    CB_EXIT=0
    if [[ -n "$REVIEWER" ]]; then
      CB_JSON=$("$CLEAN_BEHIND_SH" "$PR_NUM" --reviewer "$REVIEWER") || CB_EXIT=$?
    else
      CB_JSON=$("$CLEAN_BEHIND_SH" "$PR_NUM") || CB_EXIT=$?
    fi
    ```

    Read the JSON, never `$?` after a pipe. Branch on `CB_EXIT`:
    - `0` (`safe_to_offer: true`) → `[ACTION]` — **verified clean `BEHIND`.** No snapshot, no rebase, no force-push. Set `CLEAN_BEHIND=1` and continue to **Step 9**: this path is **AC-first**, Step 9a finishes the verification, and Step 10 hands the merge to `/wrap`.
    - `1` whose `reasons_not_safe` / `residual_blockers` are **only** the unchecked-Test-Plan-checkbox count and/or a sole `ac-gate` check-run — **failing *or* still incomplete** — → `[ACTION]` — **clean-`BEHIND` candidate**, i.e. "waiting on Step 9", not a blocker. `clean-behind-check.sh` counts unticked boxes as `reasons_not_safe`, so a pre-tick exit `1` is bookkeeping rather than a real blocker. Treat exactly as `0`: set `CLEAN_BEHIND=1`, continue to Step 9.
    - `1` with **any other** residual blocker → genuinely non-clean `BEHIND`. Surface `reasons_not_safe`, then `[ACTION]` — `diff-survival-check.sh snapshot`, rebase onto base, then `diff-survival-check.sh verify` (Step 1 branch table) and force-push **only** on exit 0; wait for a fresh review, then re-run the gate.
    - `2`/`3`/`4` → `[BLOCKED]` — usage error / PR not found or not open / `gh`-network-jq error. Surface the JSON or stderr. Nothing was reported *about this `BEHIND`*, so it is neither clean nor unclean — **never** read a non-`1` failure as a rebase signal, which would buy a rebase on evidence you do not have.

    `churn.advisory` is context, never a gate.
  - **"CI has N failing check-run(s)"** or **"CI has N incomplete check-run(s)"**: fix CI or wait for incomplete runs, then re-run the gate.
- `3` → `[BLOCKED]` — PR not found (closed or merged).
- `2`/`4` → `[BLOCKED]` — script or gh error; surface the message to the user.

---

## Step 9: Verify acceptance criteria

Run the acceptance criteria check via the shared helper:

```bash
ITEMS=$("$AC_CHECKBOXES_SH" "$PR_NUM" --extract)
AC_EXIT=$?
```

Branch on exit code:
- `0` → `$ITEMS` is a JSON array of `{index, checked, text}`. For each item with `checked == false`, read the relevant source files and verify the criterion. Tick passing items by index with `"$AC_CHECKBOXES_SH" "$PR_NUM" --tick "0,2,3"` (or `--all-pass` if every unchecked item passed).
- `1` → `[BLOCKED]` — PR body is missing a Test Plan section. Every PR must include one (per CLAUDE.md). The PR is NOT merge-ready until the body is fixed — report this to the user and do not continue to the merge decision.
- `3` → `[BLOCKED]` — PR not found.
- `2`/`4` → `[BLOCKED]` — script or gh error; surface stderr to user.

- If all items pass after ticking: `[DONE]` — All acceptance criteria verified and checked off.
- If any item fails: `[ACTION]` — Fix the failing criteria, then re-verify.

---

## Step 9a: Clean-`BEHIND` follow-through (candidates only)

`[SKIP]` unless Step 8 set `CLEAN_BEHIND=1`. Ticking AC has two after-effects; both must settle before Step 10, and they overlap, so run them in this order and wait once. Mirrors `.claude/agents/phase-c-merger.md` Step 2a (issue #1563).

1. **Re-run the failed `ac-gate` check.** `ac-gate.yml` triggers on `opened`/`synchronize`/`reopened`, so a PR-body edit never re-fires it — a red `ac-gate` on an unticked PR is by design and stays red until rerun. The id `merge-gate.sh` reports in `ci_status.blocking[].id` is a **job** id: `gh run rerun --job "$AC_GATE_JOB_ID"`. A rejected rerun (stale id, permissions, GitHub error) means `ac-gate` was never re-fired, so waiting would burn the whole deadline for nothing → `[BLOCKED]`, reporting the `gh` error and the job id, without entering the wait. An **empty** id is not a green light either — re-read the check-run on HEAD before continuing. The rerun publishes a **new** job id on the same run, so poll that one (or re-read the check-run by name from the HEAD SHA); the old id stays `failure` forever, so polling it would never terminate.
2. **Wait out the mergeability recompute.** `ac-checkboxes.sh --tick` / `--all-pass` PATCHes the PR body, and GitHub invalidates mergeability on any body write — the next gate read returns `merge_state: "UNKNOWN"` with the `BEHIND` entry **gone from `missing[]`**. That is not a new blocker and never a reason to rebase. Proceed only when **both** hold: the `ac-gate` check-run on HEAD has reached a terminal `status: "completed"` (any conclusion), **and** `gh pr view "$PR_NUM" --json mergeStateStatus` is no longer `UNKNOWN` (~30–60s). Advancing on mergeability alone hands item 3 a still-queued `ac-gate`, which `clean-behind-check.sh` reports as an *incomplete*-CI residual — read as a non-clean `BEHIND`, that triggers exactly the rebase this path exists to prevent. **Both waits share one 10-minute deadline** from the rerun; the deadline is a stop condition, never a licence to proceed with a condition unmet. Either still unmet at the deadline → `[BLOCKED]`, naming which one did not settle plus the job's URL and status: do **not** re-probe and do **not** rebase — an unsettled wait is not evidence the `BEHIND` is unclean. An `ac-gate` that completes with a **failing** conclusion is a real AC failure → back to Step 9, not a rerun loop.
3. **Re-probe.** Run `clean-behind-check.sh` again — same invocation *and the same exit-code table* as Step 8, so `2`/`3`/`4` block here too rather than being read as an unclean `BEHIND`. Exit `0` / `safe_to_offer: true` is the authorization Step 10 carries. A still-**incomplete** `ac-gate` in `residual_blockers` here means item 2's wait was left early — go back and finish it. Exit `1` once AC is ticked and `ac-gate` has completed **green** → the `BEHIND` genuinely is not clean: take the Step 8 non-clean rebase path.

---

## Step 10: Report completion

Output a summary:

```
=== /go-on complete ===

Stoppage: <pause | end | token_exhaustion | unplanned> (recorded <record_at>)
Branch: $BRANCH
PR: #$PR_NUM
Reviewer: CR / Greptile
Merge gate: MET / MET (clean BEHIND — cleared by /wrap Step 2.4) / NOT MET
Acceptance criteria: ALL PASSED / N FAILED
Refill: <still paused — clear with /go-on --resume-refill | cleared via <command> --resume-refill | not paused>
Status: Ready for wrap
```

A delegated lane (`pause` / `end`) reports the companion command's own board instead of this block, plus the `Stoppage:` and `Refill:` lines. Ranks 4 and unclassifiable report only what was found — no board, no status line, no state change.

If the merge gate is met and all AC pass, run `/wrap` immediately — no pre-merge prompt (`CLAUDE.md` "PR MERGE AUTHORIZATION"). Honor an explicit user opt-out ("don't merge" / "wait for my approval") if given in chat.

**A verified clean `BEHIND` counts as met for this hand-off (issue #1564).** `BEHIND` is cleared *by* the merge, so on that path the gate still reports exit `1` with the `BEHIND` entry present — the same loop-exit rule `/wrap` applies to itself (gate exit `1` with `BEHIND` as the sole `missing[]` item; issue #1425). When Step 9a's re-probe returned exit `0`, dispatch `/wrap` on that basis rather than reporting NOT MET. **`/wrap` Step 2.4 is the merge executor** — it runs `admin-merge.sh "$PR_NUM" --auto-plain --ac-verified` itself, with no `AskUserQuestion` (issue #754): the plain shape modifies no branch protection, so it needs no user turn. **Do not run `admin-merge.sh` from `/go-on`** — `--auto-plain` carries a repeat guard, so a call here would consume the one attempt and `/wrap`'s would then refuse with exit `8`, merging nothing. Step 2.4 owns that script's semantics; its exits map as: `0` → merged, relay the `AUTO_PLAIN_MERGED` evidence block; `8` → the shape needs a protection change (or an auto attempt already ran) → **surface `/admin-merge $PR_NUM` as a user choice and never auto-run it**; `1` → the clean state no longer held at merge time (main advanced) → Step 2.4's own rebase fall-through and recovery loop.
