<!-- go-on-routing:begin -->
Route `kind:token-exhaustion`.

**Trigger:** 0.4 rank 3, the `token_exhaustion` class.

**Prerequisites:** Step 0 is complete: 0.2a passed, every probe ran, 0.4 selected this class, 0.5 found no matching receipt or `--again` was passed, the lane preflight resolved this module, and the live-work check ran.

**Review modules:** read `review:prepare` first. Its lifecycle-helper resolution and Step 0b context and authorship guard apply before the step the handoff entry's `needs` names, and its Step 1 guard runs before any commit or push, as that step states. Then read the module holding the named step: `review:prepare` for Step 1b, `review:respond` for Step 6 and Step 7. Before Step 6 or Step 7, run that module's Step 5 (read-only) so the resumed session reloads the sticky reviewer instead of polling the wrong bot. Step 5 sets only the reviewer here: on its exit `1` (no review yet) treat the reviewer as CR and still go to the step `needs` names, so a `continue_fixes` resume reaches Step 7 rather than waiting at Step 6. Continue in order from there.
<!-- go-on-routing:end -->

- **`token_exhaustion`** — read the entry's `phase`, `head_sha`, and `remaining_work`, then continue that phase: enter Steps 0b–10 at the step its `needs` names (`continue_polling` → Step 6, `continue_fixes` → Step 7, unpushed fixes → Step 1b). The parent's replacement-subagent path (`phase-protocols.md`) is unchanged and still preferred when a parent orchestrator is live — say so rather than racing it.
