# Skill & Rule Authoring Patterns

On-demand authoring guidance for **writing effective skills and rules** in this
repo. CONTRIBUTING.md covers the *mechanics* (file paths, frontmatter fields,
symlink steps); this document covers the *judgment* — how to make a skill
discoverable and a discipline rule that actually holds under pressure.

Adapted for our conventions from [obra/superpowers `skills/writing-skills`](https://github.com/obra/superpowers/tree/main/skills/writing-skills)
(harvested via issue #417). That skill frames authoring as TDD-for-documentation
(pressure-test → write → close loopholes) and is available at runtime via the
superpowers plugin; read it for the full testing methodology. The patterns below
are the parts our own docs were missing.

Not auto-loaded. Read this when creating or revising a skill or rule.

## 1. Description = *when to use*, NOT *what it does*

The `description` field is how the model decides whether to load a skill. The
single highest-leverage authoring rule:

> **Describe the triggering conditions. Do not summarize the workflow.**

**Why it matters:** when a description summarizes the procedure, agents may follow
the *summary* and skip reading the skill body. Superpowers documented a case where
a description saying "code review between tasks" caused an agent to do **one**
review even though the skill body specified **two**; removing the workflow summary
fixed it. A description is a router, not an abstract.

```yaml
# BAD — summarizes the workflow; agent may act on this and never open the skill
description: Audit every review thread and CI check, fix all issues, push once
  per sweep, resolve threads, then re-sweep up to 5 times.

# GOOD — triggering conditions only; agent must read the body for the procedure
description: Use when a PR has unresolved review threads or failing CI checks and
  needs to be driven to a clean, merge-ready state.
```

**Caveat for our slash-command skills:** our descriptions double as `/command`
autocomplete help, so a little "what it does" is acceptable for operator
discoverability. The rule still applies to the *behavioral* part: lead with
**when to invoke**, and never let the description become a substitute for the
step-by-step body. When auditing an existing skill, check: *could an agent skip
the body and still "comply" with the description?* If yes, the description is
leaking workflow — trim it.

**Also:** third person, start with "Use when…", pack in real trigger
keywords (error strings, symptoms, tool names) an agent would search for.

## 2. Match the Form to the Failure

Before writing guidance, classify the *baseline failure* you are correcting. The
form that fixes one failure type measurably backfires on another.

| Baseline failure | Right form | Wrong form (backfires) |
|---|---|---|
| Knows the rule, skips it under pressure | Prohibition + rationalization table + red-flags list | Soft guidance ("prefer…", "consider…") |
| Complies, but output has the wrong shape (bloated, buried verdict, restates spec) | **Positive recipe / contract**: state what the output *is* — its parts, in order | Prohibition list ("don't restate", "never narrate") |
| Omits a required element from something it already produces | **Structural slot**: a REQUIRED field in the template they fill in | Prose reminder near the template |
| Behavior should depend on a condition | **Conditional** keyed to an observable predicate ("if the brief exists, reference it") | Unconditional rule + exemption clauses |

**Why prohibitions backfire on shaping problems:** under a competing incentive,
agents negotiate with "don't X". In superpowers' head-to-head wording tests, the
prohibition arm produced *more* of the unwanted content than a positive recipe —
worse than even no guidance. A recipe leaves nothing to negotiate: the output
matches the stated shape or it doesn't.

**Rules for whichever form you pick:**
- **No nuance clauses.** "Don't X unless it matters" reopens the negotiation.
  Express a real exception as its own conditional on an observable predicate.
- **Exemption clauses don't scope.** "This limit doesn't apply to code blocks"
  still suppresses code blocks. Restructure so the rule can't reach the exempt part.

## 3. Bulletproofing Discipline Rules

For rules an agent might rationalize around under pressure (our `safety.md`,
`main-hygiene.md`, merge-gate rules are exactly this kind):

- **Close loopholes explicitly.** Don't just state the rule — forbid the specific
  workarounds. "Delete it." → "Delete it. Start over. Not as 'reference', not
  'adapt it while rewriting', not 'look at it once'. Delete means delete."
- **Letter vs spirit.** State early: *violating the letter of the rule is
  violating the spirit of the rule.* This cuts off a whole class of "I'm following
  the intent" rationalizations.
- **Rationalization table.** Capture every excuse seen in testing as a row:
  `| Excuse | Reality |`. Our `Always / Ask first / Never` rule headers already
  do the front-matter version of this; the table handles the edge cases.
- **Red-flags list.** A short "STOP if you catch yourself thinking…" list lets an
  agent self-check mid-rationalization.

These belong in the relevant **rule file** (for auto-loaded discipline) or skill,
not here.

## 4. Token / Word Efficiency

Skills load on invocation; rules load **every turn** and share a hard
`rule-lint` budget (see CLAUDE.md "Rule File Size Guidelines"). Be ruthless:

- **Move detail out of the auto-loaded path.** Heavy reference, long commands, and
  schemas go in `.claude/reference/` and are linked, not inlined — that is what
  this directory is for.
- **Cross-reference instead of repeating.** Name the other rule/skill; don't
  restate its content. Avoid `@`-style force-loading links that burn context.
- **One excellent example beats five mediocre ones.** Don't write the same
  pattern in multiple languages or as a fill-in-the-blank template.
- **Verify:** `wc -w` the file; for rules, run `.github/scripts/rule-lint.sh`.

## 5. When NOT to Write a Skill or Rule

- **One-off solution** — it's a task, not a reusable technique.
- **Mechanically enforceable** — if a hook, regex, or CI check can enforce it,
  automate it; reserve docs for judgment calls. (See our `config-protection`
  backlog item in `skill-repo-diff.md` for an example of converting an advisory
  rule into mechanical enforcement.)
- **Already covered** — a runtime plugin skill or an existing rule already does
  it. Duplicating splits the source of truth.
- **Project-specific trivia** — put it in CLAUDE.md/rules, not a portable skill.

## Authoring Checklist

- [ ] Description leads with *when to use*; an agent could not "comply" by reading
      the description alone (see §1).
- [ ] Guidance form matches the baseline failure type (see §2).
- [ ] Discipline rules close loopholes + include a rationalization table /
      red-flags list where pressure is likely (see §3).
- [ ] Auto-loaded footprint minimized; heavy material lives in `reference/` (§4).
- [ ] Confirmed this isn't a duplicate or a mechanically-enforceable check (§5).
- [ ] Mechanics done per CONTRIBUTING.md (frontmatter, rule index, symlink).
