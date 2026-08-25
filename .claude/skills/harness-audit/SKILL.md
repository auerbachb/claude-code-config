---
name: harness-audit
description: Use when asking whether the harness now does natively what we automate by hand — "audit our rules/skills/hooks", "what's redundant", "does Claude Code do this already", or the monthly check. Verdicts every rule, skill, script, and hook against live harness behavior, then files issues. Advisory only — never edits.
argument-hint: "[--tick] [--report-only] [--report-to-repo] [--force-here] [--arm] [--stop]"
---

# harness-audit — is the harness already doing this?

Our automation only ever grows. Nothing in the workflow ever asks *"does Claude
Code do this natively now?"* — so redundant rules accumulate, crowd out the ones
that still earn their place under the word budget, and eventually read as
deliberate because they have sat there so long.

This skill is that missing question, run on a schedule.

Resolve the repository locator before either pass:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
REPO_ROOT_SH=$(resolve_script repo-root.sh || true)
[[ -n "$REPO_ROOT_SH" ]] || { echo "ERROR: repo-root.sh not found (checked all three paths) — harness inventory root unavailable" >&2; exit 1; }
```

> **ADVISORY ONLY — NON-NEGOTIABLE.** This skill **never** edits, deletes,
> moves, or rewrites a rule, skill, script, or hook. Not even an obviously-dead
> one. Not even when the verdict is unambiguous. Its entire output surface is a
> report plus GitHub issues. A human reads the verdicts and lands the change
> through the normal issue → branch → PR flow. If you catch yourself reaching
> for Edit/Write on an audited artifact, stop — that is the one thing this skill
> is not allowed to do.

## The two-pass shape (and why)

| Pass | Cost | Model | What it does |
|------|------|-------|--------------|
| **Inventory** | Cheap — one script | Whatever is running | Enumerate every artifact. No judgment. |
| **Judgment** | Expensive — live research + per-artifact reasoning | Top tier, resolved at run time | Read current harness behavior, verdict each artifact, file issues. |

The split exists because of a real constraint. `subagent-orchestration.md` reserves
the top tier for **interactive step-ups where a human watches the spend** — it is
never a spawn default. A monthly tick that quietly burns top-tier tokens
unattended contradicts that rule's stated harm model, not merely its wording. So
the recurring tick runs only the cheap pass and then *offers* the judgment pass
as a click-to-launch chip. Nobody's budget moves without a human clicking.

Rationale, alternatives considered, and the watermark scheme: `.claude/reference/harness-audit.md`.

---

## Step 0 — Parse mode and resolve context

| Invocation | Meaning |
|------------|---------|
| `/harness-audit` | On-demand full run. Neither enables nor disturbs the recurring nudge. |
| `/harness-audit --tick` | The tick body. Cheap pass + chip offer, gated on the monthly watermark. |
| `/harness-audit --report-only` | Dry run: verdicts and report, **files nothing**. |
| `/harness-audit --report-to-repo` | Write the report into `.claude/reference/` instead of `~/.claude/`. Refuses outside a non-`main` worktree (Step 8). |
| `/harness-audit --force-here` | Run the judgment pass on the current model even when it is not the resolved top tier; stamps a caveat into the report. |
| `/harness-audit --arm` | Enable the session-start nudge. |
| `/harness-audit --stop` | Disable the session-start nudge. |

The first two rows and the last two are **modes** and are mutually exclusive.
`--report-only`, `--report-to-repo`, and `--force-here` are **modifiers** that
combine with a plain on-demand run (and with each other). A `--tick` ignores
`--force-here` — a tick never runs the judgment pass, whatever it is passed.

Resolve once, up front:

```bash
REPO_ROOT="$("$REPO_ROOT_SH")"
INVENTORY="$REPO_ROOT/.claude/skills/harness-audit/inventory.sh"
FLEET="$REPO_ROOT/.claude/scripts/model-fleet.sh"
SESSION_STATE_SH="$REPO_ROOT/.claude/scripts/session-state.sh"
STATE_DIR="$HOME/.claude/harness-audit"
WATERMARK="$STATE_DIR/last-run.json"
MONTH="$(TZ='America/New_York' date +%Y-%m)"
mkdir -p "$STATE_DIR"
```

`--arm` and `--stop` are **lifecycle modes**; every other mode skips Step 1
entirely.

- **`--stop`** is strictly lifecycle-only: run Step 1 and exit, never auditing.
- **`--arm`** runs Step 1, then performs **one inventory-only tick** (Steps 2–3
  and Step 5's offer) so the first month is evaluated immediately instead of
  waiting for the next session, then exits. It never runs the judgment pass
  itself — a nudge-driven tick and a hand-armed first tick behave identically.

---

## Step 1 — `--arm` / `--stop` (recurrence lifecycle)

**The recurrence is a session-start check, not a scheduled job** (issue #827).
`CronCreate` — the scheduler this skill used — does not outlive the session that
armed it, so a monthly audit cannot be driven by one: the job dies at session
exit and the audit silently never runs, the worst possible failure for a skill
whose whole job is noticing silent staleness. A genuinely durable scheduler does
exist (`mcp__scheduled-tasks__*`); why this skill still declines it is in
`.claude/reference/cross-session-durability.md`.

What *is* durable is the watermark file, and it already records everything the
cadence needs. So the tick moved to the one event that recurs reliably: **the
start of a session**. `session-scheduling-reconcile.sh` reads the watermark on
every session start and surfaces a one-line nudge when the month is due.
Sessions start far more often than monthly, so a month cannot be missed — and
this needs no job id, no expiry window, and no `CronList` reconciliation.

`--arm` and `--stop` therefore toggle that nudge, in the watermark file:

### `--arm`

Hold the shared lock and replace atomically. A concurrent `--tick` writing
`last_offered_month` must not be clobbered, and an interrupted write must not
leave invalid JSON where the next session start will read it:

```bash
source "$REPO_ROOT/.claude/scripts/state-lock.sh"
state_lock_acquire "$WATERMARK"
python3 - "$WATERMARK" true <<'PY'
import json, os, sys, tempfile
p, val = sys.argv[1], sys.argv[2] == "true"
d = json.load(open(p)) if os.path.exists(p) else {}
d["nudge_enabled"] = val
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, p)
PY
state_lock_release "$WATERMARK"
```

Then run the single inventory-only tick described in Step 0 so the user sees the
skill work immediately, and report that the nudge is on.

**Arming is idempotent** — it sets a boolean. There is no way to arm twice, and
so no way to double an offer.

### `--stop`

Run the identical locked block with `false` in place of `true`. Nothing else to
tear down: there is no job, so nothing can keep firing against state that claims
it is gone. Report that the nudge is off and **STOP** — `--stop` never audits.

Both modes leave `last_completed_month` / `last_offered_month` untouched, so
disabling and re-enabling the nudge never re-audits a month that is already done.

---

## Step 2 — `--tick` gating (tick body only)

Skip this step entirely for every non-`--tick` mode.

There is no job to confirm the survival of — the session-start nudge is the
recurrence (Step 1), and it re-reads the watermark from disk every time. A tick
is therefore pure watermark arithmetic.

**Read the watermark** (`$WATERMARK`, absent on first run = never audited):

```json
{"last_completed_month": "2026-06", "last_completed_at": "...", "last_offered_month": "2026-07"}
```

| Condition | Action |
|-----------|--------|
| `last_completed_month == $MONTH` | Already audited this month → timestamped heartbeat, **exit**. |
| `last_offered_month == $MONTH` | A step-up chip is already pending → heartbeat naming it, **exit**. Do not re-offer. |
| Neither matches | Proceed: Step 3 (inventory), then Step 5's chip offer. **A tick never runs the judgment pass itself.** |

The two separate watermarks are load-bearing. One alone forces a choice between
two bad behaviors: re-offering a chip on every session start until it is
clicked, or marking the month done when nothing was actually audited.

---

## Step 3 — Inventory pass (cheap, any model)

**Fail closed — a partial inventory is worse than none**, because every
downstream completeness claim is measured against it. Write to a temp file,
validate, and only then publish:

```bash
TMP_INV="$STATE_DIR/.inventory-$MONTH.json.tmp"
# --repo-root is REQUIRED, not optional: inventory.sh otherwise resolves the
# repo from the caller's cwd, so a run from a linked worktree would audit that
# worktree (or, from an unrelated repo, the wrong project entirely) while the
# report still claims to cover the canonical config repo.
if ! "$INVENTORY" --repo-root "$REPO_ROOT" > "$TMP_INV"; then
  rm -f "$TMP_INV"
  echo "ERROR: inventory.sh failed — aborting the audit rather than judging a partial surface." >&2
  exit 1
