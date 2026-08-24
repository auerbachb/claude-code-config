---
name: stop
description: Use when usage allowance is exhausted or running thin and this session must stop for hours or days while preserving resumable work. Blocks new launches, gives running work a bounded checkpoint window, stops every remaining owned background task, then writes a portable handoff. Triggers on "stop", "clean stop", "wind down", "portable handoff", "hand this to another agent", "I'm running low".
triggers:
  - stop
  - clean stop
  - wind down
  - portable handoff
  - hand off to another agent
argument-hint: "[--window Nm] (default: --window 5m; --window 0 stops immediately)"
---

Stop cleanly for a potentially long interruption, and leave behind a document
someone else can pick up.

**You decide when.** The usage view in the app is the authoritative source for what is left of your allowance, and you are the one reading it. This command never estimates tokens, spend, or remaining quota, and never refuses or defers work based on one — `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" holds as written. `/stop` runs because you asked, and for no other reason.

Two outputs, in this order: a wind-down that leaves nothing half-finished, and a portable handoff document written to disk and printed in the thread.

## Step 0: Resolve helpers and parse the window

`/stop` is invocable from any thread — including one whose working directory is not this repo, which is exactly the situation where a repo-relative path silently fails. Resolve each helper the same way the other stop-style commands do:

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

Do not add a cwd-relative fallback to either resolver. `/stop` is designed to
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
successfully armed closed, and still emit the handoff. An unresolved checker
is handled by Step 5's "could not run" branch.

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
    --command stop --window-minutes "$WINDOW_MINUTES" \
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

Both gates stay closed until an explicit `/stop-resume` invocation. A later
message, timer, or scan never clears them implicitly. `/pause-resume` clears the
same execution gate only while restoring the separate paused-board workflow;
it is not a substitute for recovering this stop handoff.

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
Resume:    /stop-resume [--resume-refill]
```

Do not print successful completion while any owned task is still live or either
audit is unreadable. Report `INCOMPLETE SHUTDOWN` and keep the gates closed.
Nothing in this block is a question.

## Step 3: Collect the state

Follow the collector resolved as `$COLLECTOR_DOC` in Step 0 — the same one `/pm-handoff` uses. Collect all five categories, including §5 (uncommitted and unpushed local state), which only this command needs.

**Read it by its resolved path, not by a repo-relative one.** From another checkout `.claude/reference/session-state-collector.md` simply does not exist, and an unreadable collector produces the same silence as an empty session. If `$COLLECTOR_DOC` is empty, say in Step 2's report that collection ran without it and gather what you can directly — an unguided pass is worth more than a document that reports nothing in flight because it could not look.

**Substitute the paths resolved in Step 0 for the collector's `.claude/scripts/…` literals.** Those literals resolve only from this repo, and a `/stop` run from anywhere else would get command-not-found on every read — which looks exactly like a session with nothing in flight. Reporting "no in-flight work" when the truth is "could not look" is the one mistake this document cannot afford, because the reader has no way to detect it.

Every category can be legitimately empty. An empty category is reported as empty; it never aborts collection and never produces an error. **A category that could not be *read* is not empty** — say so in those words.

## Step 4: Render the portable document

Build the document from `references/portable-handoff-template.md`, following its rendering rules. Render **once**, into a single buffer — that one buffer is what gets verified, written, and printed.

The reader is an agent or person with the repository and this document and nothing else: no rules loaded, no state files, no knowledge of our conventions, possibly not Claude at all. Translate every internal concept into what someone can act on (the template has the translation table).

## Step 5: Verify portability — this is a gate, not a review

Write the buffer to a temporary file **in the destination directory** and check it:

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
if [[ -z "$TMP_DOC" ]]; then
  LINT_RC=2
elif [[ -n "$HANDOFF_LINT_SH" ]]; then
  # Bind the skill catalog to the checker's OWN repo, not the cwd. Without
  # --repo-root, a /stop run inside some other project that also happens to
  # have a .claude/skills directory would validate against THAT project's
  # command list — and a document full of this harness's commands would pass.
  LINT_ROOT=$(cd "$(dirname "$HANDOFF_LINT_SH")/../.." 2>/dev/null && pwd)
  if [[ -n "$LINT_ROOT" ]]; then
    "$HANDOFF_LINT_SH" --repo-root "$LINT_ROOT" "$TMP_DOC"; LINT_RC=$?
  else
    "$HANDOFF_LINT_SH" "$TMP_DOC"; LINT_RC=$?
  fi
