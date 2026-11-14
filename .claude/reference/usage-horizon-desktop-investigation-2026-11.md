# Usage-Horizon Desktop Investigation — 2026-11

**Question (issue #2376):** why does `usage-horizon.sh --check` come back `unknown` in desktop sessions, so that launches stop? Two causes were suspected: the derived session key changing mid-conversation, and the harness never printing the remaining-token figure.

**Verdict.** The second cause is the real one, and it is a property of the **model**, not of the desktop app. The first cause did not happen in the reported session, but it can happen, and it is now closed off anyway.

| Suspected cause | Finding | Confidence |
|---|---|---|
| The harness never prints the figure | True for this model. The counter is a per-model harness capability, and Fable 5.2 does not have it in the binary that ran the session. | Established from the binary. Not printed in the investigating sub-agent's own context either. |
| The derived session key changed mid-conversation | Not in the reported session. The "earlier reading" the check refused was written 18 days before by a different conversation. | Established from the observation log, the state slot and the process table. |
| The derived key can change under one conversation | Yes in principle (measured for issue #1572). Not reproduced here. | Not reproduced; the fix does not depend on it. |

## Audit record

| | |
|---|---|
| Date | 2026-11-14 |
| Runtime | Claude Code **2.1.321** (the binary that owns the conversation; the `claude` on `PATH` reports 2.1.325) |
| Binary | `~/Library/Application Support/Claude/claude-code/2.1.321/ddbdf2b334e1/claude.app/Contents/MacOS/claude` |
| Size / SHA-256 | 323,686,048 B · `f309b01144b4a1c59b3deee5c033809725c3007686dd4ae254b64a49aa5a5f10` |
| Host | Desktop app 5.11492.0, `CLAUDE_CODE_ENTRYPOINT=claude-desktop` |
| Model | Fable 5.2 (`claude-fable-5-2`), parent conversation and this sub-agent |
| Investigator | A Phase A sub-agent inside the affected conversation. It shares the parent's `claude` process and environment. It cannot see the parent's context. |

## Finding 1 — the counter is a per-model capability, absent for Fable 5.2

**Evidence (binary strings).** The harness describes the setting itself:

> `totalTokensReminder` … "Emit a `<total_tokens>N tokens left</total_tokens>` block in the system prompt, after each tool result, and (when totalTokensReminderAfterUserTurn is on) after each regular user prompt. 'infinite' uses the literal value Infinite, 'fixed' uses 5000000, 'countdown' uses the live remaining context-window tokens, 'padded-countdown' counts down from totalTokensReminderBudget … Defaults to padded-countdown for a model with the total_tokens_reminder capability, else off. Env var CLAUDE_CODE_TOTAL_TOKENS_REMINDER overrides."

The model table in the same binary lists the capability per model. It is present for every listed model up to and including Fable 5.1, Opus 5, Sonnet 5, Haiku 5.5 and Mythos 5.1. It is **absent** for `claude-fable-5-2`, `claude-opus-5-5`, `claude-sonnet-5-5` and `claude-mythos-5-2`. `CLAUDE_CODE_TOTAL_TOKENS_REMINDER` was not set in the session's environment.

So in a Fable 5.2 conversation the default is `off`: no figure in the system prompt, none after tool results. This holds in the terminal as well as the desktop app. A sub-agent running on a model that has the capability would see a figure in its own context.

**Corroboration.**

- No such block appeared anywhere in this sub-agent's context (system prompt or any tool result), on Fable 5.2.
- `~/.claude/usage-horizon.jsonl` holds 245 readings. The last is dated 2026-10-27. No conversation on this machine recorded one between then and 2026-11-14, though sessions ran daily.
- The reported parent transcript contains no counter-shaped string. This is weak evidence on its own: harness-injected text is not necessarily kept in a transcript.
- It agrees with issue #2147, which reported the counter absent throughout a Claude Code 2.1.322 / Fable 5.2 session.

**Not determined.** Whether the parent conversation saw a figure before its first compaction was not observed first-hand; a sub-agent cannot read the parent's context. The binary evidence says it did not. Whether a server-side flag can turn the capability on for a model at run time was not determined.

**Reproduce.**

```bash
BIN="$HOME/Library/Application Support/Claude/claude-code/<version>/<build>/claude.app/Contents/MacOS/claude"
strings -n 6 "$BIN" > "$TMPDIR/claude-strings.txt"
grep -o 'totalTokensReminder:()=>.\{1700\}' "$TMPDIR/claude-strings.txt" | head -1
grep -c 'total_tokens_reminder' "$TMPDIR/claude-strings.txt"
```

## Finding 2 — the refused reading was never this conversation's

The reported diagnostic was `stored reading belongs to session derived-872ab4b35369993b5d38, not derived-ca8e629f1b9c1df68baf`, read as the check refusing its own earlier reading.

| Observation | Value |
|---|---|
| `.usage_horizon.reading` in `session-state.json` | `session_id` `derived-872ab4b35369993b5d38`, `ts` `2026-10-27T21:57:36Z` |
| Last line of the observation log | the same reading; nothing later |
| The conversation's `claude` process | started 2026-11-13 14:36:02 local, still running on 2026-11-14 |
| Digest of that process's identity (`claude=<pid>\|start=<lstart>`) | `ca8e629f1b9c1df68baf` |
| First transcript entry of the conversation | 2026-11-13T19:36:46Z, the same minute as the process start |
| Compactions in that conversation so far | 2 |

The stored reading predates the conversation's process by 17 days. The current key is the digest of a process that has not changed since the conversation began, across two compactions. So **compaction does not change the derived key**, and in this session the key did not drift at all. `no-reading-this-session` was the correct answer: the slot held another conversation's old reading, and this conversation never had one (Finding 1).

**Why the launches still stopped.** With no figure ever printed, the only reason that lets an explicit request through is `counter-never-seen`. `subagent-thread-limit-park.md` §7.3 allowed that attestation only on continuous first-hand observation since session start, and barred it after a compaction. After the first compaction the thread could no longer attest, so the check stayed at `no-reading-this-session`, whose hold line says to wait for a fresh counter that this model never prints, and whose explicit-request column said "Remains held". That is the loop the owner had to break by hand.

**Not determined.** Which question the owner answered "Launch anyway". The only menu with that label in the source is the deadline-overrun menu (`.claude/skills/subagent/SKILL.md`, the `/leave-by` gate). §7.3 defines hold lines, not a menu.

## Finding 3 — the derived key can drift, and a stable anchor exists

The derived key is a digest of the nearest ancestor `claude` process (pid + start time). Issue #1572 measured that process being replaced under one conversation after an overnight sleep. Nothing here reproduced it, but nothing rules it out either.

The harness hands Bash tool subshells two conversation ids, and both were present in the desktop session:

| Variable | Present in desktop Bash calls | Notes |
|---|---|---|
| `CLAUDE_CODE_HOST_SESSION_ID` | yes | Set by the desktop app in each conversation's `claude` process environment. Eight concurrent conversations on the machine carried eight distinct values. |
| `CLAUDE_CODE_SESSION_ID` | yes | Exported by the CLI to the subshell (absent from the process's own environment). Equal to the conversation's transcript id; unchanged across the two compactions. |
| `CLAUDE_SESSION_ID` | no | Never set in Bash tool subshells here. |

A `claude` process started from a terminal carried neither id in its own environment.

A sub-agent's Bash calls carry the parent's ids and walk to the parent's `claude` process, so a sub-agent and its parent share one horizon identity. That was already true of the derived key.

## Decision gate and what changed

An anchor is present and stable across compaction, so the reading is keyed on it.

1. **Identity.** `usage-horizon.sh` resolves `--session`, `CLAUDE_SESSION_ID`, then a digest of `CLAUDE_CODE_HOST_SESSION_ID`, then of `CLAUDE_CODE_SESSION_ID`, then the derived key. These are the anchors `resolve-log.sh` records for issue #1572, in the same order. They are reused as environment inputs; the marker files are not, because a reading keyed directly on the anchor needs no adoption step. Only digests are stored (`reading.anchors.{host,sid}`).
2. **Ownership.** One rule serves `--check`, the hysteresis anchor and the log cross-check: equal key, or an equal recorded anchor. An explicit identity stays exact and never borrows the ambient ids.
3. **The never-seen attestation has a durable half.** `--check --counter-never-seen` now scans the script's own observation log for a reading this conversation recorded. None: `counter-never-seen`. One: `counter-seen-reading-displaced`, and the attestation is refused. So the caller attests only what it can still see, and a compaction no longer bars it. Where the Bash environment carries no harness id, the key is the derived fallback and an empty search proves nothing: the answer is then `counter-never-seen-unverified`, which keeps the old continuous-observation requirement.
4. **Hold lines** say this is not the account usage reader and that signing in will not change it.

**Unchanged.** `unknown` exits 3 and is never `clear`. Automatic refill stays held on every `unknown`. Nothing counts, converts or infers tokens: the log scan asks whether a line exists and reads no figure from it. `.claude/rules/safety.md` is untouched.

**Residual risks.** Each can only let through a launch the user asked for in chat; none reaches automatic refill.

- Log rotation (256 KiB, one retained generation) can drop a conversation's old lines.
- With no harness id at all, a drifted derived key misses its own earlier lines. This case is reported as `counter-never-seen-unverified` and keeps the stricter attestation.
- A counter that was printed but never recorded with `--observe` leaves no line.
- A reading written before this change carries no anchors. A conversation that recorded one and then upgraded reads `unknown` until its next observation.

## Open, for the owner

Items 1 and 2 are tracked in issue #2390.

1. **Automatic refill never runs on a model without the capability.** With no figure there is never a reading, the verdict is `unknown` on every cycle, and `unknown` starts nothing automatically (`monitor-mode.md` item 0). That is by rule and this change does not touch it. On Fable 5.2 it means a pipeline is refilled only by a chat request.
2. **What the figure measures.** The harness text above says the default mode counts down from a configured budget (15,000,000 by default) and re-anchors to the full budget on each user prompt, and that another mode reports remaining context-window tokens. Neither is the account's usage window. `budget-source-probe.md` Probe 0 and the script header describe it as account runway. The characterization question Probe 0 left open has an answer in the binary, and it does not match the description. Thresholds and the park at `critical` were designed on the account-runway reading.
3. **The env override exists** (`CLAUDE_CODE_TOTAL_TOKENS_REMINDER`). It is marked internal. Setting it would make a figure appear on this model, with the meaning in item 2. Not done here.

## Manual verification

These need a live conversation and were not run by the investigating sub-agent.

1. On a model that prints the figure: record it (`usage-horizon.sh --observe <n>`), run `--check`, force a compaction (`/compact`), run `--check` again. Expect the same two lines and the same exit code.
2. On Fable 5.2, in a conversation that has compacted: run `usage-horizon.sh --check --counter-never-seen`. Expect `STATUS=unknown`, `REASON=counter-never-seen`, exit 3.
3. In that conversation, type `/subagent <issue>`. Expect one `[horizon counter absent]` note, a launch, and no question about the horizon.
4. Let the same thread reach a refill tick with a free slot. Expect no automatic launch and `paused (horizon unknown) — counter-never-seen` on the idle line.

The scripted equivalents of 1 and 2 are in `.claude/scripts/tests/usage-horizon.test.sh` sections 10 and 11.
