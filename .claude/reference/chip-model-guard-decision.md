# Model-Guard Placement Decision (#601)

## Decision

**The model guard rides in both the chip `prompt` and the fallback block.** Every chip-launched or pasted coding thread carries a mandatory model-guard preamble, positioned immediately after the `**Model:** {MODEL} — {REASON}` line, defined once in `chip-launching.md` and inherited by reference — not restated — in all six canonical chip emitters: `/pm` (Step 3.1), `/prompt` (Step 6), `/start-issue` (Step 7), `/issue-maker` (Step 9c), `/wave` (Step 7.1), and `/harness-audit` (Step 5). Ad-hoc `spawn_task` offers inherit the same contract via `chip-spawn.md` (Issue #731).

**Amendment (#770) — the `**Model:**` value may be resolved rather than written.** `/harness-audit` joined as the sixth emitter with one difference: its recommendation is definitionally "the top of the fleet", not a per-task judgment, so writing a literal would guarantee staleness on the next fleet change. It resolves the name at run time via `.claude/scripts/model-fleet.sh` and carries no model literal at all. This changes **nothing** about the guard itself — same verbatim preamble, same first-line placement, same short-summary repetition, same pre-click warning. Only the provenance of the string differs. `chip-model-guard-lint.sh` splits emitters into literal and resolver classes accordingly, and forbids literals in the resolver class; the class table lives in `chip-launching.md` under "Literal vs resolved model names".

This redefines the fallback baseline. Before #601, `chip-launching.md` guaranteed fallback output was **byte-for-byte identical to pre-chip behavior** — a CLI thread could not tell the chip feature existed. That guarantee is retired. The new guarantee is **byte-identical to the chip `prompt`**: whatever a chip carries, the fallback block carries too, guard included. Print-on-demand replay stays pinned to the chip's actual `prompt` content, so replay, chip, and fallback block never diverge.

Policy: a hard stop on **any** mismatch, in either direction (over- or under-powered), with a single-line override. An explicit user reply (e.g. "continue anyway") proceeds on the current model; switching models and relaunching is the recommended path. A matching model — or a post-override continuation — proceeds with at most one status line and no further friction.

## Rationale

Two invariants existed before this ticket and a new preamble can preserve at most one of them:

- **(A) Chip `prompt` == fallback block.** The chip's `prompt` payload has always been defined as identical to what the fallback block would print inside its fence (`chip-launching.md`'s invocation table, since #555).
- **(B) Fallback block == pre-chip output.** Fallback mode was defined to be indistinguishable from the tool's behavior before chips existed at all.

Adding a guard that only some threads receive forces a choice: put it in the chip `prompt` only (preserves B, breaks A — the chip and the printed block diverge) or put it in both (preserves A, breaks B — fallback output is no longer what it was before chips shipped).

**The strongest "guard chip-only" argument, and why it loses:** a CLI/headless paste flow already has a manual checkpoint the chip flow lacks — the user opens the new thread themselves, so they can set the model before pasting. By that logic the guard is solving a chip-specific problem and doesn't belong in the fallback path at all. This argument loses because the checkpoint it describes is a *default*, not an enforced one — nothing stops a user from pasting a Heavy-tier block into an already-open Sonnet 5 thread, which is exactly the failure mode the guard exists to catch. More decisively, invariant (A) is architecturally load-bearing: AC5 of #601 pins print-on-demand replay to the chip's actual `prompt`, and `chip-launching.md` already treats "chip `prompt` byte-identical to fallback block" as the base contract three skills consume by reference. Fracturing that into "chip has X, fallback has X-minus-the-guard" would mean two representations per issue instead of one, undermining the single-sourced design #555 established. Between fracturing an architectural invariant and revising a behavioral guarantee that was never a design goal in itself (it was a byproduct of chips being purely additive), revising the guarantee is the smaller, more defensible cut. The guard is also universally beneficial in the fallback path, not merely tolerated there — it catches the same wrong-model paste mistake a CLI user can make.

**Model self-detection is best-effort.** There is no runtime mechanism for a thread to introspect its own active model — model identity is always asserted by the caller (the picker, the harness), never read back by the model itself. The guard therefore relies on the launched thread's own self-report of which model it believes it is running as, compared textually against the `**Model:** {MODEL}` line. This is a known limitation, not an oversight: if `spawn_task` later gains a model/effort parameter (the ticket's own "root cause is upstream" note), the guard becomes a pure safety net for the residual paste-flow case rather than the only defense, and this whole convention can simplify.

## Explicitly Rejected

- **Guard in chip `prompt` only** (mirroring how `/start-issue`'s `**Model:**` line was chip-only before this ticket) — rejected: breaks invariant (A), forces print-on-demand replay to pick between two non-identical artifacts, and leaves the fallback/paste path exposed to the same wrong-model mistake the guard exists to catch.
- **Deferring the guard until `spawn_task` gains a model parameter** — rejected: blocks a cheap, prompt-only mitigation on an upstream capability with no committed timeline; the ticket explicitly wants a self-enforcing preamble now, with the future parameter treated as a simplification, not a prerequisite.
- **Surfacing the model in the chip's `title` or `tldr`** (declined at ticket capture) — rejected: those fields are scanned pre-click, not enforced; a title mention doesn't stop a click on the wrong picker state the way a first-action stop inside the thread does.
- **A separate paste-block fallback reserved for tier-critical (Fable 5 / Heavy) work** (declined at ticket capture) — rejected: adds a second fallback shape to maintain for a subset of issues when one guard, applied uniformly, already covers the tier-critical case at hard-stop severity.

## References

- Issue [#601](https://github.com/auerbachb/claude-code-config/issues/601) — this decision
- `chip-launching.md` — canonical chip mechanics; defines the model-guard preamble this decision authorizes
- `.claude/skills/pm/SKILL.md` Step 3.1, `.claude/skills/prompt/SKILL.md` Step 6, `.claude/skills/start-issue/SKILL.md` Step 7, `.claude/skills/issue-maker/SKILL.md` Step 9c, `.claude/skills/wave/SKILL.md` Step 7.1, `.claude/skills/harness-audit/SKILL.md` Step 5 — the six canonical chip emitters that inherit the guard by reference; ad-hoc offers via `.claude/rules/chip-spawn.md`
- Issue [#770](https://github.com/auerbachb/claude-code-config/issues/770) — `/harness-audit` as the sixth emitter and the resolver-class amendment above
- `.claude/reference/harness-audit.md` — why that emitter offers a step-up chip instead of spawning the top tier unattended
- Issue [#731](https://github.com/auerbachb/claude-code-config/issues/731) — universal enforcement + conformance lint
- Issue [#735](https://github.com/auerbachb/claude-code-config/issues/735) — upstream ask for `spawn_task` `model` parameter
- `pm-handoff-chips-decision.md` — the house style this record follows (`## Decision` / `## Rationale` / `## Explicitly Rejected` / `## References`)
- Issue [#547](https://github.com/auerbachb/claude-code-config/issues/547) (closed) — model fleet reconciliation across selection surfaces, the related prior work this ticket builds on
