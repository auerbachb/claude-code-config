# Batch and increment chains

> Load only for: the user supplied multiple issues, or sizing requires an increment chain
> Prerequisites: session state loaded; create module loaded for per-issue behavior; crossrefs module loaded only when linking a chain

## Step 6: Batch input

If the user describes multiple issues in one message (a numbered/bulleted list, or a `batch:` prefix), treat each as its own issue: run the full per-issue flow (reflect → dedup → draft → labels → auto-create → report) **sequentially**, one `gh issue create` per issue. After the last issue of the batch is filed, print the **canonical summary table defined in Step 9a** — one row per issue, in filing order, columns and derivations exactly as that step defines them. Print it once for the whole batch, not once per create.

**Order within a batch.** Earlier `Created #N: …` links are intermediate output. Hold the last issue’s link for Step 9’s closing order, and print it only once.

**Every issue is still created; the batch gets one inline-run offer after the last issue.** Step 9c owns the offer and its repo-wide cap check for both single issues and batches; place the offer or deferral before the closing table. The cap may defer execution, but it never prevents filing any issue. A separate-thread chip is available only on explicit request.

**Increment chains preserve order in that same inline-run offer.** The sizing check turns one oversized ask into up to five increment issues. The chain is ordered and its increments land in sequence, so Step 9c names the chain and its order; the launched thread's `/subagent` Step 6.0b serializes them from there.

---
