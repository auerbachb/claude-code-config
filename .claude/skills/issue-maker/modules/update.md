# Update existing issue

> Load only for: `/update` or natural-language edit-in-place for an existing issue
> Prerequisites: session state loaded; issue number and target repo identified

## Step 10: `/update <issue#> <statement>` — structured update

A first-class command for adding information to an existing issue **without leaving capture mode**. It is *not* a raw append — it follows a disciplined process:

1. **Fetch** current state:
   ```bash
   # Optional changed-field values are per edit; discard any prior create values.
   DELIVERS=""; EST_BOUND=""
   ISSUE_JSON=$(gh issue view "$N" --repo "$REPO" --json number,body,title,url,state,comments) || exit 1
   TITLE=$(printf '%s' "$ISSUE_JSON" | jq -er '.title') || exit 1
   ISSUE_URL=$(printf '%s' "$ISSUE_JSON" | jq -er '.url') || exit 1
   ISSUE_STATUS=$(printf '%s' "$ISSUE_JSON" | jq -er '.state | ascii_downcase') || exit 1
   CURRENT_BODY=$(printf '%s' "$ISSUE_JSON" | jq -r '.body')
   ```
2. **Classify** the statement — is it best added as:
   - a new checkbox under `## Acceptance Criteria` (precise, implementer-facing detail), or
   - an addendum to an existing section (Background / Problem / Notes), or
   - a new top-level section, or
   - a **comment** on the issue rather than a body edit (status/context that doesn't belong in the canonical spec)?

   Default bias: prefer **body edits** for AC/scope, prefer **comments** for status/context.
3. **Reflect before proposing the edit** — check whether the ask is narrower than it sounds, needs an adjacent concern, contains distinct issues, exceeds one bounded reviewable PR/pipeline, or contains material ambiguity; state the assumptions in the concrete proposal. If scope or estimate changes, evaluate both deliverable fit and the new planning bound. Resolve `split-thresholds.sh` through the three standard script candidates and use its coherent `--json` pair (documented missing/unusable fallback 180/120 with a `DEGRADED:` note); compare the bound with `split_over_min` using strict `>`. A natural seam plus an over-threshold bound triggers the split conversation even for one deliverable; with no independently mergeable seam, retain the long estimate and state why. If the new statement implies the issue should be **split**, surface that instead of blindly appending. This update operation never starts filing a chain silently.
4. **Propose** the concrete diff (the edited body, or the comment text) and ask for confirmation.
5. **Apply** once confirmed and capture the write result:
   ```bash
   gh issue edit "$N" --repo "$REPO" --body "$NEW_BODY"   # body edit
   # or
   gh issue comment "$N" --repo "$REPO" --body "$COMMENT" # comment
   ```
   Use the fetch → modify → write-whole-body pattern (`gh issue edit --body` replaces the entire body — never truncate the existing content). A zero exit confirms the write. If the command fails or its response is uncertain, fetch the issue again and compare the remote body/comment with the proposed content before doing anything else; do not retry blindly. If the result cannot be verified, stop without changing the log or reporting success.
6. For a title edit, set `TITLE` to the confirmed remote title; refresh `ISSUE_STATUS` if the edit changes state. **Only after the remote write is confirmed**, record `edited_at` on the log entry — **plus any summary-table field the edit actually changed** — and **print the updated issue URL as the closing line.** If the issue isn't already tracked in this thread's log (e.g. you're updating an issue opened elsewhere), add a minimal entry for it instead of silently skipping:

   ```bash
   # DELIVERS / EST_BOUND: re-read from the body you just wrote, and set ONLY
   # when this edit changed them — empty string means "unchanged, leave the
   # stored value alone". EST_BOUND is the `plan on` bound in minutes.
   # Both are `${VAR:-}`: unlike Step 9's create path they are normally UNSET
   # here, and a bare "$DELIVERS" would abort the whole update under `set -u`.
   set_log "$MINE_DEF"'if any(.issues[]; .number == ($n|tonumber) and same_repo)
            then (.issues[] | select(.number == ($n|tonumber) and same_repo)) |=
                   (.edited_at = $ts
                    | .title = $t | .url = $u | .status = $status
                    | if $delivers == "" then . else .delivers = $delivers end
                    | if $bound == "" then . else .est_bound = ($bound|tonumber) end)
            else .issues += [{number:($n|tonumber), title:$t, url:$u, labels:[],
                              created_at:$ts, edited_at:$ts, status:$status, origin:"update", chip_task_id:null,
                              chain:null, tier:null, delivers:null, est_bound:null}] end' \
     --arg n "$N" --arg t "$TITLE" --arg u "$ISSUE_URL" --arg repo "$REPO" --arg status "$ISSUE_STATUS" \
     --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
     --arg delivers "${DELIVERS:-}" --arg bound "${EST_BOUND:-}"
   ```

   **An edit that changes what the issue delivers, or its estimate, must refresh those two fields — otherwise the running tally reports create-time values as current.** The log is the tally's source of truth after compaction (Step 9), so a `delivers`/`est_bound` left at its filing-time value survives as a confident-looking row that no longer matches the issue. Refresh on the two edits that move them: a body edit that changes the `## Estimate` line (re-read the `plan on` bound) or that materially changes the delivered scope (re-state the one-clause `Delivers`, `|` escaped as `\|`). A comment-only update and an AC clarification that moves neither leave both empty and change nothing. `tier` is deliberately not refreshed here — re-inferring a model tier is a fresh reflection pass (Step 3), not a byproduct of an append; if an edit genuinely re-sizes the work, that is the split conversation in sub-step 3, not a silent field rewrite.

   **A backfilled entry carries nulls for the summary-table fields, and the tally shows that honestly.** An issue opened elsewhere was never drafted here, so this thread inferred no tier and read no estimate. Record `null` rather than guessing: the running tally renders `—` in `Delivers`, `Model`, or `Est` for any row whose log entry lacks that value — one rule for all three, no per-column fallback. A fabricated tier would read as a genuine inference — the row would claim Opus work on no evidence — which is worse than an empty cell.

   **Chips are create-time only.** `/update`/edit-in-place never spawns or refreshes a chip — a chip offered at Step 9 stays as-is even if the body changes materially afterward. Re-planning the chip itself is out of scope for this skill (open question in issue #635's Notes); if the drift matters, retract and re-create. This also means `/update` can never cause the reverse double-offer (`/wave` or `/pm` already offered a chip for this issue, then someone edits it here via `/update`): the step above never *reads* an existing `chip_task_id` to decide anything, and the only value it ever *writes* is `null` (when backfilling a minimal entry for an issue this thread's log didn't already track) — never a live one, so it has no way to spawn a competing chip.

---

## Step 11: Natural-language edit-in-place

Phrases like **"also add X to issue #N"**, **"edit #N …"**, **"update #N with …"** route through the same fetch → classify → propose → confirm → apply → print-link path as `/update` (Step 10) — they edit the existing issue via `gh issue edit`, never create a duplicate. The explicit `/update` command and natural-language edits are two front doors to one mechanism.

---
