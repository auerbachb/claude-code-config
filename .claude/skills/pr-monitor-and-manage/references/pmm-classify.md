# PMM Classification Detail

Reference doc for `.claude/skills/pr-monitor-and-manage/SKILL.md`. Contains the
verbose rationale for the per-PR decision tree, the VERDICTS_JSON/findings
accumulation protocol, the Step 3 refinement pass, Step 3.6 merge-sequencing
implementation, and the Step 4 heartbeat/quiet-tick definition.

---

## Step 3: Gather per-PR state + classify

**Refresh `HARD_BLOCK_JSON` immediately before the per-PR loop** so Step 2.5 `blocked`/`crashed` persists from earlier in this same tick are visible to the decision tree (the Step 2.5 tick-start load is stale once Step 2.5 writes new entries):

```bash
HARD_BLOCK_JSON=$("$SESSION_STATE_SH" --get '.pmm_hard_block // {}' 2>/dev/null || echo '{}')
```

This step performs no PR mutations or dispatches: it gathers state, computes verdicts, and may persist orchestration bookkeeping (e.g. Step 3.6's `.pmm_merge_holds`). PR mutations and dispatches happen in **Step 5**, after the heartbeat/table prints (Step 4). This ordering is required so the classification is always visible *before* any long-running dispatch.

For **each** PR number, gather state. Run the per-PR fetches **in parallel across PRs** (one batch of background jobs, then collect), since they are independent network calls.

For a single PR `$N` (with `$HEADREF` = its `headRefName` from the Step 2 `$PR_LIST`):

```bash
# Gate verdict — single source of truth for merge readiness, CI, merge_state,
# review_decision, human_changes_requested, stale_bot_changes_requested_count.
GATE=$("$MERGE_GATE_SH" "$N"); GATE_EXIT=$?
GATE_BY_PR[$N]="$GATE"   # retain per-PR — Step 5c/5d look up THIS PR's gate by
                          # number rather than relying on a loop-scoped $GATE,
                          # which is only valid for whichever PR Step 3 last
                          # iterated and goes stale/wrong once other steps
                          # iterate their own PR lists.
# Linked issue for the Issue column (exit 1 = no link, expected).
# --first: the column holds one primary issue; default mode is set-valued (#1492).
ISSUE=$("$PR_ISSUE_REF_SH" --first "$N" 2>/dev/null || true)
# Unresolved review threads (GraphQL — covers every bot/human author).
UNRESOLVED=$(gh api graphql -f query='
  query($owner:String!,$repo:String!,$n:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$n){
        reviewThreads(first:100){ nodes { isResolved } } } } }' \
  -F owner="$OWNER" -F repo="$REPO" -F n="$N" \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)]|length' \
  2>/dev/null || echo "?")
```

Pull the fields the table and decision tree need out of `$GATE`:

```bash
MET=$(jq -r '.met' <<<"$GATE")
MERGE_STATE=$(jq -r '.merge_state' <<<"$GATE")          # CLEAN|BEHIND|BLOCKED|...
MERGEABLE=$(jq -r '.mergeable' <<<"$GATE")              # MERGEABLE|CONFLICTING|UNKNOWN
REVIEW_DECISION=$(jq -r '.review_decision' <<<"$GATE")  # APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED
CI_FAILING=$(jq -r '.ci_status.failing' <<<"$GATE")
CI_INPROG=$(jq -r '.ci_status.in_progress' <<<"$GATE")
CI_PASSING=$(jq -r '.ci_status.passing' <<<"$GATE")
HUMAN_CR=$(jq -r '.human_changes_requested | join(",")' <<<"$GATE")
STALE_BOT_CR=$(jq -r '.stale_bot_changes_requested_count // 0' <<<"$GATE")
```

### Reviewer engagement scan (display only — issue #1582)

The all-open-PRs reviewer-coverage matrix the retired `/monitor` skill used to render. It answers one question the gate does not: which of the four AI reviewers has not shown up on **this** HEAD. It is computed here, rendered in Step 4, and read by nothing else — no verdict, no dispatch, no trigger depends on it.

Run the shared state helper **once** per PR; it already aggregates the three comment endpoints plus check-runs and commit statuses from a single HEAD-SHA pull. Do **not** re-issue per-PR REST loops for this.

```bash
BUNDLE=$("$PR_STATE_SH" --pr "$N" 2>/dev/null) || BUNDLE=""
```

HEAD scoping is the point: a reviewer that only ran on an older commit must read ❌ so the gap is visible after a push. Check-runs and commit statuses in the bundle are already HEAD-pulled; reviews and inline comments are filtered on `commit_id == head_sha`; conversation comments carry no `commit_id`, so they count only when the body names the HEAD SHA (full or short).

```bash
engagement_matrix() {  # $1 = pr-state.sh bundle JSON ("" or unparseable → all "?")
  local bundle="$1"
  if [[ -z "$bundle" ]]; then
    printf '%s' '{"coderabbit":"?","codeant":"?","bugbot":"?","graphite":"?"}'
    return 0
  fi
  jq -c '
    def reviewers: [
      {key:"coderabbit", login:"coderabbitai[bot]", needles:["coderabbit"]},
      {key:"codeant",    login:"codeant-ai[bot]",   needles:["codeant"]},
      {key:"bugbot",     login:"cursor[bot]",       needles:["cursor","bugbot"]},
      {key:"graphite",   login:"graphite-app[bot]", needles:["graphite"]}
    ];
    # Pure-acknowledgment comments that must NOT count as engagement.
    def is_ack($body):
      ($body // "") as $b
      | ($b == "")
        or ($b | test("actions performed"; "i"))
        or ($b | test("full review triggered"; "i"))
        or ($b | test("actionable comments posted:\\s*0\\b"; "i"))
        or ($b | test("no actionable comments were generated"; "i"))
        or ($b | test("rate limit"; "i"));
    . as $b
    | (.pr.head_sha // "") as $head
    | ($head[0:7]) as $short
    | reviewers
    | map(. as $r
        | {
            has_review:
              ([$b.comments.reviews[]?
                 | select(.user.login == $r.login and (.commit_id == $head))] | length > 0),
            has_check:
              (([$b.check_runs.all[]?
                 | (.name // "" | ascii_downcase) as $n
                 | select(any($r.needles[]; . as $needle | $n | contains($needle)))] | length > 0)
               or ($r.key == "coderabbit" and ($b.bot_statuses.CodeRabbit != null))),
            has_finding_comment:
              (([$b.comments.inline[]?
                 | select(.user.login == $r.login
                          and ((.commit_id // .original_commit_id // "") == $head)
                          and (is_ack(.body) | not))] | length > 0)
               or ($head != "" and ([$b.comments.conversation[]?
                 | select(.user.login == $r.login
                          and (is_ack(.body) | not)
                          and (((.body // "") | contains($head)) or ((.body // "") | contains($short))))] | length > 0)))
          }
        | . + {key: $r.key, engaged: (.has_review or .has_check or .has_finding_comment)}
      )
    | { coderabbit: (map(select(.key=="coderabbit"))[0].engaged),
        codeant:    (map(select(.key=="codeant"))[0].engaged),
        bugbot:     (map(select(.key=="bugbot"))[0].engaged),
        graphite:   (map(select(.key=="graphite"))[0].engaged) }
  ' <<<"$bundle" 2>/dev/null \
    || printf '%s' '{"coderabbit":"?","codeant":"?","bugbot":"?","graphite":"?"}'
}
```

Store the result per PR (`ENGAGEMENT_BY_PR[$N]`) for Step 4. A missing `PR_STATE_SH`, a non-zero call, or a bundle `jq` cannot parse yields the all-`?` row and the tick continues — matching the soft-fail posture of the `UNRESOLVED` GraphQL fetch. Never let this scan abort a tick: it is the one piece of the table that carries no merge authority.

### Decision tree rationale (per row)

Read `merge_state` / `mergeable` **literally** from the gate JSON. **Do NOT infer `BEHIND` from `BLOCKED`** — `BLOCKED` also covers missing checks/reviews, not just behind-base. Only the literal `BEHIND` triggers a rebase.

| Condition (checked in order) | `VERDICT` | Rationale |
|------------------------------|-----------|-----------|
| PR in persisted `pmm_hard_block` | `BLOCKED:<reason>` | Overrides all other conditions including `CONFLICTING` — a prior-tick blocked/crashed exit already attempted resolution; do not re-dispatch silently |
| `human_changes_requested` non-empty | `BLOCKED:human(@login)` | Human CR is a hard block — name each login; never auto-dismiss; requires human action to unblock |
| `mergeable == CONFLICTING` | `fixpr` (`merge-conflict`) | Spawn `phase-a-fixer` tasked with `/merge-conflict` workflow; only `blocked` exit by the subagent turns it into `BLOCKED:conflicts(needs-human)` |
| `merge_state == BEHIND` | `rebase` | Rebase + force-push is a parent-inline operation (Step 5a) — cheaper than a subagent spawn; rebase abort routes to `fixpr(merge-conflict)` in Step 5a |
| `CI_FAILING > 0` **or** `UNRESOLVED > 0` | `fixpr` (`has-recoverable-blockers`) | Delegate fix work to Phase A fixer subagent |
| `MET == false` and (`STALE_BOT_CR > 0` or `REVIEW_DECISION == CHANGES_REQUESTED` with no human CR) | `fixpr` (`has-recoverable-blockers`) | Step 5b′ dismisses stale bot reviews + re-triggers; spawn Phase A when fix work remains |
| `MET == true` | `wrap` | Dispatch `/wrap` sequentially (Step 5d) |
| Otherwise | `waiting` | CI in-progress, reviewer pending, `REVIEW_REQUIRED` with no bot signal yet, `UNKNOWN` — no-op |

`merge-gate.sh` exit `3` (PR gone — merged/closed between Step 2 and now) → `VERDICT=gone`, clear persisted block (`"$SESSION_STATE_SH" --set ".pmm_hard_block.\"$N\"=null"`), drop from fleet. When the user explicitly approves respawn of a `crashed(needs-approval)` or `conflicts(needs-human)` PR, clear the same `pmm_hard_block` key before dispatch. Exit `2`/`4` (tooling/network) → `VERDICT=error` (do not act; retry next tick).

### VERDICTS_JSON accumulation

**Accumulate `VERDICTS_JSON` as each PR is classified — this is what Step 5.0's pre-flight gone/error skip reads.** Without this, `VERDICTS_JSON` stays an implicit empty object, the skip check never matches, and pre-flight runs against merged/errored PRs it should have skipped:

**Initialize `VERDICTS_JSON='{}'` once, before the per-PR loop — never via a `${VERDICTS_JSON:-{}}` default.** A brace-containing parameter-expansion default terminates at its **first literal `}`**, so once the variable holds real content that form expands to the JSON *plus a stray trailing brace* (`{"618":{"verdict":"wrap"}}` + `}`) and every subsequent `jq` in the loop fails on invalid input. The bug only shows up from the second PR onward, which is exactly when it is hardest to spot.

```bash
VERDICTS_JSON='{}'   # once, before the loop — plain expansion everywhere below

# ... per PR:
TAG=""
if [[ "$VERDICT" == "fixpr" && "$MERGEABLE" == "CONFLICTING" ]]; then
  TAG="merge-conflict"
fi
if [[ -n "$TAG" ]]; then
  VERDICTS_JSON=$(jq --arg n "$N" --arg v "$VERDICT" --arg tag "$TAG" \
    '.[$n] = {verdict: $v, tag: $tag}' <<<"$VERDICTS_JSON")
else
  VERDICTS_JSON=$(jq --arg n "$N" --arg v "$VERDICT" '.[$n] = {verdict: $v}' <<<"$VERDICTS_JSON")
fi
```

**Collect hard blocks for reporting, but do not force-stop the fleet.** Push every PR with a `BLOCKED:*` verdict onto a `HARD_BLOCK[]` list (with its reason). These PRs are **reported once and dropped from the actionable fleet** for this tick — they do not trigger Stop & Clean Exit. A fleet of only hard-blocked/waiting PRs converges to auto-Pause via the idle counter (Step 6/7). The `rebase`/`fixpr`/`wrap` verdicts are executed in Step 5.

### Findings pre-fetch (verdict `fixpr` only)

While gathering state, also fetch review findings from the three endpoints so Step 5c can embed them in each subagent prompt without a second round-trip:

```bash
# Per PR with fixpr verdict — stash in FINDINGS_JSON[N]
gh api "repos/$OWNER/$REPO/pulls/$N/reviews?per_page=100"
gh api "repos/$OWNER/$REPO/pulls/$N/comments?per_page=100"
gh api "repos/$OWNER/$REPO/issues/$N/comments?per_page=100"
```

Filter to actionable bot findings (`coderabbitai[bot]`, `cursor[bot]`, `greptile-apps[bot]`, `codeant-ai[bot]`, `graphite-app[bot]`). Also record the **reviewer classification** (`cr`, `bugbot`, or `greptile`) from `reviewer-of.sh` or gate JSON for the subagent prompt.

### Refinement pass: `fixpr` verdicts for concurrency + idempotency (still Step 3)

Step 5c's parallel-dispatch decisions (skip-if-in-flight, cap slots) are pure reads against `session-state.json` — compute them here, **before Step 4 prints the table**, so the heartbeat never shows a stale `fixpr` for a PR that is actually already in flight or waiting on a slot.

For every PR whose base verdict is `fixpr`:

1. **In-flight check.** Refine to `awaiting fix subagent` if a **blocking** Phase A `active_agents` entry exists for this PR (per Step 5's shared gate idiom — foreign entries past `PMM_LOCK_STALE_SECS` with no progress evidence are non-blocking), OR if `pmm_in_flight[N]` has an active lock for the same PR **that is not stale** — apply the same `PMM_LOCK_STALE_SECS` (default 3600s) staleness rule Step 5d uses for `/wrap` locks. A stale lock (e.g. a `wrap` lock left over from a crashed parent, on a PR now reclassified `fixpr`) is broken here too, not just in Step 5d — otherwise a stale non-`phase-a-fixer` lock can block fix dispatch forever with no path to clear it.
2. **Cap check.** Among the PRs still `fixpr` after step 1, count currently active **PMM-spawned** fix subagents (`id` prefixed `pmm-fix-` — excludes Phase A agents spawned by other workflows sharing the same `active_agents` map) and compute remaining slots. `.[]` iterates a map's values exactly as it iterated the array's elements, so the filter is unchanged from the pre-#1631 shape; only the empty-state fallback moved from `[]` to `{}`:

   ```bash
   ACTIVE_COUNT=$(jq '[.[] | select(.phase == "A" and (.status != "complete" and .status != "failed")
     and ((.id // "") | startswith("pmm-fix-")))] | length' \
     <<<"$("$SESSION_STATE_SH" --get '.active_agents' 2>/dev/null || echo '{}')")
   SLOTS=$(( PMM_MAX_PARALLEL - ACTIVE_COUNT ))
   (( SLOTS < 0 )) && SLOTS=0
   ```

   Allocate the `$SLOTS` available slots in two tiers, never by plain PR-number order alone: **tier 1** — every PR in `EXHAUSTION_RESPAWN_PRS` (populated by Step 2.5 this tick) keeps verdict `fixpr` unconditionally, even if it exceeds `$SLOTS` — an exhaustion-with-handoff respawn is mandatory per `subagent-orchestration.md`, not slot-competitive, so it must never lose to a fresh PR. **Tier 2** — remaining slots (`$SLOTS` minus tier-1 count, floored at 0) go to the rest of the still-`fixpr` PRs by PR number order, for determinism. Anything past that refines to `queued (cap)`. (A tick with more exhaustion respawns than `$PMM_MAX_PARALLEL` will transiently run over the nominal cap — acceptable, since these are already-approved in-flight fixes being continued, not new work.)

Store the refined verdict per PR (`fixpr`, `awaiting fix subagent`, or `queued (cap)`) for both Step 4's table and Step 5c's dispatch loop — Step 5c dispatches only PRs still refined to `fixpr` and does not repeat this check.

---

## Step 3.6: Overlap-aware merge sequencing

First-ready-first-merged is backwards when one PR's diff dwarfs its siblings' in a shared file: every small PR that lands first forces the big one into another conflict round. Before Step 4 prints and Step 5d dispatches, compute a **merge order** over the fleet so the largest footprint in a contested file lands first and the smaller ones wait.

This step is **side-effect-free** — `merge-sequence.sh` reads `pulls/{N}/files` and prints a plan; it never merges, rebases, or comments. Mechanism, state machine, and rationale: `.claude/reference/merge-sequencing.md`.

```bash
# Prior tick's hold state — this is what makes stall detection work across ticks.
PRIOR_HOLDS=$("$SESSION_STATE_SH" --get '.pmm_merge_holds // {}' 2>/dev/null || echo '{}')

# Flatten Step 3's VERDICTS_JSON ({"<n>":{verdict,tag}}) to {"<n>":"<verdict>"},
# then overwrite each entry with the REFINED verdict where Step 3's refinement
# pass produced one (`awaiting fix subagent`, `queued (cap)`, `held(#A)` from a
# prior tick). Pass the WHOLE fleet, not just the `wrap` PRs: the planner needs a
# non-`wrap` anchor's verdict to tell "progressing" from "hard-blocked", and that
# is exactly what decides whether its followers hold or release.
VERDICTS_MAP=$(jq -c 'map_values(.verdict)' <<<"$VERDICTS_JSON")
HEADS_MAP='{}'   # plain init — never a ${HEADS_MAP:-{}} default (see Step 3 above)
for N in $PR_NUMS; do
  VERDICTS_MAP=$(jq -c --arg n "$N" --arg v "${REFINED_VERDICT[$N]:-}" \
    'if $v == "" then . else .[$n] = $v end' <<<"$VERDICTS_MAP")
  HEADS_MAP=$(jq -c --arg n "$N" --arg sha "$(jq -r '.head_sha // ""' <<<"${GATE_BY_PR[$N]}")" \
    'if $sha == "" then . else .[$n] = $sha end' <<<"$HEADS_MAP")
done

# Sequence only PRs that still exist. A PR classified `gone` (merged/closed
# between Step 2 and now) would 404 in the planner and, without --skip-missing,
# take the WHOLE fleet's plan down with exit 3. Filter the known-gone ones here,
# and pass --skip-missing so a PR that merges during this very step is demoted to
# an excluded_prs[] entry instead of failing the run.
SEQ_PRS=$(for N in $PR_NUMS; do
  V=$(jq -r --arg n "$N" '.[$n] // ""' <<<"$VERDICTS_MAP")
  [[ "$V" == "gone" || "$V" == "error" ]] || echo "$N"
done | tr '\n' ',' | sed 's/,$//')

SEQ=""; SEQ_RC=1
if [[ -n "$SEQ_PRS" ]]; then
  SEQ=$("$MERGE_SEQUENCE_SH" --prs "$SEQ_PRS" --skip-missing \
    --verdicts "$VERDICTS_MAP" --heads "$HEADS_MAP" --holds "$PRIOR_HOLDS")
  SEQ_RC=$?
fi
```

`HEADS_MAP` comes from the gate JSON you already fetched, so passing it saves one `gh pr view` per PR. Both maps are plain in-memory tick state — initialize `HEADS_MAP='{}'` at the top of this step every tick, never carried across ticks.

`SEQ_RC` is `0` when sequencing applies (≥1 hold or batch), `1` when the fleet has no overlap (plan still printed, every PR reads `merge`, dispatch unchanged), and `2`/`3`/`4` on usage/not-found/gh errors. **On any error exit, log one line and continue the tick with sequencing disabled** — treat every PR as `merge`. A planner failure must never block the fleet; the merge gate is still the authority on whether anything lands.

**Refine the verdicts once more** from `SEQ`'s per-PR action, for PRs currently verdicted `wrap`:

| `plan[N].action` | Refined verdict | Step 5d does |
|------------------|-----------------|--------------|
| `merge` | `wrap` (unchanged) | dispatch normally |
| `hold` | `held(#A)` | skip this tick — `#A` is landing ahead of it |
| `batch` | `batch(#A)` | dispatch in this tick's single batch window |
| `not_merge_ready` | unchanged | n/a — it was never a merge candidate |

**Persist the returned hold state — only on a successful run** (`SEQ_RC` `0` or `1`) so the next tick's stall counter advances. **Never persist after an error exit:** `$SEQ` is empty or partial then, `.holds` evaluates to `null`, and writing it would *wipe* the prior tick's stall counters — turning a transient planner failure into a silent reset that re-holds already-released PRs:

```bash
if [[ "$SEQ_RC" -eq 0 || "$SEQ_RC" -eq 1 ]]; then
  NEW_HOLDS=$(jq -c '.holds // {}' <<<"$SEQ")
  "$SESSION_STATE_SH" --set ".pmm_merge_holds=$NEW_HOLDS"
else
  echo "[PMM] merge-sequence.sh failed (exit $SEQ_RC) — sequencing disabled this tick; prior holds left intact"
  SEQ=""   # every PR falls through to `merge`; Step 4 prints no annotation
fi
```

Evaluate the `jq` first and pass the resulting JSON as the value — never a raw filter expression (`handoff-files.md` field-type contract). Keep `SEQ` for Step 4's annotation and Step 5d's dispatch order; an empty `SEQ` means "no sequencing this tick", which every consumer below already treats as `merge`.

> **Authorship is enforced inside the planner** (`pr-authorship.sh`, fail-closed): a collaborator's PR touching the same file is excluded before grouping, so it can never become an anchor holding your PRs behind a merge you have no authority to perform. Under `READ_ONLY_FLEET=1` this step still runs — the plan is display-only context, like the rest of the table.

---

## Step 4: Heartbeat / quiet-tick definition and table format

### Quiet-tick logic

Print the **full table** (below the lead line) when ANY of:

- (a) this is the first tick of a fresh invocation (Step 0 mode entry) or the first tick after a resume (Step 0a) — both null `.pmm_digest`/`.pmm_row_digest`; (a) is independently sufficient, so the table prints regardless of (b). The user asking for the table also fires (a);
- (b) a digest change — `DIGEST != PREV` **or** `ROW_DIGEST != ROW_PREV` **or** either previous value is null — **that is also** decision-relevant: a new hard block, a gate failure, a termination, or a PR entering/leaving the fleet. Both halves must hold; a digest change on its own does not fire (b). A purely informational delta (a new bot comment, a CI count, a display-only change) does **not** print the table (issue #851); the digests are still computed and persisted for backoff;
- (c) any PR's verdict this tick is actionable — `rebase`, `fixpr`, `wrap`, or `batch(#A)` — so the classification is always visible before Step 5 acts;
- (d) Step 2.5 processed any subagent outcome, or `HARD_BLOCK[]` gained a new entry this tick;
- (e) Step 3.6 held or batched anything (the merge-sequence annotation must stay visible).

**Quiet tick** (none of a–e): append `— no change` plus the PR numbers to the lead line; when `HARD_BLOCK[]` is non-empty append the standing blocks with reasons, and when any PR is refined `queued (cap)` or `held(#A)` append those too (e.g. `… (author:x) — no change (#101 #102; hard-blocked: #99 human-CR; queued (cap): #103)`); print **only that line** — no table. **New** hard blocks, gate failures, and terminations always get the full table on the tick they appear ((b)/(c)/(d)); already-reported blocks stay visible via the hard-blocked suffix on every quiet line — never silently dropped. Terminal snapshots (Pause / Stop & Clean Exit) always print the full table regardless of quiet-tick status.

### Table format

**This is a documented divergence from the canonical "Running now" table, not an unreconciled one** (issue #1527). The rationale is recorded once, in `.claude/reference/time-estimates.md` §"Documented divergence: `/pr-monitor-and-manage`" — do not restate it here, and do not reshape these columns toward the canonical seven without changing that entry first. The canonical table still has a home in this skill: the round-progress question routes to `/board` (SKILL.md Step 4), which renders it unaltered.

| Issue | PR | State | Reviews | CI | Unresolved Threads | Verdict | Subagent |
|-------|----|-------|---------|----|--------------------|---------|----------|
| #<issue or —> | #<N> | <merge_state> | <review_decision> | <pass>/<fail>/<prog> | <count> | <VERDICT from Step 3> | <SUBAGENT_STATUS> |

- **Issue** — from `pr-issue-ref.sh`, or `—` when the PR body has no closing keyword.
- **State** — literal `merge_state` (`CLEAN`/`BEHIND`/`BLOCKED`/`UNKNOWN`); when `mergeable == CONFLICTING`, append `(CONFLICTING)` to the State cell so the conflict signal is visible (CONFLICTING is a `mergeable` value, not a `merge_state` value).
- **Reviews** — literal `review_decision` (`APPROVED`/`CHANGES_REQUESTED`/`REVIEW_REQUIRED`).
- **CI** — `passing`/`failing`/`in_progress` counts from the gate.
- **Unresolved Threads** — count of `isResolved == false` (or `?` if the GraphQL fetch failed).
- **Verdict** — the Step 3 verdict: `rebase`, `fixpr`, `wrap`, `waiting`, `awaiting fix subagent`, `queued (cap)`, `rate-limited`, `BLOCKED:human(@x)`, `BLOCKED:conflicts(needs-human)`, `gone`, `error`, plus Step 3.6's merge-sequencing refinements `held(#A)` and `batch(#A)`.
- **Subagent** — per-PR agent state for fix work: `—` (not spawned / no fix dispatch this tick), `dispatched (merge-conflict)` (conflict-resolution fixer spawned this tick — transitions to `spawned`/`working`/`complete`/`failed` as the subagent runs), `spawned`, `working`, `complete`, `failed`, `deferred(foreign-agent)` (Step 5d/5e deferral gate closed because a foreign Phase A entry blocks this PR), `foreign-agent-stale` (Step 5e staleness timeout fired on a silent foreign entry — gate treated as drained). Populated from `active_agents` + Step 2.5 outcomes (PMM-owned only) + Step 5e foreign-drain polling. Merge-ready `/wrap` dispatches show `—` (wrap is parent-inline, not a subagent).

A PR merged this tick is reported via the per-tick `merged #N` line (Step 5d) and then naturally disappears from the fleet on the next `gh pr list` discovery — no table row lingers.

Each PR's four engagement cells are part of `ROW_TUPLE_SORTED`, so a reviewer arriving on or dropping off HEAD is a display change like any other — it feeds (b)'s digest half and never on its own forces a print.

### Reviewer engagement block

Printed on every tick that prints the table, directly beneath it (and beneath the merge-sequence annotation when there is one). One row per PR in the same order as the table; ✅ = engaged on the current HEAD SHA, ❌ = missing, `?` = the bundle was unavailable for that PR.

| PR | CodeRabbit | CodeAnt | BugBot | Graphite |
|----|------------|---------|--------|----------|
| #476 | ✅ | ❌ | ✅ | ❌ |
| #479 | ❌ | ❌ | ✅ | ❌ |

Under it, one line per PR that is missing at least one reviewer, naming the missing ones — omit the line entirely for a fully covered PR, and omit the whole block when the fleet is empty:

```text
Gaps: PR #476 — missing: CodeAnt, Graphite
Gaps: PR #479 — missing: CodeRabbit, CodeAnt, Graphite
```

When every PR is fully covered, replace the gap lines with a single `Reviewer engagement: all PRs covered on HEAD.`

**Graphite caveat.** A ❌ in the Graphite column may reflect the known app-level outage rather than a fresh per-PR gap — diagnostic method and current status in `.claude/reference/codeant-graphite-supplemental.md`. Say so once when Graphite is the only missing reviewer across the fleet; do not repeat it per row.

**Authority boundary.** The block is display-only. It proposes nothing and posts nothing: reviewer triggers are issued solely by Step 5.0's `pr-preflight.sh` (CR account hourly budget + per-PR 2-explicit-triggers/hour cap, fail-closed), and Step 2's `READ_ONLY_FLEET` guard already suppresses every dispatch when the fleet is not the authenticated user's. A gap on a PR you did not author is therefore reported and never acted on.

### Merge-sequence annotation

Print this whenever Step 3.6 held or batched anything. Emit `SEQ`'s `summary` verbatim on the line directly under the table:

```bash
jq -e '[.plan[] | select(.action == "hold" or .action == "batch")] | length > 0' >/dev/null <<<"$SEQ" \
  && echo "Merge sequence: $(jq -r .summary <<<"$SEQ")"
```

```text
Merge sequence: holding #101, #102 until #100 lands — they share `.claude/skills/pm/SKILL.md`
```

Omit the line entirely when nothing is held or batched — a fleet with no overlap gets no annotation and no behavioural change. When `SEQ`'s `excluded_prs[]` is non-empty, add one short line naming the count and reason (e.g. "1 PR excluded from sequencing: not yours") so a collaborator's PR silently sitting out is visible rather than invisible.

Only after the heartbeat (and the table, when any of a–e fired) is printed does Step 5 execute the actions. A quiet tick has no actionable verdicts by construction (condition c); if Step 5.0 pre-flight nonetheless acts on a quiet tick (draft flip, reviewer trigger), its own timestamped output lines report it.
