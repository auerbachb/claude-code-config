# Away log — nothing to chat while the operator is away

Issue #2594. Applies whenever `presence.sh is-away` exits 0: an away window set by `/afk`, `/pm --away` or `/presence`, or an active unattended window.

## Why

While he is away the operator reads none of the chat. When he returns, `/back` is how he catches up. Every message written to chat in between costs output tokens that nobody reads, and it buries the thread he comes back to. `/back`'s digest already comes from durable records: GitHub activity, stoppage entries, handoffs, running agents and the unattended question queue. Its one dependence on chat text was the recovered-tasks scan, which reread the thread for steps handed to the operator. The away log replaces that.

## The contract

While away, a thread:

1. **Writes no chat text.** No progress, status, monitor tick, merge line, blocker notice, recap or closing summary. If the host requires a turn to end with text, use the shortest allowed close. Skip the desktop app's next-step box, which no one will see.
2. **Logs what it would have said** with `away-log.sh append --kind <kind> --text '<one line>'`:

   | kind | for |
   |---|---|
   | `blocker` | an owner-only blocker, an exhausted recovery or a genuine stall |
   | `decision` | a call it made that he may want to revisit (questions themselves still go to the unattended queue) |
   | `owner-task` | a step only he can do. Also save it with `owner-task.sh add` as `human-queue.md` requires. |
   | `merged` | the `merged PR #N` line |
   | `stopped` | a pipeline or watch that stopped, with how it resumes |
   | `summary` | the closing message of finished work |
   | `note` | anything else he would have wanted |

   Name a variable or account, never its value. Text that looks like a secret is refused (exit 5), and text over 2000 bytes is refused (exit 2).
3. **Changes nothing else.** Gates, safety stops, hard stops, CI and review evidence, session state, handoffs, claims and the unattended question queue all behave exactly as in `decision-only-output.md`. Only the human-facing narration moves. Phone pushes for a blocking question (Issue #2291) still go out.

On his next live message presence returns him and normal decision-only output resumes. Nothing is replayed into chat except through `/back`.

## How the thread knows

`silence-detector.sh` (PostToolUse, every tool call) checks `presence.sh is-away` on a new session, and otherwise only when it would emit something: the SILENCE CHECK nag or the once-a-minute time injection. While he is away it never nags. Instead it refreshes the heartbeat and, at most once per `AWAY_REMIND_S` (default 900 seconds), injects an `OPERATOR AWAY` reminder that carries the contract above. No new hook registration was needed. The always-loaded rules are at their word cap, so the instruction travels in the hook and this reference rather than in `.claude/rules/`.

## Storage and reading

`~/.claude/away-log/<owner>__<repo>/<session>.jsonl` (override the root with `AWAY_LOG_DIR`). Each line is `{at, at_iso, repo, session, kind, text}`. The log is append-only and is never pruned by the writer.

`back-report.sh` reads it into `away_log`: entries since the away declaration, from this session in thread scope and from every repo and session with `--all`. When it cannot read the log it sets `away_log` to null and names the source in `unreadable`, so the gap is reported rather than shown as an empty list. `/back` Step 4 saves `owner-task` entries through `--save-recovered`, and Step 5 shows the rest under **Logged while away**.

## Limits

- The reminder reaches a thread only after its next tool call. A turn that makes no tool call at all may still end with text.
- The log is local to the machine, like the other `/back` local sources.
