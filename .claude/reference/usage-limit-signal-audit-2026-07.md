# Usage-Limit Signal Audit — 2026-07

**Question (issue #824):** does Claude Code expose a trustworthy upstream signal that a **hook, skill, or session** can read to notice "this account is approaching its usage limit" *before* the limit is hit?

**Verdict: No.** A first-party approaching-limit signal exists in the runtime, but it is delivered **only to the status line**, which is a display surface that (a) never executes in this user's environment and (b) has no path back into the model's context even when it does. No hook event of any kind carries usage data. The only limit signal that reaches a hook arrives **after** the turn has already failed.

Consequence: the automatic "detect the approach → wind down → hand off" behavior described in issue #824 **cannot be built on a trustworthy trigger today**, and the issue's own no-signal branch applies — a written finding, no heuristic trigger, and `.claude/rules/safety.md` left unchanged.

### Audit record (this verdict is version-scoped)

| | |
|---|---|
| Runtime | **Claude Code 2.1.219** |
| Binary | `~/Library/Application Support/Claude/claude-code/2.1.219/claude.app/Contents/MacOS/claude` |
| Size / SHA-256 | 256,908,272 B · `49b1845cd34af8a57faf30c460824e4235ae4917bf15cd13288c1ae9e6077b97` |
| Audited | 2026-07-30 |
| Session under probe | Desktop app, headless: `claude --output-format stream-json --verbose --input-format stream-json` |
| Probe config tier | Project — `.claude/settings.local.json` (reverted after the run) |
| Probe duration | ~6 min, dozens of tool calls, normal working session |

**Reproducing it.** Extract the binary's strings once, then re-run the three checks:

```bash
BIN="$HOME/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude"
strings -n 6 "$BIN" > /tmp/claude-strings.txt

# 1. statusLine contract — does it still carry rate_limits, and only there?
grep -n 'rate_limits' /tmp/claude-strings.txt

# 2. Shared hook payload base — does any usage field appear?
grep -oE 'function Kf\([^)]*\)\{.{0,700}' /tmp/claude-strings.txt

# 3. Hook event catalog — has a proactive limit event appeared?
grep -oE '[A-Za-z]+:\{summary:"[^"]*"' /tmp/claude-strings.txt | sort -u
```

The minified identifier for the payload base (`Kf` here) is not stable across builds; if check 2 returns nothing, locate the builder by grepping for `hook_event_name` and reading the object it spreads.

**Live probe.** Register a statusLine command that appends its raw stdin to a file, leave it armed through a normal working session, then check for invocations:

```bash
# .claude/settings.local.json → {"statusLine":{"type":"command","command":"/path/to/probe.sh"}}
# probe.sh: INPUT="$(cat)"; printf '%s\n' "$INPUT" >> /tmp/statusline-payload.jsonl; printf 'probe'
wc -l /tmp/statusline-payload.jsonl 2>/dev/null || echo "0 invocations"
```

---

## Evidence, component by component

### 1. statusLine — carries the signal, but cannot deliver it

The binary embeds the documented statusLine stdin contract. It **does** include usage limits:

```
"rate_limits": {   // Optional: Claude.ai subscription usage limits. Only present for subscribers after first API response.
  "five_hour": {   // Optional: 5-hour session limit (may be absent)
    "used_percentage": number,   // Percentage of limit used (0-100)
    "resets_at": number          // Unix epoch seconds when this window resets
  },
  "seven_day": {   // Optional: 7-day weekly limit (may be absent)
    "used_percentage": number,
    "resets_at": number
  }
}
```

So the number itself is real, first-party, and authoritative. Four separate facts make it unusable as a trigger:

**(a) It only runs inside the interactive TUI.** The status-line executor is invoked from the Ink/React render path, and its result is written into React app state (`onResult` → `statusLineText`) which a footer component renders. There is no non-TUI invocation site.

**(b) It never executes in this user's environment.** The Claude Code desktop app runs the agent headlessly:

```
claude --output-format stream-json --verbose --input-format stream-json --effort max --model … 
```

There is no status line to render in a `stream-json` session, so the command is never called.

**(c) Live probe: zero invocations.** A statusLine command that appended its raw stdin to a dump file was registered and left armed for ~6 minutes across dozens of tool calls in a normal working session. It produced **no output file and no invocations at all**.

> Probe caveat, stated honestly: the probe was registered at the *project* settings tier, so it does not by itself isolate "headless mode" from "tier not honored." That distinction is moot — no status line can execute in a headless session regardless of which tier declares it — and (a) and (b) are independent code-level evidence. It is recorded here so the null result is not over-read.

**(d) Even in a terminal TUI, stdout is display-only.** The command's stdout becomes `statusLineText` and is rendered. Nothing forwards it into the model's context. Any bridge would have to be a *side effect* of the script (writing a marker file that an in-session hook later reads) — the same shape as `silence-watchdog.sh`, whose "no path back into the thread" limitation is already documented in `bgwork-ceiling.sh`.

### 2. Hooks — no usage fields on any event

Every hook payload is built from one shared base function. It returns exactly:

```js
{ session_id, transcript_path, cwd, prompt_id, permission_mode, agent_id, agent_type, effort }
```

No `rate_limits`, no usage, no quota. Per-event payloads add only event-specific fields (`tool_name`, `trigger`, `agent_id`, …).

All 32 registered hook events were enumerated from the binary's own catalog and checked: `ConfigChange`, `CwdChanged`, `DirectoryAdded`, `Elicitation`, `ElicitationResult`, `FileChanged`, `InstructionsLoaded`, `MessageDisplay`, `Notification`, `PermissionDenied`, `PermissionRequest`, `PostCompact`, `PostToolBatch`, `PostToolUse`, `PostToolUseFailure`, `PreCompact`, `PreToolUse`, `SessionEnd`, `SessionStart`, `Setup`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`, `TaskCompleted`, `TaskCreated`, `TeammateIdle`, `UserPromptExpansion`, `UserPromptSubmit`, `WorktreeCreate`, `WorktreeRemove`, `terminal`.

**None carries an approaching-limit field.** `Notification` in particular does not.

The single place in the binary where `rate_limits` appears near `hook_event_name` is a 218 KB minified OpenTelemetry schema blob — a `Quota-429` **error-reporting** shape (`{resets_at, rate_limit_type}`), not a hook payload. It also defines `rate_limits_available` as *"False when plan rate limits do not apply (API key, Bedrock, Vertex, or missing profile)"*, confirming the signal is subscription-scoped.

### 3. StopFailure — real, but strictly post-hoc

```
StopFailure — "When the turn ends due to an API error"
"Fires instead of Stop when an API error (rate limit, auth failure, etc.) ended the turn.
 Fire-and-forget — hook output and exit codes are ignored."
```

Payload: the base fields plus `error`, `error_details`, `last_assistant_message`. It is matchable on the `error` field, whose documented values are:

`rate_limit`, `overloaded`, `authentication_failed`, `oauth_org_not_allowed`, `billing_error`, `invalid_request`, `model_not_found`, `server_error`, `max_output_tokens`, `unknown`

This is a genuine, first-party, zero-estimation limit signal — but it fires **after** the wall, and its output is ignored, so it can neither warn the session nor change its behavior. It can only run a script that records something to disk.

### 4. `/usage` — authoritative, in-app, not machine-readable

The binary contains the in-app usage view (`Current session`, `Current week (all models)`, `Current week (Sonnet only)`, `rate_limits_available`, `model_scoped`). This is the surface `safety.md` names as authoritative. It is UI only; nothing exports it to a hook, a file, or an env var.

---

## Why this is not simply "build the relay anyway"

CodeRabbit's plan on issue #824 proposed a statusLine → marker-file → `PostToolUse` relay, plus a `safety.md` amendment blessing it. The premise (a real `rate_limits` signal exists) is correct; the design does not survive the evidence:

- The observer half **never runs** in the desktop app (§1b, §1c). The relay would be silently inert exactly where this user works — the worst failure mode for a safety-adjacent feature, because it looks shipped and does nothing.
- It would make a wind-down capability's correctness depend on the user's *client choice* (terminal TUI vs. desktop app), invisibly.
- `safety.md` needed no amendment, because nothing shipped acts on an estimate. Amending a deliberately strict safety rule to accommodate a mechanism that cannot fire would weaken the rule for no gain.

## Why this is not "just estimate it locally"

This ground was already covered. Issue #499 rolled back a shipped `/quota` tracker (PR #484) for three reasons, the first of which is the load-bearing one:

1. **Agents gated real decisions on the estimate.** A transcript showed an agent declining to fan out a wave of coding agents "because quota is critical" — the wave was the right move.
2. Per-turn Stop-hook noise across every thread, for days.
3. The measurement model could not match Anthropic's enforcement model.

That rollback is why `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" exists. The inert residue is still on disk (`~/.claude/quota-usage.log`, `~/.claude/quota-usage.d/`, last written 2026-07-01) and is deliberately left alone as user data.

## What NOT to build

- **Do not** ship any trigger derived from locally-computed token or spend arithmetic — including "tokens seen this session," transcript size, or turn counts as a limit proxy. `safety.md` forbids it and #499 is the worked example of the harm.
- **Do not** build the statusLine → marker relay as an automatic trigger while the desktop app is the primary client. It cannot fire there.
- **Do not** amend `safety.md` for this. Nothing shipped here acts on an estimate, so the rule stands unmodified.
- **Do not** treat `StopFailure` as an *approaching*-limit signal. It is a post-mortem.

## What was built instead

A single post-hoc recorder, `.claude/hooks/usage-limit-record.sh`, registered on `StopFailure` with matcher `rate_limit`. When — and only when — the runtime itself reports that a turn ended on a rate limit, it appends a durable record (session id, cwd, transcript path, truncated last assistant message) to `~/.claude/usage-limit-events.jsonl` and refreshes `~/.claude/usage-limit-last.json`.

It is deliberately minimal:

- **Upstream-triggered only.** Its sole input is the runtime's own error classification. It computes nothing.
- **It gates no decision.** It never pauses, downgrades, defers, or refuses work, so `safety.md` is satisfied as written.
- **It is a recorder, not a shutdown.** By the time it fires the turn is already over; the value is that the *next* session finds a breadcrumb instead of silence.

This does not deliver the pre-emptive wind-down issue #824 hoped for. That remains blocked upstream.

## Follow-ups / re-check triggers

Re-run this audit if any of the following change:

1. **A hook event gains usage fields** — re-check the shared hook-payload base. That single change would unblock the full pre-emptive wind-down.
2. **A non-TUI statusLine invocation appears**, or the desktop app starts rendering a status line.
3. **The runtime gains a proactive warning event** (e.g. an `ApproachingLimit` / `Notification` variant carrying `rate_limits`).
4. **A machine-readable usage export** (CLI subcommand, env var, or file) ships.

Until then, the honest user-facing answer is: watch the in-app usage UI, and invoke a handoff yourself (`/pm-handoff`, `/wrap`) when you can see the window running out.

## Related

- `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" — unchanged by this work.
- Issue #499 — the `/quota` rollback that produced that rule.
- Issue #710 — spend/thread-type telemetry: measurement, not a limit signal; does not satisfy the upstream-signal requirement.
- `.claude/reference/bgwork-ceiling.md` — the "external observer with no path back into the thread" precedent.

---

## Re-audit — 2026-08 (issue #835)

**Verdict: unchanged.** No trustworthy pre-emptive usage-limit signal reaches a hook, skill, or session on Claude Code 2.1.221. All three binary checks confirm the same finding as 2.1.219. The post-hoc recorder (`.claude/hooks/usage-limit-record.sh`) remains correct and complete.

### Re-audit record

| | |
|---|---|
| Runtime | **Claude Code 2.1.221** |
| Binary | `~/Library/Application Support/Claude/claude-code/2.1.221/claude.app/Contents/MacOS/claude` |
| Size / SHA-256 | 270,518,240 B · `b3ce994579aa07c0344869f9520735907a1e9229186d79efc12c6163cb380711` |
| Build time | 2026-08-03T03:19:26Z (Git SHA `6efaf12e8b43dc7dbe50e0955c76dc4174a15876`) |
| Audited | 2026-08-05 |
| Method | Binary strings extraction + three-check methodology from §"Reproducing it" above |

### Check 1 — statusLine contract

Usage-limit data still appears only in the statusLine stdin contract (same schema as 2.1.219: `rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage`, `resets_at`). No new hook payload or event payload carries this field. **Unchanged.**

```shell
$ grep -c 'rate_limits' /tmp/claude-strings-2.1.221.txt
11
```

The 11 occurrences of the `rate_limits` token break down as:

- **statusLine contract documentation** (lines 353316, 353356, 353358) — the subscription usage-limit schema with `five_hour` / `seven_day` windows. This is the authoritative usage-limit signal.
- **Internal UI state** (`rateLimits`, `rateLimitGraceActive`) — React app state fields that track usage-limit status for TUI display. Usage-limit related, but confined to the UI render path; no hook reads them.
- **OpenTelemetry error-reporting schema blob** — a `Quota-429` error shape (`{resets_at, rate_limit_type}`); a post-error reporting field, not a usage signal.
- **Gateway config schema** (`rate_limits.device_authorization`, `rate_limits.device_verify`) — request-throttling config for the claude-gateway product, unrelated to subscription usage limits.

None of these occurrences is a hook payload. Because this grep covers the full string table of the binary, it catches event-specific payload fields (e.g. any `MessageDisplay`- or `Notification`-specific additions) just as it does the shared base — no `rate_limits` token is injected by any event's own payload schema.

### Check 2 — Shared hook payload base

The minified identifier changed from `Kf` (2.1.219) to `Hm` (2.1.221), confirming the instability note in §"Reproducing it." Located via `hook_event_name` grep. The returned object is **identical**:

```js
// Hm() in 2.1.221 — same fields as Kf() in 2.1.219
return {
  session_id: n,
  transcript_path: UH(n),
  cwd: Lt(),
  prompt_id: cPt() ?? void 0,
  permission_mode: e,
  agent_id: r?.agentId,
  agent_type: o,
  effort: a
}
```

No `rate_limits`, no usage, no quota. **Unchanged.**

### Check 3 — Hook event catalog

Still exactly **32 events**, identical set to 2.1.219:

`ConfigChange`, `CwdChanged`, `DirectoryAdded`, `Elicitation`, `ElicitationResult`, `FileChanged`, `InstructionsLoaded`, `MessageDisplay`, `Notification`, `PermissionDenied`, `PermissionRequest`, `PostCompact`, `PostToolBatch`, `PostToolUse`, `PostToolUseFailure`, `PreCompact`, `PreToolUse`, `SessionEnd`, `SessionStart`, `Setup`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`, `TaskCompleted`, `TaskCreated`, `TeammateIdle`, `UserPromptExpansion`, `UserPromptSubmit`, `WorktreeCreate`, `WorktreeRemove`, `terminal`.

No `ApproachingLimit`, no `UsageLimit`, no new `Notification` variant carrying `rate_limits`. **Unchanged.**

### Notable new item in 2.1.221 (does not satisfy a re-check trigger)

The binary now exports four text-classification constants via the `@anthropic-ai/claude-agent-sdk` public API:

```text
USAGE_WARNING_PREFIXES:    ["You've used", "You're close to"]
USAGE_TRANSITION_PREFIXES: ["You're now using usage credits", "You're now using your usage allocation", …]
USAGE_LIMIT_ERROR_PREFIXES: (SDK-consumer constant, not a hook payload)
ORG_POLICY_LIMIT_PREFIXES: ["This service is disabled for your org"]
```

These are string-matching patterns for classifying user-facing chat messages. They are SDK utilities for downstream consumers, not hook events, not hook payloads, and not a machine-readable upstream signal reachable from a hook or session. They do not satisfy re-check trigger #3 (a proactive warning *event*) or trigger #4 (a machine-readable *export*).

### Safety.md status

`.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" is **unchanged**. Nothing built or changed here acts on a locally-derived estimate.

### What remains blocked

The pre-emptive wind-down (issue #824) is still not buildable: no re-check trigger has fired. The four triggers from the original audit still apply; this re-audit closes issue #835 on the "still no signal" branch.
