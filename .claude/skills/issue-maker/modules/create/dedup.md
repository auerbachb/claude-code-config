# Create: duplicate check

> Load only for: after a draft title and problem statement exist
> Prerequisites: create reflection/draft complete; only read when duplicate screening is next

## Step 4: Dedup search

Before creating, search open and recently-closed issues for likely duplicates and surface any matches. Use the shared `issue-dedup.sh` helper, which scores **titles and bodies** — a title-only search misses the case that motivated it (issue #647 restated issue #638's second acceptance criterion while sharing almost no title words; issue #652):

```bash
# 2–6 significant keywords from the proposed title AND the problem statement —
# body scoring is what catches a duplicate that was worded differently.
KEYWORDS="<significant words from the title and problem statement>"
ISSUE_DEDUP=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/issue-dedup.sh" \
  "$HOME/.claude/scripts/issue-dedup.sh" \
  ".claude/scripts/issue-dedup.sh"; do
  if [ -x "$candidate" ]; then ISSUE_DEDUP="$candidate"; break; fi
done
DEDUP_RC=0
SIBLING_NUMBERS=""
if [ -n "${CHAIN_ID:-}" ]; then
  SIBLING_NUMBERS=$(jq -r "$MINE_DEF"'[.issues[] | mine | select(.chain.chain_id == $chain_id) | .number] | join(",")' \
    "$LOG" --arg repo "$REPO" --arg chain_id "$CHAIN_ID") || {
    echo "ERROR: could not identify same-chain issues; duplicate screening is pending" >&2
    exit 1
  }
fi
if [ -n "$KEYWORDS" ] && [ -n "$ISSUE_DEDUP" ]; then
  DEDUP_ARGS=("$KEYWORDS" --repo "$REPO")
  [ -z "$SIBLING_NUMBERS" ] || DEDUP_ARGS+=(--exclude "$SIBLING_NUMBERS")
  "$ISSUE_DEDUP" "${DEDUP_ARGS[@]}" || DEDUP_RC=$?
fi
# Only exit 1 means "searched, found nothing". Exit 2/4 (usage, gh/env failure)
# means the check did not run — fall back below and say so; never present an
# unrun check as a clean result.
```

- **Guard:** if no significant keywords remain, skip the dedup search.
- **Helper missing, or `DEDUP_RC` ≥ 2:** fall back to the title-only `gh issue list --repo "$REPO" --state all --search "$KEYWORDS in:title" --limit 100 --json number,title,url,state,closedAt` over open and recently-closed issues, and say so in one line when surfacing results — `DEGRADED: issue-dedup.sh not found (checked all three paths) — title-only duplicate search` for the missing-helper case, naming the exit code instead when the helper ran and failed. Filter closed results to the same recent window as the helper (30 days); retain open results. If this fallback also fails, stop with duplicate screening pending rather than claiming no match or filing unscreened. Never present an unrun or downgraded check as a clean result.
- Apply the same `$SIBLING_NUMBERS` exclusion to fallback results before ranking them. The exclusion must happen before any top-candidate selection. If the log read needed to build it fails, stop duplicate screening.

```bash
CANDIDATES=$(gh issue list --repo "$REPO" --state all --search "$KEYWORDS in:title" \
  --limit 100 --json number,title,url,state,closedAt) || exit 1
CANDIDATES=$(printf '%s' "$CANDIDATES" | jq -c --arg exclude "$SIBLING_NUMBERS" '
  ($exclude | split(",")) as $excluded
  | [.[] | . as $candidate
    | select((($candidate.state | ascii_upcase) == "OPEN")
      or (try (($candidate.closedAt | fromdateiso8601) >= (now - 2592000)) catch false))
    | select(($excluded | index($candidate.number | tostring)) == null)]') || exit 1
printf 'DEDUP_CANDIDATES=%s\n' "$CANDIDATES"
```
- **Filter same-run increment siblings out of the candidate list first** — before anything below reads a "top" candidate. See the sibling bullet at the end of this list for why; the ordering matters because every rule below acts on whichever candidate ranks first.
- **Interpreting matches:** `/issue-maker` always has a human in the loop, so it only ever *surfaces* candidates — it never auto-comments in place of filing. Use the strong/weak/none thresholds in `autofile-dedup.md` — read through the standard candidate order, `$HOME/.claude/skills-worktree/.claude/reference/` first, then `$HOME/.claude/reference/`, then `.claude/reference/` (`portable-skill-resolution.md`) — to classify the **top surviving** candidate: a **strong match** or an **exact title match** is a genuine pause point; weak/ambiguous matches are not.
- **Default mode — pause only on a strong or exact match:** if the top candidate clears that bar, surface it and present the choice via **`AskUserQuestion`** when available (options: `"Skip — looks like a duplicate (Recommended)"`, `"File anyway"`; prose fallback `"Looks like a duplicate of #N — file anyway? (y/N)"` in headless runs). On a weak/ambiguous match, **do not block** — file, and name the near-duplicate as a decision point (Step 9a: "possibly overlaps #N"). No match → file normally. See `ask-menu.md` for the full vehicle convention.
- **Rapid-fire:** show any matches but proceed unless there is an **exact title match** (then block and ask).
- **Siblings in the same increment chain are never duplicates of each other.** Increments share a theme prefix and most of their keywords by design, so filing `Landing page 2/4` right after `Landing page 1/4` will surface increment 1 as a strong match. That is the chain working, not a duplicate. **Drop every candidate sharing this issue's `chain_id` (Step 9's log record) from the list, then classify what remains** — an exclusion, not an override. Match on `chain_id`, never on the theme prefix: two unrelated chains can share wording, and a re-worded title would silently stop matching. Excluding them only after the top candidate is chosen would let a sibling outrank a genuine duplicate and carry the "file anyway" verdict with it, so a real duplicate ranked second would never be evaluated at all. Note the skipped siblings in one line; duplicates *outside* the chain still pause normally, in both modes. If nothing survives the filter, that is a clean "no match" — file normally.

---
