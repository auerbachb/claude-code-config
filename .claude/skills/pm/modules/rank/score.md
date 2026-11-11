<!-- pm-routing:begin -->
Route `rank:score`. Read the selected issue evidence and score the candidates. Apply the pause, scope and operator order read in rank:load or the current refill gate.
For a bounded rescan after context turnover, restore the current OKRs and `OKR_MODE` before scoring when either input is unavailable. Resolve `rank:load` for the read-only config and OKR rule in 1B.1. Keep the current refill scope and operator evidence.
<!-- pm-routing:end -->
### 1B.3: Read issue bodies for top candidates

Reading all issue bodies is expensive. Use a two-pass approach:

**Pass 1 — Quick scan:** From the issue list, shortlist the top `max(20, 2 × LIMIT)` candidates (Step 0), or all available candidates if fewer exist. Use fast signals:
- Labels containing `bug`, `critical`, `P0`, `P1`, `urgent`, `blocked`
- Issues with no assignee (available for pickup)
- Issues not already covered by an open PR (cross-reference PR branch names and bodies for `#N` references)
- Most recently updated (active discussion = likely important)
- Oldest unassigned (may be neglected but important)
- **Operator order (1B.1a):** every open issue in `PRIO_JSON.order` is a candidate whatever the signals above say, and every issue in `PRIO_JSON.parked` is dropped here, before any deep read. An ordered issue missing from 1B.2's list (past its 500-issue cap) is fetched directly — `gh issue view N --json number,title,labels,assignees,state,createdAt,updatedAt` — and joins when open, so the cap never silently drops an operator pick

**Every issue in `NEW_ISSUES` (1B.2) joins the shortlist in addition to the quick-scan candidates**, so an issue filed since the last scan is always read, scored, and tiered on the first scan after it was filed. The 1B.5 output then **names each of them with its tier**, even when it ranks below the top 3–5, as one line after the ranked list: `New since the last scan: #N — title (Tier)` (several joined with `; `). A new issue the 1B.3 / 1B.4 checks later drop (an open PR, a dependency) is named the same way with that reason in place of the tier, so the operator sees it was picked up.

**Pass 2 — Deep read:** Fetch full bodies and score the entire shortlist in 1B.4:

```bash
# For each candidate issue number:
gh issue view $NUMBER --json body,title,labels,comments,assignees
```

