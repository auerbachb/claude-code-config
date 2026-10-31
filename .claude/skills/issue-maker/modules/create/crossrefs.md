# Create: related issues and increment links

> Load only for: when the idea names related issue numbers or a sizing result requires a chain
> Prerequisites: create draft exists; batch module is loaded for chain-specific linking

## Step 8: Cross-references

Detect `#N` mentions in the user's description and verify each exists (`gh issue view N --repo "$REPO" --json number` succeeds). Add a `## Related Issues` section using phrasing that matches the user's intent:

- "related to #N" → `- Related to #N`
- "depends on #N" / "blocked by #N" → `- Depends on #N`
- "blocks #N" → `- Blocks #N`

### Linking an increment chain (sizing check failed)

File the increments **in order**, head first, so each one can reference the number of the increment before it. Every increment after the head gets a `## Related Issues` entry pointing at its **immediate predecessor** — not at the head, and not at all of them:

```markdown
## Related Issues

- Depends on #<previous increment>
```

This is the existing `- Depends on #N` phrasing above, reused deliberately rather than invented: `/pm` Step 1B.3 collects `depends on #N` as a blocked-direction marker, and `/wave` 5.1 consumes that same set and **excludes any candidate blocked by an open, unmerged issue.** A predecessor link is therefore what makes `/wave` admit only the chain head and serialize the rest — inventing a new marker would leave the chain looking parallelizable.

**Cap: at most 5 increments per ask without pausing.** Five is a chain; twenty is a confetti backlog nobody will triage. If an ask genuinely needs more than 5, **stop before filing anything** and say so — name the count you'd need and what the increments would be, and present the choice via **`AskUserQuestion`** when available (options: `"Re-cut to ≤5 increments (Recommended)"`, `"File all N increments"`; prose fallback in headless runs). This mirrors the Step 4 dedup pause bar: clear the bar and proceed silently, exceed it and ask first. See `ask-menu.md` for the full vehicle convention.

**Both modes stop at this bar.** It is one of rapid-fire's two hard bars, enumerated in the "Rapid-fire override" paragraph of the top-level rule — rapid-fire asks in one terse line instead of default's fuller framing, but it never files a 6+ chain unasked and never silently re-cuts one down to 5 on its own. Re-cutting changes what gets built; that call is the user's.

---