fi
# Parse-check before publishing: a truncated write must never become the
# baseline the Step 6 assertion trusts.
if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("counts",{}).get("total",0) > 0 and d.get("artifacts") else 1)' "$TMP_INV"; then
  rm -f "$TMP_INV"
  echo "ERROR: inventory output is unparseable or empty — aborting." >&2
  exit 1
fi
mv "$TMP_INV" "$STATE_DIR/inventory-$MONTH.json"

# Read the counts back OUT of the published file rather than invoking the
# script a second time. Two runs can disagree if anything under .claude/
# changes between them, and the assertion in Step 6 must be measured against
# the same snapshot the verdicts were produced from.
python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["counts"]; [print("%s\t%d" % (k, c[k])) for k in ("rule","skill","script","hook","total")]' \
  "$STATE_DIR/inventory-$MONTH.json"
```

Never reuse a previous month's inventory file as a fallback; a stale surface
would silently exempt everything added since.

The script enumerates four categories — `rule` (CLAUDE.md + `.claude/rules/**/*.md`,
recursive, matching how the corpus is loaded and budgeted),
`skill` (every `.claude/skills/*/SKILL.md`), `script` (`.claude/scripts/`, minus
`lib/` and `tests/`), and `hook` (the union of `global-settings.json`'s `hooks`
map and `.claude/hooks/`, cross-checked). Its declared `exclusions` are part of
the output; **quote them in the report** rather than letting a skipped path be
invisible.

**`hook_drift` entries are findings in their own right.** A hook registered in
the manifest but missing from disk never fires; a file on disk that nothing
registers is dead weight or a missed registration. Carry both into Step 7.

**If this is a `--tick` or `--arm`, stop here and go to Step 5** — both are
inventory-only paths, and neither may fall through into the judgment pass
(Steps 4 and 6–9). `--arm` in particular exists to *offer* the expensive pass;
running it would defeat the top-tier invariant this skill is built around. Only
an on-demand run continues to Step 4.

---

## Step 4 — Establish current harness behavior from a live source

> **Model memory is forbidden as a source.** Your training data has a cutoff and
> the harness ships continuously; "I believe Claude Code does X natively" is
> exactly the confident-but-stale judgment this audit exists to catch in *our*
> files. A verdict that cannot name where it read the behavior is not a verdict.

Use, in rough order of preference:

1. **The `claude-code-guide` agent** (Agent tool, `subagent_type: claude-code-guide`)
   — purpose-built for "does Claude Code do X?" and, critically, carries
   `WebFetch`/`WebSearch`, so it can read current docs rather than recall them.
   Ask concrete, checkable questions, batched by theme rather than one per
   artifact. Spawn it per `subagent-orchestration.md`: `mode: "bypassPermissions"`
   and an explicit model set from that file's read-only-review-agent row — look
   the tier up, never spell it into this file (Step 5).

   The repo's own `.claude/agents/researcher.md` is **not** a substitute here:
   it is deliberately read-only over the *codebase and GitHub*, with no web
   tools at all, so it cannot establish current harness behavior. Use it for the
   repo half of a question (what our artifact actually does) and
   `claude-code-guide` for the harness half.
2. **Official docs and release notes** via `WebFetch` / `WebSearch` — changelog
   and feature pages for the surfaces our automation overlaps: scheduling,
   background tasks, worktrees, hooks, subagents, review integrations, memory.
3. **Observable local behavior** — the tool list and settings schema available in
   this session. First-hand, but only evidence of *this* session's configuration.

Record for every claim: `{kind, ref, checked_at}` — `kind` one of
`guide-agent` / `docs` / `release-notes` / `local-observation`, `ref` a URL,
agent answer excerpt, or concrete observation.

**Unverifiable ⇒ `keep` + `unverified`.** If no live source settles whether the
harness covers an artifact, the verdict is `keep`, flagged `unverified`, with the
question you could not answer written out. Never guess. The asymmetry is the same
one `autofile-dedup.md` reasons from: a wrong `redundant` deletes a load-bearing
guard, a wrong `keep` costs one line of report.

---

## Step 5 — Model gating and the step-up chip

Resolve the tier — **no model name is written anywhere in this file**, which is
the entire point of the indirection:

```bash
TOP_ID="$("$FLEET" --top-tier)"
TOP_DISPLAY="$("$FLEET" --top-tier-display)"
```

`model-fleet.sh` fails closed: if it errors, **stop and report** rather than
proceeding on an assumed tier. A fleet change is a one-file edit to
`.claude/model-fleet.json`; nothing in this skill needs touching when it happens.

### Tick path (`--tick`)

Never run the judgment pass. **Claim the month, then offer it.**

Claim *before* offering, not after. A tick that offers first and records second
has a window in which a second tick — a session start racing a manual run, or
two sessions starting at once — reads `last_offered_month` as unset and offers
the same month again.

**Ordering alone is not enough: read-then-write is still a TOCTOU race.** Two
ticks can both read an unset watermark, both conclude they won, and both offer.
The check and the claim must be *one* mutually-exclusive operation, so hold the
repo's existing advisory lock across both — the same primitive every
`session-state.json` writer uses (`state-lock.sh`, issue #639), which exists
because "each write is atomic" did not make the surrounding read-modify-write
safe:

```bash
source "$REPO_ROOT/.claude/scripts/state-lock.sh"
state_lock_acquire "$WATERMARK" || { echo "[harness-audit] watermark lock busy — another tick holds the claim; exiting." >&2; exit 0; }
trap 'state_lock_release' EXIT
# --- critical section: check AND claim, nothing between them ---
CLAIMED=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("last_offered_month") or "")' "$WATERMARK" 2>/dev/null || echo "")
if [[ "$CLAIMED" == "$MONTH" ]]; then
  state_lock_release; trap - EXIT
  echo "[harness-audit] $MONTH already claimed by another tick — offering nothing."; exit 0
fi
# write last_offered_month=$MONTH with delivery:"pending", preserving siblings
state_lock_release; trap - EXIT
```

1. **Under the lock**, read `last_offered_month`. If it already equals `$MONTH`,
   another run claimed it — release and **exit**, offer nothing.
2. **Still under the lock**, write `last_offered_month = $MONTH` with
   `delivery: "pending"`, preserving the rest of the watermark document. Release
   only after the write lands.
3. **Offer**, by whichever path is available:
   - **Chip** via `mcp__ccd_session__spawn_task`, per `chip-launching.md`.
     On success record the returned `task_id` and set `delivery: "chip"`, so
     the offer can be withdrawn later.
   - **Fallback** (no `spawn_task` in session): print the byte-identical fenced
     block and set `delivery: "fallback"`, `task_id: null`. **A fallback block
     is still an offer** — the month stays claimed, or the tick reprints the
     same wall of text every day until someone acts on it.
4. **Roll back** the claim (clear `last_offered_month`) only if *neither* path
   delivered anything. An undelivered claim would silently skip the month.

### On-demand path

**A skill cannot change its own thread's model.** So compare and route:

- **Running model matches the top tier** → run the judgment pass inline (Steps 6–9).
  Match against **either** `$TOP_ID` or `$TOP_DISPLAY`, compared
  case-insensitively and ignoring surrounding whitespace. A model self-reports
  its *display* name far more often than its API id, so an id-only comparison
  would report a mismatch on the very model it was asked to check for — and the
  inline path would never run.
- **Mismatch** → say so plainly, offer the same step-up chip, and stop. The user
  either clicks it or re-runs with `--force-here`.
- **`--force-here`** → proceed on the current model and stamp
  `judged_on_model: <actual>` into the report header, so a reader can weigh the
  verdicts against the tier that produced them.

### Chip model + effort contract

The chip `prompt` **MUST open with** the `**Model:**` line as its literal first
line, then the `**Effort:**` line, then — **no blank line** between the three —
the verbatim MODEL GUARD preamble from `chip-launching.md`. Reproduce that
preamble unchanged; do not reword it for this skill.

The effort recommendation is a literal here, unlike the model. `{TOP_DISPLAY}` is
resolved because "the top of the fleet" changes when the fleet does; the effort
this work needs does not — a judgment pass over the whole harness is Max-effort
work by its nature, and pinning it says so. `{LEVEL}` uses the picker's own
labels (`chip-launching.md` "Model and effort lines"), never a bare API token.

```text
**Model:** {TOP_DISPLAY} — deep judgment pass; distinguishing "the harness does this now" from "ours is stricter" degrades badly on a cheaper tier
**Effort:** Max — correctness-over-cost: a wrong "the harness covers this" verdict silently deletes a working guard
{verbatim MODEL GUARD preamble from chip-launching.md}

Run /harness-audit {SAFE_MODIFIERS} for {MONTH} against {REPO}. The inventory
pass is already done — {N} artifacts at {STATE_DIR}/inventory-{MONTH}.json. Do
Steps 4 and 6-9 of .claude/skills/harness-audit/SKILL.md ...
```

**`{SAFE_MODIFIERS}` is not optional garnish — it is a side-effect guard.** Carry
every restricting modifier from the invoking run into the generated prompt:
`--report-only` and `--report-to-repo`. A run the user deliberately made
side-effect-free must not hand out a chip whose prompt reads bare
`Run /harness-audit`, because clicking that lands on the **default** path and
files issues the user explicitly asked not to be filed. The step-up changes the
*model*, never the user's stated constraints.

Modifiers that only affect *this* thread's execution (`--force-here`, `--tick`,
`--arm`, `--stop`) are deliberately **not** carried — they describe how this run
routed itself, not what the work is permitted to do. When in doubt, ask whether
dropping the flag could cause a side effect the user declined; if yes, carry it.

Per `chip-launching.md`, both the `**Model:**` and `**Effort:**` lines are
repeated in the visible short summary so the user can set the picker **before**
clicking, since `spawn_task` carries neither parameter (upstream issue #735).
When the parent thread's model differs from the chip's recommendation, add the
one-line pre-click warning to that short summary — the picker is set by the user,
and the in-thread guard is only the backstop, and it covers the model line only.
Resolve both model names through `model-fleet.sh` and the running-model
self-report; never spell either into this file.

Fallback (no `spawn_task` in session): print the byte-identical block in a fence,
per `chip-launching.md`'s fallback mode.

---

## Step 6 — Verdict every artifact

Exactly **one** verdict per inventoried artifact:

| Verdict | Means | Bar |
|---------|-------|-----|
| `redundant` | The harness now does this natively; our version adds nothing. | You can name the harness behavior **and** the live source, and it covers our artifact's job **fully**. |
| `conflicting` | The harness default and our rule describe the same thing **differently**, so the model gets two sources and may follow the wrong one. | Both behaviors named, and the divergence stated concretely. |
| `keep` | Still earning its place. | The default — everything that is not clearly one of the above. |

Each verdict carries: a **one-line reason**, and a **pointer to the specific
harness behavior checked** with its source.

### The rule that matters most: stricter is never redundant

**An artifact that is stricter than the harness default is `keep`, always.**
Superficial topic overlap ("the harness manages PRs now") is not coverage.

The worked example — apply it as the calibration for every borderline call:

> `safety.md`'s authorship guard restricts automated PR writes to PRs authored by
> the authenticated user. The harness has PR tooling and permission modes, but no
> per-PR *author* gate. A reading that stops at "the harness handles PR
> operations" would call this redundant and delete a guard whose whole value is
> the narrower thing it forbids. Correct verdict: **`keep`** — stricter than the
> default, with the gap named.

Three more calibrations in the same direction:

- **Same behavior, tighter trigger** → `keep`. Ours fires in a narrower, more
  dangerous case.
- **Harness does it, but only on an opt-in we do not set** → `keep`. A default we
  do not enable is not a default we get.
- **Harness does it, ours documents *why*** → `keep` if the rationale is load
  bearing; `redundant` only if the mechanism is genuinely duplicated and the
  reasoning lives elsewhere.

**Uncertainty resolves to `keep`.** Every time.

### Completeness assertion (hard gate)

Count verdicts per category and compare against `inventory.json`'s `counts`:

```bash
python3 - "$STATE_DIR/inventory-$MONTH.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["counts"])
PY
```

**Any category where `verdicts != count` fails the run loudly.** Name the missing
paths and stop — do not file issues or write a final report from a partial pass.
Silent omission is the failure mode this gate exists to make impossible, and a
short report that *looks* complete is worse than an error.

**Self-audit is in scope.** This skill inventories `.claude/skills/`, which now
includes `harness-audit` itself, plus `model-fleet.sh` and `inventory.sh`. Verdict
them like anything else. The one carve-out is in Step 7: do not *file* an issue
about this skill's own files while they are still unmerged on their first run —
there is nothing yet for a reader to act on.

---

## Step 7 — File issues (exact-artifact dedup)

`--report-only` **files nothing** — skip to Step 8.

Only clear `redundant` and `conflicting` findings are filed. `keep` verdicts live
in the report. One issue per finding; **one grouped issue when several findings
share a single fix** (carry every artifact's marker in the grouped body).

### Dedup: exact key, not the fuzzy ladder

Every finding names one unambiguous artifact path, so this uses the
**exact-artifact** variant from `autofile-dedup.md` — the same shape as `/wrap`'s
churn hotspots, not `issue-dedup.sh`'s strong/weak/none scoring. Fuzzy coverage
would be wrong twice over here: it can miss the existing issue (filing a
duplicate) and it can match a *sibling* path (suppressing a real finding).

- **Title:** `Harness redundancy: <artifact path>` — compared by **client-side
  string equality**.
- **Body marker:** `<!-- harness-audit: <artifact path> -->` — survives a human
  retitling the issue, and is the authority when title and marker disagree.
  **Compare the fully-substituted marker, never the `<!-- harness-audit:`
  prefix.** Observed on the first live run: issue #770 (this skill's own
  tracking issue) contains the *template* text `<!-- harness-audit: <artifact
  path> -->` because it documents the convention, and a prefix-only match
  treated that as an existing filing for every artifact. Any issue describing
  the mechanism will do the same. Build the exact string for the one path you
  are checking, closing `-->` included, and require a full match.
- **Search is recall only:**

  ```bash
  DEDUP_LIMIT=200
  CANDIDATES="$(gh issue list --search "Harness redundancy in:title" --state all \
    --limit "$DEDUP_LIMIT" --json number,title,body,state)" || CANDIDATES=""
  ```

  **A saturated result set is a failed lookup, not a clean one.** If the fetch
  returns exactly `DEDUP_LIMIT` rows, the candidate set was truncated and the
  issue you needed to see may be the one that got cut — treat it exactly like a
  command failure below (block the filing, surface it), rather than concluding
  "no match" from a page that was never complete. This matches
  `churn-hotspots.sh`, which caps at 200 and reports `existing_lookup_failed`
  on saturation.

  ```bash
  COUNT="$(jq 'length' <<<"${CANDIDATES:-[]}")"
  if [[ -z "$CANDIDATES" ]] || (( COUNT >= DEDUP_LIMIT )); then
    echo "existing_lookup_failed — blocking this filing" >&2
  fi
  ```

  GitHub tokenizes paths in `in:title`, so the search narrows candidates; the
  **decision is the exact comparison**, never the search ranking.
- **A failed lookup BLOCKS filing.** If `gh issue list` errors, returns
  unparseable output, **or saturates `DEDUP_LIMIT`** (see above), file nothing
  for that artifact, surface the failure by name, and carry it into the report's
  suppressed section. Never risk a duplicate on an unverified lookup — and note
  that a truncated page is unverified, however clean it looks.
- **Open match** → comment the new evidence onto the existing issue instead of
  filing. **Closed match** → file, and link it as prior context.

### Same-run batch self-check

Keep a **run-scoped registry** of every artifact path filed during this audit,
and check it *before* the repo lookup — `autofile-dedup.md` requires this of
every autonomous filer. Two findings in one run can key to the same artifact
(a rule that is both redundant *and* conflicting), and a grouped issue already
covers several paths at once. Without the registry, the second finding files a
duplicate of an issue created minutes earlier in the same run, which the repo
search may not even have indexed yet.

- Path already in the registry → **collapse** into the issue this run already
  filed (add the finding as a comment, or fold it into the grouped body while
  preserving every artifact's marker). Record it as suppressed, naming the
  earlier issue: `Collapsed into #N (filed earlier this run)`.
- Filter the run's already-filed numbers out of any repo-side result
  **client-side, after the fetch**. `gh issue list` has no `--exclude` flag —
  only the `issue-dedup.sh` helper `/wrap` uses does, and this path does not go
  through it. Drop those numbers from the candidate set yourself before
  comparing, so an issue filed minutes ago in this same run cannot come back as
  a repo candidate and be double-counted.

### Body shape

Reuse `/issue-maker`'s canonical 6-section body (Background, Problem, Proposed
solution, Acceptance Criteria, Test Plan, Notes / Open questions), its
label-intersection rule (apply only labels that already exist in the repo), and
its closing-URL convention (the issue URL is the last line of the report entry).
Include the marker comment, the verdict, the one-line reason, and the harness
behavior + source. Footer: `_Captured via /harness-audit._`

### Never silent

Every suppressed filing is named in the report with the issue it deferred to —
`Appended to #N instead of filing — "<finding>"`. A finding that is neither filed
nor reported is the exact outcome this contract exists to prevent.

---

## Step 8 — Write the report

**Default destination is outside the repo:**
`~/.claude/harness-audit/harness-audit-YYYY-MM.md`.

> **Why outside.** The recurring tick can run in a session sitting on the root
> repo on `main`. Writing a report there would put changes on `main` — against
> `CLAUDE.md` §ALWAYS USE A WORKTREE — and trip `dirty-main-guard`. Landing a
> report *in* the repo stays a deliberate, human, PR-shaped act.

`--report-to-repo` writes `.claude/reference/harness-audit-YYYY-MM.md` instead,
and is valid **only** when both hold:

```bash
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && [[ "$(git branch --show-current)" != "main" ]] \
  && [[ "$(git rev-parse --show-toplevel)" != "$("$REPO_ROOT_SH")" ]]
```

i.e. a worktree that is **not** the root repo, on a branch that is **not** `main`.
**Refuse otherwise** — explain why and fall back to the default path. When it does
land in-repo, add the one-line entry under **"Audits and research
(point-in-time)"** in `.claude/reference/README.md`.

Follow the established audit-report shape used by the repo's prior audits:

```markdown
# Harness redundancy audit — YYYY-MM

**Issue:** #770
**Date:** <ET date>
**Related precedent:** <prior month's report, or the audit that came closest>
**Judged on:** <model>  <!-- plus `judged_on_model` caveat when --force-here -->

## Executive summary
<2–4 sentences: how many artifacts, how many of each verdict, the single most
consequential finding.>

## Findings

| # | Artifact | Verdict | Reason | Harness behavior + source |
|---|----------|---------|--------|---------------------------|

## What NOT to change
<Artifacts a careless reader would call redundant, and why they are not —
led by every stricter-than-default `keep`. This section is the guardrail
against someone acting on the table above without reading it.>

## Follow-ups filed
## Filings suppressed as duplicates
## Coverage
<Per-category verdicts vs inventory counts; the declared exclusions.>
## Cadence
```

On completion, set `last_completed_month` and `last_completed_at` in the
watermark. `--report-only` **also** sets them: a dry run still produced verdicts,
so the month's question has been answered.

---

## Step 9 — Report to the user

Timestamped summary: counts by verdict, the issues filed (with URLs), anything
suppressed, the report path, and the source(s) Step 4 actually used. If any
verdict is `unverified`, say how many and why.

---

## Exit criteria

**STOP** when all of these hold — and not before:

1. Every inventoried artifact has exactly one verdict, and the Step 6
   completeness assertion passed for **every** category.
2. Every **verified** verdict cites a live source. A verdict with no live source
   is permitted **only** as `keep` + `unverified`, and only when it carries the
   unanswered question and why it could not be settled — that is the documented
   downgrade from Step 4, not a gap. An unsourced `redundant` or `conflicting`
   never passes.
3. Every `redundant` / `conflicting` finding is either filed or reported as
   suppressed, naming its target issue. **Nothing is silently dropped.** Under
   `--report-only` nothing is filed, so every such finding must appear in the
   report instead — the obligation moves, it does not lapse.
4. The report is written to a permitted destination.
5. The watermark is updated.
6. **No audited artifact was modified.** Confirm with `git status --short` —
   the only paths that may appear are a `--report-to-repo` report and its
   `README.md` index line.

**STOP immediately, without completing the audit, when:**

- `model-fleet.sh` fails — report the error; never assume a tier.
- The completeness assertion fails — name the gap; file nothing.
- The mode is `--stop` — lifecycle only, never any audit work.
- The mode is `--arm` — stop after the single inventory-only tick; the judgment
  pass is offered, never run.
- A `--tick` finds its month already completed or already offered — heartbeat
  and exit.

**Never** edit a rule, skill, script, or hook. **Never** file an issue from a
`--report-only` run. **Never** run the judgment pass from a `--tick`.
