# Create: increment-specific drafting

> Load only for: the sizing check has determined that this issue should become an increment chain
> Prerequisites: create reflection/draft is complete; batch/chain operation selected

## Initialize chain identity before the first duplicate check

After the sizing/cap decision and before any member's dedup, initialize one identity for the new chain and persist it. `TOTAL` is the selected increment count. This block is **new-chain only**; on recovery restore `CHAIN_ID` and `TOTAL` from `.active_chain`, set `IS_INCREMENT=true`, and derive the next position from the confirmed rows sharing that id. Never mint a second id for resumed siblings.

```bash
IS_INCREMENT=true
CHAIN_ID=$(python3 -c 'import uuid; print(uuid.uuid4())') || exit 1
POSITION=1
set_log '.active_chain = {chain_id:$id, total:$total, repository:$repo}' \
  --arg id "$CHAIN_ID" --argjson total "$TOTAL" --arg repo "$REPO"
```

Keep that identity for every member and increment `POSITION` after each confirmed filing. After all `TOTAL` members are recorded, clear `.active_chain`; the rows retain their chain objects for retraction/recovery. For a genuinely new standalone ask, reset `IS_INCREMENT=false`, `CHAIN_ID=""`, and `CHAIN_JSON=null` before drafting so a prior chain cannot leak into it. A restarted active chain restores its identity instead of resetting it.

### Increment issues — the variant shape for a chain (sizing check failed)

When the top-level rule's sizing check fails, each increment is a normal 7-section issue with two additions to the AC section. An increment is not a sub-task: it is a **complete, independently mergeable issue** that happens to be one slice of a larger theme.

**Title — carry the parent theme and the position.** `{Parent theme} {i}/{n}: {what this slice delivers}` — e.g. `Landing page 1/4: hero + layout shell`, `Landing page 2/4: services page`. The theme prefix is what keeps a backlog of increments scannable instead of looking like four unrelated tickets.

The existing **≤70-character** title rule still applies to the composed whole, so budget for all three parts rather than trimming only the tail:

1. **Reserve the `{i}/{n}` marker** — never trimmed, never abbreviated; it is what makes the chain readable.
2. **Bound the parent theme** to roughly the first 25 characters, and keep it identical across every increment in the chain — a theme that shifts wording between increments defeats the point of having one.
3. **Trim the slice description** to fit what's left.

If the title still exceeds 70 after all three, the theme itself is too long — shorten it once, apply that shortened form to the whole chain, and note the trim in the decision points.

**Acceptance Criteria — one boundary line, always.** Every increment's `## Acceptance Criteria` opens with a line stating where the slice stops. Non-final increments hand the remainder forward; the **final** increment has nothing to hand forward and says so instead:

```markdown
- [ ] This increment ends at <the boundary>; <what's explicitly out of scope> lands in the next increment.
```

```markdown
- [ ] Final increment — this completes <the parent theme>; it ends at <the boundary>, with nothing deferred past it.
```

The boundary line is what keeps a pipeline from scope-creeping across the whole theme — without it, an agent picking up increment 1 has nothing telling it to stop at the hero. Write the boundary in concrete terms ("ends at a static hero and layout shell — no services content, no form"), never as a vague "part 1 of the work." Never point the last increment at a successor that will not exist.

Everything else is unchanged: the same functional-first tone, the same seven sections (including `## Estimate` — use the increment's own tier), the same labels, the same capture-mode footer.

**Every increment's own bound must be at or under `INCREMENT_BOUND_MIN`** (default 120 — resolved by the block in the top-level rule's sizing check, never typed in). Against the seed table **at that default** that means the **Light** row, `Est: 60–90 min · plan on 90`; the bound is what governs, not the row, so a knob set under 90 admits no seed row at all and the increment carries an explicit tighter estimate or is not cut yet. This binds chains from *either* trigger, not just the time one: a slice that needs the Standard row's 180 is a slice cut too coarse — re-cut the boundary rather than publishing an over-bound increment, and if it genuinely cannot be cut finer, say so in the decision points rather than letting the number slide.

**Capture-mode footer:** append a trailing line to every created body so capture-mode issues are identifiable:

```
_Captured via /issue-maker._
```
