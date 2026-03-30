---
name: lessons
description: Summarize lessons learned from the current session — what went wrong, what patterns emerged, what to remember. Saves actionable insights to memory.
---

Reflect on the current session and extract reusable lessons before the thread is closed.

## Steps

### Step 1: Review the session

Look back at what happened in this session:
- What was the task? What was accomplished?
- What went wrong or was harder than expected?
- What patterns emerged (good or bad)?
- Were there any surprises — tools behaving unexpectedly, edge cases hit, workflow friction?
- Did any workarounds get used that should be codified?
- Were there any bugs, regressions, or close calls?

### Step 2: Categorize lessons

For each lesson identified, determine:

1. **Type** — which memory category fits best:
   - **feedback** — corrections to Claude's approach that should persist (e.g., "don't mock the DB", "always check X before Y")
   - **project** — facts about the project that affect future decisions (e.g., "module X is fragile when Y changes", "legal requires Z")
   - **user** — things learned about the user's preferences or expertise

2. **Actionability** — is this something that should change future behavior, or just an observation? Only save actionable lessons.

3. **Novelty** — is this already covered by existing memory? Check `MEMORY.md` before creating duplicates. If an existing memory should be updated, update it instead of creating a new one.

### Step 3: Save to memory

For each actionable, novel lesson:

1. Write a memory file to `~/.claude/projects/{project}/memory/` with proper frontmatter. Derive the filename by slugifying the `name` field (lowercase, spaces/hyphens to underscores, prefixed by type, e.g., `feedback_no_git_clean.md`):
   ```markdown
   ---
   name: <descriptive_name>
   description: <one-line description for relevance matching>
   type: <feedback|project|user>
   ---

   <lesson content>

   **Why:** <what happened that surfaced this lesson>
   **How to apply:** <when and where this should change behavior>
   ```

2. Add a pointer to `MEMORY.md` (the memory index at `~/.claude/projects/{project}/memory/MEMORY.md`) as a single bullet: `- [filename.md](filename.md) — one-line description`. If updating an existing memory, update the existing pointer instead of adding a duplicate.

### Step 4: Output summary

Present the lessons to the user in a concise format:

```
## Session Lessons

### Saved to memory:
1. **<lesson title>** — <one-line summary> (saved as <type>)
2. ...

### Observations (not saved):
- <things noted but not actionable enough to persist>
```

If the session was straightforward with nothing notable, say so: "Clean session — no new lessons to capture."

## Guidelines

- **Quality over quantity.** 1-3 strong lessons are better than 7 weak ones.
- **Be specific.** "CR sometimes re-raises findings when line numbers shift" is useful. "Code review can be tricky" is not.
- **Include the why.** A lesson without context is hard to apply later.
- **Don't repeat what's in the rules.** If something is already documented in `.claude/rules/`, it's not a lesson — it's a known procedure.
- **Don't log task completion as a lesson.** "We merged PR #40" is not a lesson. "Merging after a rebase requires waiting for a new CR cycle" is.
