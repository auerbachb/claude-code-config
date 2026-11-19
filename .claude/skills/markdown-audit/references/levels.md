# markdown-audit — level rubric and finding format

Read by `/markdown-audit` Step 3 when it builds agent briefs. Paste the parts for
the levels in range into each brief; the agent sees nothing else.

## Units

The helper (`mdaudit.py segment`) fixes every unit's line range, so two runs see
the same units. Fenced code is fence-aware (matched character and minimum
length); headings are ATX (`#`) only — Setext (underlined) headings are not
recognised. Frontmatter and HTML comments are kept out of the structure.

- **Sentence** — no helper unit. Locate a sentence by the first physical line it
  starts on; a range covers the lines it spans.
- **Block** — a blank-line-separated paragraph, list, table, heading line or
  whole fence.
- **Section** — a heading to the line before the next heading of the same or a
  higher level.
- **Page** — one screen: 50 lines, or the content under one top-level heading,
  whichever is smaller. Top-level is the shallowest heading level used at least
  twice (a lone title does not make the whole file one page). Pages break only
  between blocks, so a single block longer than 50 lines is one page.
- **Document** — the whole file.
- **Group / repo** — a candidate pair from `mdaudit.py pairs`, with the line
  ranges where the two files share wording or identifiers.

## What each level asks

| # | Question | Valid evidence | Typical actions |
|---|----------|----------------|-----------------|
| 1 | Does each sentence say something the reader needs, once? | the sentence repeats one nearby or elsewhere in the file; it states what the next sentence shows; it hedges or narrates without instructing | cut, keep |
| 2 | Does the block make one point, without restating its neighbours? | two blocks carry the same point; a block mixes two points that belong apart | cut, merge (into the neighbour), move, keep |
| 3 | Does the section belong in this file, in this order? | the section serves another file's job; it is out of step order; it repeats an earlier section | cut, merge, move (name the destination file and heading), keep |
| 4 | Does the page hold together as one screen of thought? | the page switches topic midway; the reader needs a later page to follow it | move, merge, keep |
| 5 | Does the document do one job; is anything dead? | a section no caller reaches; a flag or step the code no longer has; two jobs in one file | cut, move, keep |
| 6 | What overlaps with sibling files; what should merge? | the same instructions in both files; a sibling restates what the other owns | merge (name the owning file), cut, keep |
| 7 | What is duplicated or contradicted across the repo? | the same rule in two homes; two files giving conflicting instructions — quote both | merge, cut, keep |

Judge only the levels in range. A lexical match from `pairs` is a reason to read
both ranges, not a finding: overlapping topic is not redundancy.

## When to keep

Propose `keep` (and say why) when a passage that looks redundant is:

- a deliberate summary that helps a reader navigate (an overview that points at
  the detailed steps below it);
- a non-negotiable rule restated where it is enforced;
- a caller contract — text another file, script or test depends on verbatim
  (test anchors, verbatim blocks, flag tables a lint reads);
- an intentional delegation, where one file hands a job to another and names
  it (for example `/merge` and `/wrap` sharing gate wording).

`keep` rows appear in the report's "What NOT to change" list and count zero
words removed.

## Finding format

One JSON object per line. Every finding names the file, a line or line range,
an action, and a one-line reason (at most 240 characters, no line breaks).

```json
{"level": 3, "file": ".claude/skills/x/SKILL.md", "start": 40, "end": 58, "action": "move", "target": ".claude/reference/x.md — new section 'Recovery'", "reason": "Recovery detail serves the reference doc, not the step list"}
{"level": 6, "file": ".claude/skills/merge/SKILL.md", "start": 12, "end": 30, "other_file": ".claude/skills/wrap/SKILL.md", "other_start": 20, "other_end": 41, "action": "merge", "target": ".claude/skills/wrap/SKILL.md", "reason": "Both restate the merge gate; wrap owns it"}
```

- `level`: 1–7 or the level name.
- `action`: `cut`, `merge`, `move` or `keep`. `merge` names the target file
  (and section); `move` names the destination. Both go in `target`.
- Levels 6–7 also name `other_file` with `other_start`/`other_end`. A
  contradiction quotes both conflicting instructions in the reason.

## Coverage lines

One JSON object per reviewed item, so unreviewed items are reported as unknown:

```json
{"file": ".claude/skills/x/SKILL.md", "level": 2, "status": "reviewed"}
{"pair": [".claude/skills/merge/SKILL.md", ".claude/skills/wrap/SKILL.md"], "level": 6, "status": "reviewed"}
```

A pair the agent could not judge is written with `"status": "unreviewed"`.
