---
name: end
description: Use when usage allowance is exhausted or running thin and this session must stop for hours or days while preserving resumable work. Blocks new launches, gives running work a bounded checkpoint window, stops every remaining owned background task, then writes a portable handoff. Triggers on "end", "clean end", "wind down", "portable handoff", "hand this to another agent", "I'm running low".
triggers:
  - end
  - clean end
  - wind down
  - portable handoff
  - hand off to another agent
argument-hint: "[--window Nm] (default: --window 5m; --window 0 stops immediately)"
---

Stop cleanly for a potentially long interruption, and leave behind a document
someone else can pick up.

**You decide when.** The usage view in the app is the authoritative source for what is left of your allowance, and you are the one reading it. This command never estimates tokens, spend, or remaining quota, and never refuses or defers work based on one — `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" holds as written. `/end` runs because you asked, and for no other reason.

Two outputs, in this order: a wind-down that leaves nothing half-finished, and a portable handoff document written to disk and printed in the thread.

## Step 0: Resolve helpers and parse the window

`/end` is invocable from any thread — including one whose working directory is not this repo, which is exactly the situation where a repo-relative path silently fails. Resolve each helper the same way the other shutdown-style commands do:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_script session-state.sh) || SESSION_STATE_SH=""
HANDOFF_LINT_SH=$(resolve_script portable-handoff-lint.sh) || HANDOFF_LINT_SH=""
EXECUTION_PAUSE_SH=$(resolve_script execution-pause.sh) || EXECUTION_PAUSE_SH=""
TASK_REGISTRY_SH=$(resolve_script background-task-registry.sh) || TASK_REGISTRY_SH=""
HANDOFF_CONTEXT_SH=$(resolve_script portable-handoff-context.sh) || HANDOFF_CONTEXT_SH=""
HANDOFF_PUBLISH_SH=$(resolve_script portable-handoff-publish.sh) || HANDOFF_PUBLISH_SH=""

# The collector is a document, not a script, so resolve it the same way but
# test for readability rather than the executable bit.
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/reference/session-state-collector.md" \
  "$HOME/.claude/reference/session-state-collector.md"; do
  [[ -r "$candidate" ]] && { COLLECTOR_DOC="$candidate"; break; }
done
COLLECTOR_DOC="${COLLECTOR_DOC:-}"

for candidate in \
  "$HOME/.claude/skills-worktree/.claude/reference/background-task-shutdown.md" \
  "$HOME/.claude/reference/background-task-shutdown.md"; do
  [[ -r "$candidate" ]] && { SHUTDOWN_DOC="$candidate"; break; }
done
SHUTDOWN_DOC="${SHUTDOWN_DOC:-}"
```

Do not add a cwd-relative fallback to either resolver. `/end` is designed to
run while the current checkout may be unrelated or untrusted; executing its
`.claude/scripts` files (or following its instruction documents) would cross a
trust boundary. If neither installed location resolves, degrade explicitly as
described below.

Parse the first `--window` value exactly as `/pause` does. Accept a
non-negative integer with an optional trailing `m`, default to `5`, reject a
missing, negative, non-numeric, or greater-than-1440-minute value, and compute
one deadline. Leading zeroes are decimal (`08m` is eight minutes). `--window 0`
skips cooperative checkpoint time and proceeds directly to hard stop.

```bash
WINDOW_MINUTES=5
_NEXT_IS_WINDOW=false
_WINDOW_SET=false
for arg in $ARGUMENTS; do
  [[ "$_WINDOW_SET" == true ]] && continue
  if [[ "$_NEXT_IS_WINDOW" == true ]]; then
    _NEXT_IS_WINDOW=false
    _RAW="${arg%m}"
    [[ "$_RAW" =~ ^[0-9]+$ ]] || { echo "ERROR: --window requires a non-negative integer (got: $arg)" >&2; exit 2; }
    _NORMALIZED="${_RAW#"${_RAW%%[!0]*}"}"
    _NORMALIZED="${_NORMALIZED:-0}"
    (( ${#_NORMALIZED} < 4 )) || \
      { (( ${#_NORMALIZED} == 4 )) && [[ "$_NORMALIZED" < 1441 ]]; } || \
      { echo "ERROR: --window must not exceed 1440 minutes." >&2; exit 2; }
    WINDOW_MINUTES=$((10#$_NORMALIZED))
    _WINDOW_SET=true
    continue
  fi
  [[ "$arg" == --window ]] && _NEXT_IS_WINDOW=true
done
[[ "$_NEXT_IS_WINDOW" == false ]] || { echo "ERROR: --window requires a value." >&2; exit 2; }
T_END=$(( $(date -u +%s) + WINDOW_MINUTES * 60 ))
```

