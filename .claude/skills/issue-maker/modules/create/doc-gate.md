# Create: document gate before an oversized chain

> Load only for: the sizing check needs more than five increments, or the ask carries open design decisions its body cannot settle
> Prerequisites: create reflection is complete and the increment count is known; nothing is filed yet

An ask that fits one chain (five increments or fewer) with no open design decision never loads this module: it files exactly as before, with no question and no output from here. This gate replaces the count-only "more than 5" question that used to open Step 8's cap.

<!-- test-anchor: issue-maker-doc-gate-tiers -->
## The tiers — the one written definition

Every other mention of these tiers cites this section rather than restating it.

| Tier | Fires when | Recommended option |
|------|-----------|--------------------|
| **Fits a chain** | Five increments or fewer **and** no open design decision | None — the gate does not fire |
| **Large** | More than five increments, **or** open design decisions the body cannot settle | PRD first |
| **Very large** | Large, **and** the ask is greenfield (no existing app, product or subsystem to extend) or its architecture is still unchosen | Design doc plus PRD first |

- **An open design decision** is a choice that changes what gets built and that neither the ask nor the target repo settles — which datastore, which product surface owns a flow, whether two features share a model. A wording or naming choice is not one.
- **Sizing alone opens the gate.** The increment count comes from the sizing check (`/subagent` Step 4 criterion 3 per increment, cited from the create reflection module); the design-decision test comes from what the ask describes. **Nothing here reads the word "epic"**, or any other title word, body keyword, or label: an ask titled "epic new button" that is one small change files as one issue, and an untitled eight-slice ask still reaches the gate. Labels stay a tie-break for the tier row inside the sizing check, never a trigger for this gate.
- **Greenfield or architecture-undecided** is judged from the work the ask describes, after the gate has fired on sizing. It only chooses which option is recommended; it never opens the gate by itself.

## The one question

Stop before filing anything. Ask once through `AskUserQuestion` (vehicle: `ask-menu.md`; prose fallback only when headless), recommended option first, naming the increment count and any open decisions:

- Large: `"Write a PRD first (Recommended)"`, `"Design doc + PRD first"`, `"File as-is"`
- Very large: `"Design doc + PRD first (Recommended)"`, `"Write a PRD first"`, `"File as-is"`

**Rapid-fire stops here too**, in one terse line: `Needs 8 increments (open: datastore choice) — PRD first, design doc + PRD, or file as-is?` It is rapid-fire's second hard bar (create reflection module).

**File as-is** keeps today's behaviour. With more than five increments it continues to the existing re-cut choice in Step 8 (`create:crossrefs`); with five or fewer (the gate fired on open decisions alone) it files the ordinary chain or single issue and names each open decision in the decision points (Step 9a).

## The document path

1. **Pick where the document lives** — one question, recommended first:
   - `"Parent issue body (Recommended)"` — the document is a `## PRD` (and `## Design doc`) section of the tracking parent, between `## Proposed solution` and `## Acceptance Criteria`. Always available and durable; children cite `#<parent> § <heading>`.
   - `"Shared doc"` — offered only when this session has a docs tool or skill that creates a shareable document; children cite its link and heading.
   - `"Repo file"` — the user names the path (default `docs/prd/<slug>.md`, `docs/design/<slug>.md`). Write it only into a checkout of the target repo on a non-default branch (never onto `main`); otherwise say so and ask again. The file is left uncommitted; landing it is the user's ordinary repo work. Children are **not filed** until the file on the default branch (fetched first, read with `git show origin/<default>:<path>`) matches the approved draft. An existing path with older text does not count. Until then, file only the parent and checkpoint `file children after <path> lands` as the next step, so no child can start without its document. Children cite `<path> § <heading>`.
2. **Write it together.** When `doc-coauthoring` is in the skill list, invoke it for this step; otherwise draft inline. Skeletons, each heading a `###` so children can cite it:
   - **PRD:** Goals · Users and problems · Requirements (numbered `R1`, `R2`, …) · Non-goals · Open decisions · Milestones.
   - **Design doc** (written first, then the PRD): Context · Options considered · Decision · Components · Data and interfaces · Risks.
   Show the draft and ask `"Cut issues from this (Recommended)"` / `"Revise"`. Any open decision still unsettled is recorded under Open decisions and becomes its own child (a decision spike) rather than a buried assumption.
