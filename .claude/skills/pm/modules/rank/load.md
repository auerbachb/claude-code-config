<!-- pm-routing:begin -->
Route `rank:load`. Load the project config, operator order, pause and scope before fetching or composing ranking output.
<!-- pm-routing:end -->
### 1B.1: Load or bootstrap pm-config.md

```bash
# Probe for the config file via the shared parser. rc=2 means the file is missing.
"$PM_CONFIG_GET" --list >/dev/null 2>&1
LIST_RC=$?
```

- If `LIST_RC == 2` (**BOOTSTRAP**): run the same bootstrap logic as `/pm-handoff` Step 2 (detect infrastructure, map architecture, generate pm-config.md). Then continue.
- Otherwise (**CONFIG_EXISTS**): parse sections via `--list` + per-section `--section <name>` as in 1A.1.

Extract the `## OKRs` section via `"$PM_CONFIG_GET" --section OKRs`. If `rc=0` **and** the body does not start with "No OKRs set", set `OKR_MODE=true`.

<!-- pm-routing:begin -->
At this gate, read `shared:priority` and apply its existing instructions.
<!-- pm-routing:end -->
**Read the refill pause before dispatching anything — and before composing the ranking output above**, the way Step 1C runs ahead of everything else in this step. Cold start is the default mode for a bare `/pm`, so this path runs in repos where a human already said "stop" and that stop was persisted. The resume path reads it in 1A.2 and this path reads it here — dispatching without the same read is how an inverted default silently relaunches against an explicit stop:

```bash
REPO_KEY=$("$SESSION_STATE_SH" --repo-key)
RC=0
SCOPE_RC=0
PAUSED=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].refill.paused") || RC=$?
SCOPE=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].refill.scope" 2>/dev/null) || SCOPE_RC=$?
# A requested window that could not be parsed or persisted blocks dispatch (Step 0b).
[[ "${WINDOW_PARSE_FAILED:-}" == "true" ]] && PAUSED=true
```

Interpret **both** reads with **3.4's table, unchanged**: `RC=0` + `true` → paused; `RC=0` + `false`/`null`, or `RC=3` (no state file ever written) → dispatch; any other `RC` → unreadable state is **not** permission, so treat it as paused and say the state was unreadable. `SCOPE_RC` gets the same treatment — a failed scope read yields an empty `$SCOPE`, which is indistinguishable from "no narrowing exists" and would dispatch the full backlog, so anything but `0` or `3` is paused-and-unreadable too. When paused, rank and report only — launch nothing, and say the pause out loud with how to lift it ("Refill is paused (you stopped it earlier) — say resume to restart it"). A non-null `$SCOPE` is a narrowing, not a stop: drop every candidate outside it **before** ranking decides anything, so the recommendations the user reads never contain work they excluded — filtering after the list renders surfaces exactly that work. Name the scope in the report. **This gate binds the default dispatch only.** A live in-chat request to start a specific issue is the human acting, not refill — it proceeds, and it does not on its own lift the pause for future refills. Step 0's degraded rules still win over this default: no `SESSION_STATE_SH` means rank and report without starting pipelines, and an unreadable `chip-launching.md` stops chip offers before they happen.

**An unreadable operator priority is a stop of the same kind** (`PRIORITY_UNREADABLE=true`, 1B.1a): rank and report, launch nothing, and say so with 1B.1a's one-line warning. It lifts on its own once the file reads cleanly again (fixed, or removed) — no human resume is needed, because nothing was paused on purpose.