An unresolved state, execution-pause, registry, or shutdown helper makes the
shutdown incomplete. Say which control is missing, keep every control that was
successfully armed closed, and still render the handoff in the thread. A
missing context, checker, or publisher helper prevents a canonical file from
being claimed as published; retain and name the draft instead.

## Step 1: Close both launch gates immediately

Arm the session-scoped execution gate before reading or waiting on background
work, then pause refilling. The first prevents direct Agent, Workflow, Monitor,
and background Bash launches; the second prevents pipeline successor launches.

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
WINDDOWN_PERSISTED=1
EXECUTION_GATE_PERSISTED=1
if [[ -n "$EXECUTION_PAUSE_SH" ]]; then
  "$EXECUTION_PAUSE_SH" --activate --session "$SESSION_ID" \
    --command end --window-minutes "$WINDOW_MINUTES" \
    || EXECUTION_GATE_PERSISTED=0
else
  EXECUTION_GATE_PERSISTED=0
fi
if [[ -n "$SESSION_STATE_SH" ]] && \
   REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) && \
   [[ -n "$REPO_KEY" ]]; then
  NOW=$(date -u +%FT%TZ)
  "$SESSION_STATE_SH" \
    --set ".repos[\"$REPO_KEY\"].refill={\"paused\":true,\"reason\":\"full_stop\",\"scope\":null,\"at\":\"$NOW\"}" \
    || WINDDOWN_PERSISTED=0
else
  WINDDOWN_PERSISTED=0   # Step 0 could not resolve the helper
fi
```

Both gates stay closed until an explicit `/end-resume` invocation. A later
message, timer, or scan never clears them implicitly. `/pause-resume` clears the
same execution gate only while restoring the separate paused-board workflow;
it is not a substitute for recovering this end handoff.

## Step 2: Checkpoint, stop, and prove quiescence

Read and follow `$SHUTDOWN_DOC` in full with the parsed deadline. Preserve each
task's output and recovery location in the registry and in the handoff's Open
work or Local state section. This command owns the current session only; name
separate `claude agents` sessions as out of scope.

Print the initial winding-down line before the cooperative window. After the
deadline and final audit, report exact counts:

```text
=== Winding down ===
Gates:     <execution gate and refill gate status>
Stopped:   <N of N current-session background tasks confirmed terminal>
Preserved: <task IDs and their output/worktree/recovery paths, or "nothing was running">
Unresolved:<exact live IDs and stop errors, or "none">
Resume:    /end-resume [--resume-refill]
```

Do not print successful completion while any owned task is still live or either
audit is unreadable. Report `INCOMPLETE SHUTDOWN` and keep the gates closed.
Nothing in this block is a question.

## Step 3: Collect the state

Follow the collector resolved as `$COLLECTOR_DOC` in Step 0 — the same one `/pm-handoff` uses. Collect all five categories, including §5 (uncommitted and unpushed local state), which only this command needs.

**Read it by its resolved path, not by a repo-relative one.** From another checkout `.claude/reference/session-state-collector.md` simply does not exist, and an unreadable collector produces the same silence as an empty session. If `$COLLECTOR_DOC` is empty, say in Step 2's report that collection ran without it and gather what you can directly — an unguided pass is worth more than a document that reports nothing in flight because it could not look.

**Substitute the paths resolved in Step 0 for the collector's `.claude/scripts/…` literals.** Those literals resolve only from this repo, and a `/end` run from anywhere else would get command-not-found on every read — which looks exactly like a session with nothing in flight. Reporting "no in-flight work" when the truth is "could not look" is the one mistake this document cannot afford, because the reader has no way to detect it.

Every category can be legitimately empty. An empty category is reported as empty; it never aborts collection and never produces an error. **A category that could not be *read* is not empty** — say so in those words.

After the shutdown audit has produced final task outcomes, collect one bounded
machine snapshot. This snapshot is the authority for repository/worktree/Git
fields, linkage, and current-session task metadata in the document:

```bash
CONTEXT_ERROR=""
if [[ -n "$HANDOFF_CONTEXT_SH" ]]; then
  if CONTEXT_JSON=$("$HANDOFF_CONTEXT_SH" --session "$SESSION_ID" 2>/dev/null); then
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$CONTEXT_JSON"; then
      CONTEXT_ERROR="context snapshot failed (malformed or non-object JSON)"
      CONTEXT_JSON=""
    fi
  else
    CONTEXT_RC=$?
    CONTEXT_ERROR="context snapshot failed (exit $CONTEXT_RC)"
    CONTEXT_JSON=""
  fi