3. **Cut the children from the document**, in dependency order, each one the normal 7-section shape plus `create:increment-draft`'s increment rules (title `{i}/{n}`, boundary line, bound at or under `INCREMENT_BOUND_MIN`). Each child's `## Background` opens with `Cut from <document> § <heading>.` naming the exact section. File at most five children now; when the document yields more, list the rest under `## Not yet cut` in the parent (plain bullets, never checkboxes — running more than five children in waves is `/pm`'s job, not this skill's).

## The tracking parent

File it **before** the children so each child can point at it; it never depends on them and they never `Depends on` it (an open parent would hold the chain forever).

- **Identity first.** Run `create:increment-draft`'s chain-identity block with `TOTAL` = the child count, then file the parent with `IS_INCREMENT=true`, `POSITION=0`, `CHAIN_ROLE=parent`. `create:file` adds `role:"parent"` to its chain record, so the session log row is `{chain_id, position:0, total, role:"parent"}` — the marker `update:edit` and `retract:close` read. Then reset `CHAIN_ROLE=""` and file the children at positions 1…N exactly as a chain does today.
- **Body.** Seven sections plus the footer. Background links the document; `## Estimate` is the sum of the children's estimates, with one sentence saying the parent is tracking-only and never a pipeline. No closing keyword anywhere points at the parent — not in its own body, not in any child.
- **Record the planned scope on the parent row.** Right after the parent's session-log row is recorded (Step 9) and before the first child is drafted, write how much the document plans: `PLANNED_CHILDREN` is every child the document yields, `NOT_YET_CUT` the number of bullets going under `## Not yet cut` (zero when all fit in this filing). This record, and nothing about the issue's wording, is what `create:epic-offer` reads at the end of the session. A failed write stops before any child is filed, with the parent named and this write as the checkpointed next step; never re-file the parent.

  <!-- test-anchor: issue-maker-epic-scope-record -->
  ```bash
  : "${PARENT_N:?record the tracking parent first}"
  [[ "${PLANNED_CHILDREN:-}" =~ ^[0-9]+$ && "${NOT_YET_CUT:-}" =~ ^[0-9]+$ ]] || { echo "ERROR: planned and not-yet-cut counts must be whole numbers" >&2; exit 1; }
  set_log "$MINE_DEF"'([.issues[] | mine | select(.origin == "create" and .number == ($n|tonumber) and (.chain.role // "") == "parent")] | length) as $hits |
    if $hits != 1 then error("tracking parent row not found in this session") else
    (.issues[] | mine | select(.origin == "create" and .number == ($n|tonumber) and (.chain.role // "") == "parent") | .epic_scope) =
      {planned:($planned|tonumber), not_yet_cut:($cut|tonumber)} end' \
    --arg repo "$REPO" --arg n "$PARENT_N" --arg planned "$PLANNED_CHILDREN" --arg cut "$NOT_YET_CUT" || exit 1
  ```

- **Seed the checklist on the parent.** Right after the parent's create is confirmed, write an empty `## Increment chain` section (heading and tracking sentence, no boxes) before the footer, so a parent still waiting for its children is recognizable from GitHub alone.
- **Children link back** in `## Related Issues`: `- Parent: #<parent>` beside the usual `- Depends on #<predecessor>` — the marker `/subagent` Phase C Completion step 4 reads to tick the parent's checklist and close it when the last child merges.
- **Checklist as each child files.** After each child's create is confirmed, and before the next child is drafted, fetch the parent body and remove any earlier `## Increment chain` section, from its heading up to the next `## ` heading or the footer, whichever comes first, so later sections survive a retried write. Insert the same shape `/subagent` Step 5.1 writes, with heading `## Increment chain`, one tracking sentence, then `- [ ] #<child>` for every child filed so far, in order. The parent then always lists the confirmed children, so another session can rebuild the chain from it even when filing stopped part-way. Put it directly before the `_Captured via /issue-maker._` footer so the footer stays the last line, and write it with `gh issue edit --body-file`. If this write fails, stop with the parent and children named and the checklist write as the checkpointed next step; never re-file children.

Report once, on the parent: the tier, the option chosen, the document location, and the children in order. The Step 9a table lists the parent first.

**Point the coherence pass at the document.** The parent and children form one set (`batch:chain` Step 6b, opened with `IS_CHAIN_SET=true` before the parent is filed). As soon as the document's location is known — right after the parent's create for the parent-body option — rerun that block with `SET_CONTINUE=true` and `SOURCE_REF` set to it (`#<parent> § PRD`, the shared doc link, or the repo path). After the last child is filed, `create:coherence` then reads the children against the document rather than the original ask, and treats the parent's `## Not yet cut` list as deferred, not missing.
