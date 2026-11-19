# Batch and increment chains

> Load only for: the user supplied multiple issues, or sizing requires an increment chain
> Prerequisites: session state loaded; create module loaded for per-issue behavior; crossrefs module loaded only when linking a chain

## Step 6: Batch input

If the user describes multiple issues in one message (a numbered/bulleted list, or a `batch:` prefix), treat each as its own issue: run the full per-issue flow (reflect → dedup → draft → labels → auto-create → report) **sequentially**, one `gh issue create` per issue. After the last issue of the batch is filed, print the **canonical summary table defined in Step 9a** — one row per issue, in filing order, columns and derivations exactly as that step defines them. Print it once for the whole batch, not once per create.

**Order within a batch.** Earlier `Created #N: …` links are intermediate output. Hold the last issue’s link for Step 9’s closing order, and print it only once.

**Every issue is still created; the batch gets one inline-run offer after the last issue.** Step 9c owns the offer and its repo-wide cap check for both single issues and batches; place the offer or deferral before the closing table. The cap may defer execution, but it never prevents filing any issue. A separate-thread chip is available only on explicit request.

**Increment chains preserve order in that same inline-run offer.** The sizing check turns one oversized ask into up to five increment issues. The chain is ordered and its increments land in sequence, so Step 9c names the chain and its order; the launched thread's `/subagent` Step 6.0b serializes them from there.

## Step 6b: Open the coherence set before the first create

A batch or chain is read back as a whole once its last member is filed (`create:coherence`). That pass needs to know which rows belong to this filing and what they were cut from, after compaction as well as in context, so the set is recorded explicitly — never inferred from titles, labels, timestamps, or the word "epic".

Run this block **before the first create** of every batch, and again when any request (or a single ask) becomes a chain — with `IS_CHAIN_SET=true`, before `create:increment-draft`'s identity block. Set `SOURCE_ASK` to the user's original ask text, verbatim (the whole batch message for a batch). A set already open is kept only when this run continues the **same** filing — a chain inside the open batch, `create:doc-gate` adding the document reference, or a recovered session resuming it — and the caller says so with `SET_CONTINUE=true`. A chain inside a batch then joins the batch's set and the pass runs once for the whole filing. A new filing that finds a set still open stops instead: an unfinished earlier filing must reach its coherence step (or be closed) first, so two filings never share one set or one source ask.

<!-- test-anchor: issue-maker-coherence-open-set -->
```bash
: "${SOURCE_ASK:?capture the original ask text before opening the set}"
SET_ID=$(python3 -c 'import uuid; print(uuid.uuid4())') || exit 1
set_log 'if .active_set != null and .active_set.repository != $repo then error("a coherence set is still open for another repository; finish it there first")
  elif .active_set != null and $continue != true then error("a coherence set is still open from an unfinished filing; finish or close it before starting another")
  elif .active_set != null then .active_set.has_chain = (.active_set.has_chain or $chain)
    | if $ref != "" then .active_set.source.ref = $ref else . end
  else .active_set = {set_id:$id, repository:$repo, has_chain:$chain,
    source:{ask:$ask, ref:(if $ref == "" then null else $ref end)}, review:null, applied_fixes:[]} end' \
  --arg id "$SET_ID" --arg repo "$REPO" --arg ask "$SOURCE_ASK" --arg ref "${SOURCE_REF:-}" \
  --argjson chain "${IS_CHAIN_SET:-false}" --argjson continue "${SET_CONTINUE:-false}" || {
  echo "ERROR: could not open the coherence set; do not file the first member" >&2
  exit 1
}
```

`SOURCE_REF` is empty until a document exists. `create:doc-gate` reruns this block with `SOURCE_REF` set to the approved document's location (`#<parent> § PRD`, the shared doc link, or the repo path) so the pass reads the set against the document rather than the ask. A single issue never loads this module, so it never opens a set and never gets a pass.

---