else
  LINT_RC=2   # checker not found in Step 0 — same branch as "could not run"
fi
```

Staging inside `$OUT_DIR` — not `$TMPDIR` — keeps Step 6's `mv` on one filesystem, where it is a real atomic rename rather than a copy a reader can catch half-finished.

- **`LINT_RC` 0** — proceed to Step 6.
- **`LINT_RC` 1** — the document names something the reader cannot use. Rewrite each reported line in plain English, then re-run. Do not emit a failing document, and do not edit the checker to make a line pass.
- **Anything else** (2, 3, an unresolved checker, or a non-zero the checker does not define) — the check could not run. Emit the document anyway, and say plainly in the thread that it went out **unverified**, naming what stopped it. An unverified handoff is worth more than no handoff; an unverified handoff the user believes was checked is worth less than nothing.

If `STAGING_ERROR` is non-empty, no destination draft exists to publish. Keep
the rendered buffer in memory, print it in the thread, report the exact command
failure, and name `$OUT_DIR` as the recovery destination for a later retry. Do
not run `mv`, claim a file was emitted, or discard the only remaining copy.

The lint also enforces that every required section exists and has content, which is what keeps graceful degradation from quietly producing an empty shell.

## Step 6: Emit — write, then print the same bytes

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
SESSION_ID="${SESSION_ID:-default}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DOC_TAG="${TMP_DOC##*.portable-handoff.}"
OUT="$OUT_DIR/portable-handoff-${STAMP}-${SESSION_ID}-${DOC_TAG}.md"
if [[ -n "$TMP_DOC" ]] && mv "$TMP_DOC" "$OUT" 2>/dev/null; then
  chmod 644 "$OUT"
  echo "$OUT"
else
  if [[ -n "$TMP_DOC" && -f "$TMP_DOC" ]]; then
    echo "could not publish the handoff; the draft is at $TMP_DOC" >&2
  else
    echo "could not stage the handoff: $STAGING_ERROR; retry publication in $OUT_DIR" >&2
  fi
fi
```

Same-directory `mktemp` + `mv` is an atomic single-writer publish — a reader
sees a complete document or none. The exclusive `mktemp` suffix is retained in
the final name, so concurrent invocations in the same session and second never
target or overwrite the same path. Naming and format:
`.claude/reference/portable-handoff.md`.

If the `mv` fails, say so and print the temp file's path — never report a write that did not happen.

Then print the **same buffer** in the thread, in one fenced block, so it can be copied without a file read. Do not re-render for display: a second render is a second document, and the reader has no way to tell which one they got.

Close with the file path on its own line, so the next session (and the usage-limit recorder, which points at the most recent one of these) can find it.

## Relationship to the other end-of-something commands

| Command | Ends | Produces |
|---|---|---|
| `/wrap` | a pull request | a merge, follow-up issues, lessons |
| `/pm-handoff` | a thread | a prompt for the next thread in this harness |
| `/stop` | a working session | a document for a reader **outside** this harness |

### The automatic checkpoint is a different producer, not this command on a timer

`.claude/hooks/checkpoint-handoff.sh` writes the same *kind* of document automatically while work is in progress (issue #941), because a usage limit that arrives without warning is exactly the case where nobody got to run `/stop` — and the recorder that looks for a handoff then finds none.

It ends nothing. It stops no work, takes no wind-down step, and makes no decision; it only describes repository state. So the "does not fire on a schedule, a threshold, or an inference" clause below still holds for **this** command, which is the one that stops things.

The two are distinguishable on disk: a checkpoint's filename ends `-checkpoint.md`. What you write here is richer — it carries the reasoning a script cannot know — so a checkpoint names the most recent `/stop` document in its own body rather than burying it, and retention never deletes one.

They overlap in what they read — hence the shared collector — and not at all in what they produce. `/stop` does not merge anything, does not close anything, and does not decide that work is finished. It records where the work actually is and stops.

## Not this command's job

- **Estimating anything.** No token count, no spend figure, no "you have about N left". You read the usage view; this command does not model it.
- **Deciding when to stop.** It runs when invoked. It does not fire on a schedule, a threshold, or an inference.
- **Deleting interrupted work.** Stops preserve branches, worktrees, logs,
  outputs, and recovery metadata for explicit resume.

When a real approaching-limit signal eventually reaches a hook, the wind-down built on it emits **this** document rather than defining its own (issue #835) — the trigger changes, the artifact does not.