else
  CONTEXT_ERROR="portable-handoff-context.sh was not resolved from a trusted install"
  CONTEXT_JSON=""
fi
```

Read only the named fields in `CONTEXT_JSON`; never dump arbitrary environment
variables, credential-bearing remote URLs, file contents, or the raw session
state into the handoff. Lists are already capped. If the snapshot is absent or
invalid, render every affected value as `unknown — context snapshot failed`,
state `$CONTEXT_ERROR`, and do not claim that no work or metadata existed.

## Step 4: Render the portable document

Build the document from `references/portable-handoff-template.md`, following its rendering rules. Render **once**, into a single buffer — that one buffer is what gets verified, written, and printed. The explicit Progress and verification section must cover objective, completed work, remaining work, blockers or decisions, tests, review state, and exact next commands. Use the context snapshot's separately labeled tracked and untracked arrays; do not collapse them to a generic dirty count.

For every current-session task returned by the snapshot, render its exact
runtime ID, logical name, translated type, final status, work item, output,
checkpoint (when separately known), and recovery path. Missing values say `not
recorded`; they never become invented paths. A `running`, `stopping`,
`stop_failed`, or unreadable task inventory makes the handoff say shutdown is
incomplete and keeps the gates closed.

The Resume safely section names `/end-resume` for this harness and also gives
a different coding agent a shell-quoted `cd -- '<absolute worktree>'` followed
by ordinary `git`, `gh`, and test commands. It explicitly requires inspecting
each recorded status/output/recovery path before any relaunch.

The reader is an agent or person with the repository and this document and nothing else: no rules loaded, no state files, no knowledge of our conventions, possibly not Claude at all. Translate every internal concept into what someone can act on (the template has the translation table).

## Step 5: Stage and verify portability — this is a gate, not a review

Write the single rendered buffer to a temporary draft **in the destination
directory**. The canonical publisher runs the checker against those exact bytes:

```bash
OUT_DIR="$HOME/.claude/handoffs"
STAGING_ERROR=""
if ! mkdir -p "$OUT_DIR"; then
  STAGING_ERROR="mkdir -p $OUT_DIR failed"
  TMP_DOC=""
elif ! TMP_DOC=$(mktemp "$OUT_DIR/.portable-handoff.XXXXXX"); then
  STAGING_ERROR="mktemp $OUT_DIR/.portable-handoff.XXXXXX failed"
  TMP_DOC=""
