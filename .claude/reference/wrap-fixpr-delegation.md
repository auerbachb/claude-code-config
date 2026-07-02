# `/wrap` → `/fixpr` Delegation Contract

Full contract extracted from `.claude/rules/phase-protocols.md` (issues #452 / #455). The rule file keeps a pointer; this file holds the detailed handoff semantics.

`/wrap` Step 2.1 delegates recovery to the **full** `/fixpr` workflow (not a wrapper) — including when unresolved review threads are the only blocker (#455). The handoff is the `/fixpr` exit report, never a new contract:

1. **Parse the `=== fixpr complete ===` footer.** Grep `FIXPR_WRAP_STATUS:` (machine token, mirrors `Status:`) and `FIXPR_WAIT_SUMMARY:` (`iterations=N total_wait_secs=S final=…`). Echo both into the cycle heartbeat; append to `WRAP_RECOVERY_AUDIT`.
2. **Trust the verdict (#454).** `/fixpr` already waited on bots + CI for the new SHA. `/wrap` re-fetches HEAD and re-runs `merge-gate.sh` **immediately** — no `/wrap`-side sleeps or polls.
3. **Bounded — never infinite.** One `/fixpr` invocation per recovery iteration; `/wrap` caps iterations at `WRAP_RECOVERY_MAX_ITERATIONS` (5) and `/fixpr` self-caps at `FIXPR_MAX_ITERATIONS` (5). `THREADS_STUCK`/`NEEDS_HUMAN_REVIEW`/`CONFLICTS`/`CI_FAILING` are terminal stops (list residual threads). Never resolve a thread without `/fixpr`'s code-verification.