Extract from each:
- Scope and intent (what the issue actually asks for, not just the title)
- Acceptance criteria — when present, these define "done"
- Dependency references, from the body **and** comments. **Match these markers case-insensitively** — the same way the closing-keyword rule below does, and for a concrete reason: `/issue-maker` Step 8 and `/subagent` Step 5.1 both write increment links as `- Depends on #N` at the start of a list item, so a case-sensitive read would collect none of them and every increment chain would look parallelizable to `/wave` Step 5.1:
  - Blocked direction: `blocked by #N`, `depends on #N`, `prerequisite for #N`, `after #N`
  - Unblocking direction: `unblocks #N`, `enables #N`, `required by #N`, `before #N`
  - **`issue-deps.sh` is the canonical reading of these markers** (issue #1760): `"$ISSUE_DEPS_SH" parse` reads the `--json number,body,comments` you already fetched (one array) and prints the blocker → blocked edges; `edges <owner/repo>` and `dependents <owner/repo> <N>...` read the repo's open issues themselves. Build 1B.4's dependency map from its edges rather than by eye, so `/pm`, `/wave` (5.1), and the desk's derived impact (`human-queue.sh impact`, which counts an issue's open dependents with the same script) can never read the markers differently.
- In-flight signal: cross-reference against the open-PR list already fetched in 1B.2 (now includes `body`) — a PR body containing a GitHub closing keyword (`close`/`closes`/`closed`, `fix`/`fixes`/`fixed`, `resolve`/`resolves`/`resolved`, case-insensitive) for this issue's number means a PR is already underway; match both local (`#N`) and cross-repo (`owner/repo#N`) reference forms. GitHub's closing keywords live in PR bodies, not in the issue's own text, so this signal is never collected from the issue body or comments — same source Section 3.3's progress detection reuses.
- Complexity signals: number of acceptance criteria, files mentioned, architectural scope
- Current assignee — who, if anyone, is already on it

### 1B.4: Score and rank issues

Sort candidates into four tiers — **Critical**, **High**, **Medium**, **Low**.

**When the user stated a business goal**, goal alignment is the primary signal and sets the tier directly:

- **Critical** — directly unblocks or achieves the goal; without it the goal cannot be met.
- **High** — significant enabler; materially accelerates progress toward the goal.
- **Medium** — supporting work; deferrable without derailing the goal.
- **Low** — tangential, or serves a different goal entirely.

**With no stated goal (the default)**, the priority signals in (1) below set the tier instead. Either way, (2)-(6) then apply to every candidate.

**Precedence:** the initial tier always comes from goal-alignment (if a goal is stated) or priority-signals (1) otherwise. Leverage (2) and OKR (3) never set the tier on their own — they only modify it afterward, and only upward: leverage via an explicit tier-jump, OKR via the one-tier boost or tie-break rules in (3), never a downgrade. Momentum (4), cost-benefit (5), and exclusions (6) don't touch the tier at all — they refine ordering and the candidate pool within whatever tier (2)-(3) leave it in.

1. **Priority signals:**
   - Labels: `P0`/`critical` > `P1`/`bug` > `P2`/`enhancement` > unlabeled
   - Age + activity: old unassigned issues with recent comments = neglected priority

2. **Leverage (tier-jump):** an issue inherits the urgency of what it unblocks — one that unblocks three Critical issues is itself Critical, even if its own alignment is Medium. Build a dependency map from the references collected in 1B.3:
   - For each issue, record what blocks it and what it blocks.
   - Follow chains: if #10 blocks #15 which blocks #20, the root (#10) gets the boost.
   - Flag circular dependencies (A blocks B, B blocks A) — these need human resolution; surface them rather than ranking them.

3. **OKR alignment (when `OKR_MODE=true`):**
   - Issues that directly advance an incomplete key result get a one-tier boost (unless already Critical)
   - Issues aligned with an objective broadly get a tiebreaker advantage — ordering within the tier only; the tier label does not change
   - Issues matching no OKR take no penalty — they rank on the other signals alone
   - Record which OKR(s) each issue aligns with for the rationale (e.g. "Advances O1/KR2"); list at most 2, ordered by objective then key result

4. **Recent momentum:**
   - What areas of the codebase have recent merged PRs? Issues in the same area benefit from warm context.
   - What themes appear in recent merges? Issues continuing that theme are cheaper to pick up.

5. **Cost-benefit (tie-break within a tier):** at equal alignment, the smaller issue wins. Read effort from `complexity:quick|light|medium|heavy` labels when present, otherwise from scope signals in the body (count of acceptance criteria, files mentioned, architectural reach).

6. **Exclusions:**
   - Skip issues that already have an open PR (per the in-flight signal cross-referenced in 1B.3 — a closing keyword in an open PR body means in flight)
   - Skip issues assigned to someone else (unless stale > 14 days)
   - Skip issues labeled `blocked`, `on-hold`, `wontfix`, `duplicate`

7. **Operator order (`/desk`) — last, after every exclusion.** Skip this step when 1B.1a found no override (`.order` and `.parked` both empty) or the file was unreadable. Otherwise flatten the surviving candidates into one ranked list — Critical first, each tier in its final order — and overlay the operator's order on it:

   <!-- test-anchor: pm-1b4-priority-apply -->
   ```bash
   # RANKED_ISSUES: the eligible candidates' issue numbers, best first, after (1)-(6).
   PRIO_APPLY_RC=0
   PRIO_APPLY=$(printf '%s\n' ${RANKED_ISSUES[@]+"${RANKED_ISSUES[@]}"} \
     | "$PM_PRIORITY_SH" apply --json 2>/dev/null) || PRIO_APPLY_RC=$?
   [[ "$PRIO_APPLY_RC" -eq 0 ]] || PRIORITY_UNREADABLE=true   # the file changed under us: 1B.1a's unreadable case
   ```

   Its `.order` is the presentation and dispatch order: `source: "override"` rows first, in the operator's order, then the `ranked` rows in yours; parked issues are gone. **The overlay moves rows and nothing else** — each row keeps the tier, leverage, OKR alignment, and rationale (1)-(6) gave it, so an issue dropped from the file returns straight to its ranked place. `.not_eligible` lists ordered issues that did not survive (1)-(6): name each with the exclusion that removed it (open PR, assigned to someone else, a `blocked`/`on-hold`/`wontfix`/`duplicate` label, closed) and never promote one past it.

**Misaligned effort ("stop doing"):** cross-reference the user's current work (their open PRs and assigned issues from 1B.2) against the tiers. If they are actively on Low/Medium work while Critical/High issues sit unassigned and within their scope, flag it — name the low-impact work and the higher-impact work to switch to. Only flag when the misalignment is clear and the alternative is materially better; when their current work is already Critical/High, say it is well-aligned instead.

If exclusions and inline eligibility leave fewer than `LIMIT` candidates, read and score at most one more `max(20, 2 × LIMIT)` page from the unexamined issue list. Apply the same scope, scoring, exclusion, and operator-order rules to the combined set before writing the rank cache. If the list is exhausted or the batch is still short, use the available eligible issues.

### 1B.4b: Judgment check (ask only when the ranking turns on a judgment call)

Ranking is a recommendation, not arithmetic. Before presenting, check whether the **top** of the list depends on a call only the user can make. Any one of these triggers is enough:

- **Near-tied top candidates** — two or more issues share the top tier with no OKR or cost-benefit signal separating them.
- **Competing OKR alignments** — top candidates advance *different* objectives, and no stated business goal breaks the tie.
- **Conflicting urgency signals** — e.g. a `P0` label on a stale, quiet issue against an unlabeled issue with active discussion and a fresh dependency.

When a trigger fires, present **only** the tied candidates, one line of rationale each, and ask **one** focused question:

> Two issues tie for the top:
> - **#42 — {title}** — unblocks #50 and #53, advances O1/KR2
> - **#38 — {title}** — labeled `P0`, but quiet for three weeks
>
> Which matters more right now — clearing the dependency chain, or the P0?

Incorporate the answer, finalize the ranking, and continue to 1B.5.

**Operator-ordered rows are already decided** (1B.4 item 7): the operator ranked them, so no trigger fires on them — read the triggers against the `ranked` rows that follow.

**Negative rule — this does not fire on every run.** No trigger, no question: when one candidate is clearly ahead, emit the ranking and proceed. A pause the user did not need is a failure of this step, not caution. Ask at most one question per ranking; if the answer is ambiguous, take the higher-leverage candidate, say so in one line, and move on.

### 1B.4c: Persist the ranking (for the desk's derived impact)

Once 1B.4b has settled the order, write it to the rank cache, so `/desk` can derive a Decision's impact from where its issue ranks (issue #1760: `human-queue.sh impact` reads the cache while it is under 24 hours old). Write **every retained candidate**, not just the 3-5 you present: the eligible rows in the order 1B.5 will show them — item 7's `.order` when it ran (override rows first, each with the tier (1)-(6) gave it), otherwise the tiers in order, Critical first. One `<N> <Tier>` line each, best first:

<!-- test-anchor: pm-1b4c-rank-cache -->
```bash
# FINAL_ORDER: one "<N> <Tier>" line per retained candidate, best first (as above).
if [[ -n "$PM_RANK_CACHE_SH" ]]; then
  RANK_REPO=""
  if [[ -n "$SESSION_STATE_SH" ]]; then RANK_REPO=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || RANK_REPO=""; fi
  [[ "$RANK_REPO" == */* ]] || RANK_REPO=""  # --repo-key prints `_unknown` (exit 0) when it resolves no repo
  if [[ -z "$RANK_REPO" ]]; then RANK_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || RANK_REPO=""; fi
  if [[ -z "$RANK_REPO" ]] \
    || ! printf '%s\n' ${FINAL_ORDER[@]+"${FINAL_ORDER[@]}"} | "$PM_RANK_CACHE_SH" write "$RANK_REPO" >/dev/null 2>&1; then
    echo "DEGRADED: the ranking was not cached (pm-rank-cache.sh write failed) — the desk reads this repo's backlog rank as unknown"
  fi
fi
```

Best-effort, never a gate: a failed write prints that one line and ranking, presentation, and dispatch carry on. Every path that re-ranks ends here — the mid-session re-prioritize (3.3) and every 3.4 re-scan, day-mode ticks included — so the cache always holds the latest order.