fi
# ... write the rendered buffer to "$TMP_DOC" ...
```

Staging inside `$OUT_DIR` — not `$TMPDIR` — keeps Step 6's `mv` on one filesystem, where it is a real atomic rename rather than a copy a reader can catch half-finished.

- **Publisher exit 0** — the exact buffer passed lint and atomically replaced
  the canonical repository/session note.
- **Publisher exit 1** — the document is not portable. Rewrite each reported
  line in plain English and retry; never publish the failing bytes.
- **Any other exit** — verification, locking, staging, or publication could not
  complete. Keep and print the draft, name its path and the exact error, and do
  not claim a canonical note was written.

If `STAGING_ERROR` is non-empty, no destination draft exists to publish. Keep
the rendered buffer in memory, print it in the thread, report the exact command
failure, and name `$OUT_DIR` as the recovery destination for a later retry. Do
not run `mv`, claim a file was emitted, or discard the only remaining copy.

The lint also enforces that every required section exists and has content, which is what keeps graceful degradation from quietly producing an empty shell.

Steps 4–6 are one bounded correction loop with at most three publication
attempts. Publisher exit 1 returns to Step 4: display the lint findings,
rewrite the same buffer to address every finding, stage it again, and retry.
Do not print the document as final while lint is failing. After three lint
failures, preserve the latest draft, report that the canonical handoff was not
published, and keep every completion gate closed.

Set `PUBLISH_ATTEMPT=0` once before the first Step 4 render. Preserve it across
corrections; do not reset it when returning to Step 4.

## Step 6: Publish canonically, then print the same bytes

```bash
PUBLISH_ATTEMPT=$((PUBLISH_ATTEMPT + 1))
PUBLISH_RC=4
OUT=""
if [[ -n "$TMP_DOC" && -n "$HANDOFF_PUBLISH_SH" && -n "$HANDOFF_LINT_SH" ]]; then
  REPO_ID=$(jq -r '.repository.identity // "unknown"' <<<"$CONTEXT_JSON" 2>/dev/null)
  LINT_ROOT=$(cd "$(dirname "$HANDOFF_LINT_SH")/../.." 2>/dev/null && pwd)
  if [[ "$REPO_ID" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    if [[ -n "$LINT_ROOT" ]]; then
      OUT=$("$HANDOFF_PUBLISH_SH" --input "$TMP_DOC" --repo "$REPO_ID" \
        --session "$SESSION_ID" --out-dir "$OUT_DIR" --lint "$HANDOFF_LINT_SH" \
        --lint-root "$LINT_ROOT")
    else
      OUT=$("$HANDOFF_PUBLISH_SH" --input "$TMP_DOC" --repo "$REPO_ID" \
        --session "$SESSION_ID" --out-dir "$OUT_DIR" --lint "$HANDOFF_LINT_SH")
    fi
    PUBLISH_RC=$?
  else
    echo "could not publish the canonical handoff: repository identity is unknown" >&2
  fi
fi
if (( PUBLISH_RC == 0 )); then
  rm -f "$TMP_DOC"
  echo "$OUT"
elif (( PUBLISH_RC == 1 )); then
  if [[ -n "$LINT_ROOT" ]]; then
    "$HANDOFF_LINT_SH" --repo-root "$LINT_ROOT" "$TMP_DOC" >&2 || true
  else
    "$HANDOFF_LINT_SH" "$TMP_DOC" >&2 || true
  fi
  if (( PUBLISH_ATTEMPT < 3 )); then
    echo "portable handoff lint failed on attempt $PUBLISH_ATTEMPT of 3; return to Step 4, rewrite the same buffer, and retry" >&2
  else
    echo "portable handoff lint failed on attempt 3 of 3; canonical handoff was not published; recovery draft: $TMP_DOC" >&2
    echo "INCOMPLETE SHUTDOWN — all completion gates remain closed" >&2
  fi
elif [[ -n "$TMP_DOC" && -f "$TMP_DOC" ]]; then
  echo "canonical handoff was not published (exit $PUBLISH_RC); recovery draft (validation may be incomplete): $TMP_DOC" >&2
else
  echo "could not stage the handoff: $STAGING_ERROR; retry publication in $OUT_DIR" >&2
fi
```

The publisher derives one deterministic filename from the validated repository
identity and session ID, acquires an advisory lock, lints the staged bytes, and
uses same-directory `mktemp` + `mv`. A reader sees the previous complete note or
the new complete note, never a partial file; concurrent `/end` calls serialize
instead of creating competing handoffs. Naming and format:
`.claude/reference/portable-handoff.md`.

If the `mv` fails, say so and print the temp file's path — never report a write that did not happen.

Then print the **same buffer** in the thread, in one fenced block, so it can be copied without a file read. Do not re-render for display: a second render is a second document, and the reader has no way to tell which one they got.

Close with the file path on its own line, so the next session (and the usage-limit recorder, which points at the most recent one of these) can find it.

## Relationship to the other end-of-something commands

| Command | Ends | Produces |
|---|---|---|
| `/wrap` | a pull request | a merge, follow-up issues, lessons |
| `/pm-handoff` | a thread | a prompt for the next thread in this harness |
| `/end` | a working session | a document for a reader **outside** this harness |

### The automatic checkpoint is a different producer, not this command on a timer

`.claude/hooks/checkpoint-handoff.sh` writes the same *kind* of document automatically while work is in progress (issue #941), because a usage limit that arrives without warning is exactly the case where nobody got to run `/end` — and the recorder that looks for a handoff then finds none.

It ends nothing. It stops no work, takes no wind-down step, and makes no decision; it only describes repository state. So the "does not fire on a schedule, a threshold, or an inference" clause below still holds for **this** command, which is the one that stops things.

The two are distinguishable on disk: a checkpoint's filename ends `-checkpoint.md`. What you write here is richer — it carries the reasoning a script cannot know — so a checkpoint names the most recent `/end` document in its own body rather than burying it, and retention never deletes one.

They overlap in what they read — hence the shared collector — and not at all in what they produce. `/end` does not merge anything, does not close anything, and does not decide that work is finished. It records where the work actually is and stops.

## Not this command's job

- **Estimating anything.** No token count, no spend figure, no "you have about N left". You read the usage view; this command does not model it.
- **Deciding when to stop.** It runs when invoked. It does not fire on a schedule, a threshold, or an inference.
- **Deleting interrupted work.** Stops preserve branches, worktrees, logs,
  outputs, and recovery metadata for explicit resume.

When a real approaching-limit signal eventually reaches a hook, the wind-down built on it emits **this** document rather than defining its own (issue #835) — the trigger changes, the artifact does not.
